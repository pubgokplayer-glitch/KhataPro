/// KhataPro · keeping the UI at 60–120 fps while 52 MB crosses a data channel.
///
/// The naive LAN sync — `for (chunk in chunks) channel.send(chunk)` — does three
/// things wrong at once, and all three are visible to the shopkeeper as a stutter:
///
///  1. it fills the peer connection's send buffer far beyond what the link can
///     carry, so memory balloons and latency explodes;
///  2. it never yields to the event loop, so the isolate that builds the next frame
///     waits behind the loop;
///  3. it uses one frame size for every link, so a weak Wi-Fi connection gets the
///     same 64 KiB messages as a strong one.
///
/// This file fixes all three with the flow control a transport would use: a
/// **credit budget**, an **explicit yield**, and **AIMD frame sizing**. The
/// decisions are pure arithmetic (`PumpDecision`, `AdaptiveFrameSizer`), so the
/// harness can run a full 52 MB transfer against a fake channel and assert that the
/// budget was never exceeded and that the pump yielded on schedule.
///
/// The numbers, and where they come from:
///
///  * **16 KiB initial frame** — `RTCDataChannel` message limits vary by stack
///    (SCTP's default is 64 KiB, but some Android WebRTC builds negotiate less);
///    16 KiB is safe everywhere and still amortises framing overhead well.
///  * **256 KiB in-flight budget** — one round trip's worth at typical LAN RTT and
///    throughput. Big enough to keep the link busy, small enough that a stalled peer
///    costs 256 KiB of memory rather than 52 MB.
///  * **4 MiB/s pacing** — a mid-range phone on 2.4 GHz Wi-Fi sustains roughly
///    2–6 MB/s per stream. Pacing at 4 MiB/s leaves the radio and the CPU room to
///    render; an unpaced transfer competes with the frame pipeline and the frame
///    time spikes from 8 ms to 40 ms.
library;

/// What the pump should do next. Exactly one of these, every step — the pump is a
/// state machine, not a loop with conditions scattered through it.
enum PumpStep {
  /// Write the frame and charge the budget.
  send,

  /// The channel is full: wait for `bufferedAmountLow` (or a short timer) and retry.
  waitForDrain,

  /// Yield to the event loop so the frame scheduler can run. The pump counts frames
  /// per tick rather than measuring time, because a tick is what the UI feels.
  yieldToUi,

  /// Nothing left to send.
  done,

  /// The peer refused or vanished. Stop, keep the checkpoint, let the resume logic
  /// (or the next app launch) pick it up.
  aborted,
}

/// How long the pump may keep sending before it must yield.
///
/// Four frames at 256 KiB budget means a yield happens at most every ~256 KiB, which
/// at 4 MiB/s is every 64 ms — under the 16 ms frame budget only if the send itself
/// is cheap, and it is: handing a buffer to the data channel is a memcpy, not a
/// network wait. The yield is what guarantees the UI thread gets the isolate back.
abstract final class PumpTuning {
  static const int initialFrameBytes = 16 * 1024;
  static const int minFrameBytes = 4 * 1024;
  static const int maxFrameBytes = 64 * 1024;
  static const int inFlightBudgetBytes = 256 * 1024;
  static const int maxFramesPerTick = 4;

  /// 4 MiB/s. Configurable per device class: a tablet on 5 GHz can afford more, and
  /// the sync screen exposes "fast / gentle" for a phone that is being used while
  /// syncing.
  static const int defaultBytesPerSecond = 4 * 1024 * 1024;

  /// Above this, the connection is being pushed harder than a phone's radio should
  /// be. Not a hard limit — a pacing target.
  static const int gentleBytesPerSecond = 1024 * 1024;
}

/// The state the pump needs, as a value.
final class PumpState {
  const PumpState({
    required this.remaining,
    required this.inFlight,
    required this.framesThisTick,
    required this.sentThisSecond,
    required this.frameBytes,
    this.aborted = false,
  });

  final int remaining;
  final int inFlight;
  final int framesThisTick;

  /// Bytes sent inside the current one-second window — a *window* counter, reset by
  /// the caller when the window rolls. Passing a running total here silently disables
  /// pacing.
  final int sentThisSecond;
  final int frameBytes;
  final bool aborted;

  PumpState copyWith({
    int? remaining,
    int? inFlight,
    int? framesThisTick,
    int? sentThisSecond,
    int? frameBytes,
    bool? aborted,
  }) =>
      PumpState(
        remaining: remaining ?? this.remaining,
        inFlight: inFlight ?? this.inFlight,
        framesThisTick: framesThisTick ?? this.framesThisTick,
        sentThisSecond: sentThisSecond ?? this.sentThisSecond,
        frameBytes: frameBytes ?? this.frameBytes,
        aborted: aborted ?? this.aborted,
      );
}

/// The whole decision, in one place, testable without a socket.
abstract final class FlowControl {
  /// [bytesPerSecond] is a pacing target, not a hard rate limiter: it is enforced by
  /// asking the caller to wait, which keeps the arithmetic honest and the waiting
  /// where the event loop can do something useful with it.
  static PumpStep decide(
    PumpState state, {
    int budgetBytes = PumpTuning.inFlightBudgetBytes,
    int maxFramesPerTick = PumpTuning.maxFramesPerTick,
    int bytesPerSecond = PumpTuning.defaultBytesPerSecond,
    int elapsedThisSecondMs = 1000,
  }) {
    if (state.aborted) return PumpStep.aborted;
    if (state.remaining <= 0) return PumpStep.done;
    if (state.framesThisTick >= maxFramesPerTick) return PumpStep.yieldToUi;

    // Pacing comes before the buffer check: on a fast link the budget would never
    // bind, and the UI would still suffer from an unpaced 20 MB/s upload.
    if (elapsedThisSecondMs < 1000) {
      final allowance =
          (bytesPerSecond * elapsedThisSecondMs) ~/ 1000 - state.sentThisSecond;
      if (allowance <= 0) return PumpStep.waitForDrain;
    }

    if (state.inFlight + state.frameBytes > budgetBytes) return PumpStep.waitForDrain;
    return PumpStep.send;
  }

  /// The frame actually written, which is never more than what is left.
  static int frameLength(PumpState state) =>
      state.frameBytes < state.remaining ? state.frameBytes : state.remaining;

  /// How long to wait before trying again, when the answer was
  /// [PumpStep.waitForDrain]. Deliberately short: on a healthy link the buffer
  /// drains continuously, and a long sleep would idle the transfer.
  static Duration drainDelay(PumpState state, {int budgetBytes = PumpTuning.inFlightBudgetBytes}) {
    // Scale the wait with how far over the budget we are: a nearly-empty buffer
    // needs a moment, a full one needs a whole frame's worth of draining.
    final over = state.inFlight - budgetBytes;
    // The quantum is a quarter of a frame, floored at one byte: a caller that hands in
    // a zero-size frame must get a short wait, not an integer division by zero.
    final quantum = state.frameBytes < 4 ? 1 : state.frameBytes ~/ 4;
    final ms = over <= 0 ? 2 : (2 + (over ~/ quantum).clamp(0, 20));
    return Duration(milliseconds: ms);
  }
}

/// Additive-increase / multiplicative-decrease frame sizing.
///
/// The same controller TCP uses, for the same reason: it probes upward slowly and
/// retreats sharply. Frame size (not rate) is what it adjusts, because a lost
/// WebRTC message is a lost `RTCDataChannel.send`, and a smaller message is one the
/// SCTP layer is more likely to deliver intact.
final class AdaptiveFrameSizer {
  AdaptiveFrameSizer({
    int initial = PumpTuning.initialFrameBytes,
    this.probeAfter = 64,
  }) : _frameBytes = initial;

  int _frameBytes;
  int _cleanFrames = 0;

  /// Consecutive successful frames before the size is nudged up. 64 frames at 16 KiB
  /// is a megabyte of evidence that the link is comfortable.
  final int probeAfter;

  int get frameBytes => _frameBytes;

  /// Bytes of ciphertext actually pushed, for the sync screen's throughput readout.
  int get suggestedFrameBytes => _frameBytes;

  /// Records a delivered frame and returns the size to use next.
  int onDelivered() {
    _cleanFrames += 1;
    if (_cleanFrames >= probeAfter && _frameBytes < PumpTuning.maxFrameBytes) {
      // Additive increase: +25 %, capped. Gentle, because overshooting here is felt
      // as a dropped frame rather than as a lost packet.
      _frameBytes = (_frameBytes + (_frameBytes ~/ 4)).clamp(0, PumpTuning.maxFrameBytes);
      _cleanFrames = 0;
    }
    return _frameBytes;
  }

  /// Records a loss and returns the reduced size.
  int onLoss() {
    // Multiplicative decrease: halve, with a floor. One lost frame is enough
    // evidence; demanding several would mean several visible stutters.
    _frameBytes = (_frameBytes ~/ 2).clamp(PumpTuning.minFrameBytes, PumpTuning.maxFrameBytes);
    _cleanFrames = 0;
    return _frameBytes;
  }
}
