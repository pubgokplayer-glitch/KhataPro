/// KhataPro · the WebRTC side of LAN sync.
///
/// A phone-to-phone data channel, no server anywhere in the path:
///
///  * **No ICE servers.** `RTCConfiguration(iceServers: [])` means the browser stack
///    only ever gathers *host* candidates — the LAN addresses. No STUN, no TURN, no
///    public IP leaked, no quota to exhaust, nothing to pay for. On the same Wi-Fi
///    this connects every time; across networks it correctly fails instead of
///    silently uploading the user's books to a relay.
///  * **One data channel, no media.** `khata-sync-v1`, ordered and reliable. Ordered
///    because a pack is a byte stream and the SCTP layer is the cheapest place to
///    guarantee that; unreliable delivery is a future optimisation for the *initial*
///    bulk sync only, and it needs per-chunk application-level retransmission to be
///    worth it — the per-chunk MACs in `kpb1_format.dart` make that possible later.
///  * **DTLS underneath.** WebRTC gives us encryption in transit for free. The pack
///    is *also* encrypted end to end, because the cloud copy is nobody's business
///    either and the same file goes to both transports.
///  * **Non-trickle ICE.** The offer waits for gathering to finish and carries its
///    candidates inside the description, because the description travels by QR code,
///    and a QR code cannot trickle.
///
/// Backpressure is delegated to [FlowControl] so the frame-rate behaviour is tested
/// arithmetic rather than a hope; this file is the wiring that feeds it real numbers.
///
/// ## What this file must not do
///
/// Hand a description it did not receive to `setLocalDescription` or
/// `setRemoteDescription`. libwebrtc parses and validates its own text; a symmetric
/// "minimise both sides" is the kind of tidy-looking change that produces two phones
/// that negotiate successfully and then never connect. Minimising happens **only** on
/// the way into a [PairingTicket] — see `sdp_tools.dart`, which is pure Dart and is
/// therefore covered by the harness.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../../core/errors/khata_exception.dart';
import '../../core/security/hasher.dart' show randomBytes;
import 'flow_control.dart';
import 'qr_pairing.dart';
import 'sdp_tools.dart';

/// The channel label. Versioned: a v2 protocol must not be half-understood by a v1
/// peer, and a rejected channel is a better failure than a misparsed frame.
const String kSyncChannelLabel = 'khata-sync-v1';

/// How long to wait for ICE gathering. A LAN needs milliseconds; the ceiling exists so
/// a phone with a broken radio fails in two seconds instead of hanging the pairing
/// screen.
const Duration kIceGatheringTimeout = Duration(seconds: 2);

/// One LAN peer connection, plus the pack pump.
final class LanSyncTransport {
  LanSyncTransport({
    this.onProgress,
    this.onSessionCode,
  });

  final void Function(int sent, int total)? onProgress;

  /// Called when the local authentication string is ready to show. The UI shows six
  /// digits and waits for the user to confirm the other phone shows the same ones.
  final void Function(String code)? onSessionCode;

  RTCPeerConnection? _connection;
  RTCDataChannel? _channel;
  final _frames = StreamController<Uint8List>.broadcast();
  final _inbound = BytesBuilder(copy: false);
  final _buffer = BytesBuilder(copy: false);
  int _expectedBytes = 0;
  bool _aborted = false;

  /// The far end's frame stream, reassembled by the caller into a pack.
  Stream<Uint8List> get frames => _frames.stream;

  /// Offers: builds a connection and returns the ticket to render as a QR.
  Future<PairingTicket> createOffer({
    required String nodeId,
    required Uint8List ephemeralPublicKey,
    String? displayName,
    String? ledgerId,
  }) async {
    final connection = await _newConnection();
    final trap = _IceTrap(connection);
    final channel = await connection.createDataChannel(
      kSyncChannelLabel,
      RTCDataChannelInit()..ordered = true,
    );
    _attach(channel);

    final offer = await connection.createOffer();
    // The stack gets its own text back, unedited. `getLocalDescription()` is the one
    // that has the candidates once gathering completes.
    await connection.setLocalDescription(offer);
    final candidates = await trap.complete();
    final local = await connection.getLocalDescription() ?? offer;

    // From here on the description is text in a QR code, so it gets cut down — and
    // validated, because a minimised description missing `a=sctp-port` would still
    // scan and would never connect.
    final minimised = mergeCandidates(
      minimiseDataChannelSdp(local.sdp ?? offer.sdp ?? ''),
      candidates,
    );

    return PairingTicket(
      version: PairingTicket.currentVersion,
      nodeId: nodeId,
      role: PairingRole.offer,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      expiresAtMs: DateTime.now()
          .add(PairingCodec.defaultTicketLifetime)
          .millisecondsSinceEpoch,
      // The same CSPRNG the crypto layer uses. A pairing nonce is security
      // material — it binds the authentication string — so it must not be
      // hand-rolled from a clock.
      nonce: randomBytes(16),
      sessionDescription: minimised,
      candidates: candidates,
      ephemeralPublicKey: ephemeralPublicKey,
      displayName: displayName,
      ledgerId: ledgerId,
    );
  }

  /// Answers a scanned ticket, returning the ticket to send back to the offerer.
  Future<PairingTicket> acceptOffer({
    required PairingTicket offer,
    required String nodeId,
    required Uint8List ephemeralPublicKey,
    String? displayName,
    String? ledgerId,
  }) async {
    if (offer.isExpired) {
      throw const InvariantViolation(
        invariantCode: 'PAIR-3',
        message: 'that pairing code has expired. Show a fresh code on the other '
            'phone — they last two minutes on purpose.',
      );
    }
    final connection = await _newConnection();
    final trap = _IceTrap(connection);
    connection.onDataChannel = (channel) {
      if (channel.label == kSyncChannelLabel) _attach(channel);
    };

    await connection.setRemoteDescription(
      RTCSessionDescription(offer.sessionDescription, 'offer'),
    );
    // Candidates travel as a list *and* inside the description; the description is
    // what the stack parses, and a duplicate line is rejected by some stacks, so any
    // candidate already described is skipped here.
    await _addMissingCandidates(connection, offer.sessionDescription, offer.candidates);

    final answer = await connection.createAnswer();
    await connection.setLocalDescription(answer);
    final candidates = await trap.complete();
    final local = await connection.getLocalDescription() ?? answer;

    // Both sides now hold both keys, so both can derive the same six digits. The
    // caller shows them; the user compares them by eye; the sync proceeds.
    final code = SessionCode.derive(
      localPublicKey: ephemeralPublicKey,
      remotePublicKey: offer.ephemeralPublicKey,
      nonce: offer.nonce,
    );
    onSessionCode?.call(code);

    return PairingTicket(
      version: PairingTicket.currentVersion,
      nodeId: nodeId,
      role: PairingRole.answer,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      expiresAtMs: offer.expiresAtMs,
      nonce: offer.nonce,
      sessionDescription: mergeCandidates(
        minimiseDataChannelSdp(local.sdp ?? answer.sdp ?? ''),
        candidates,
      ),
      candidates: candidates,
      ephemeralPublicKey: ephemeralPublicKey,
      displayName: displayName,
      ledgerId: ledgerId,
    );
  }

  /// Completes the offer side of the exchange, once the answer comes back.
  Future<void> acceptAnswer(PairingTicket answer) async {
    final connection = _connection;
    if (connection == null) {
      throw const InvariantViolation(
        invariantCode: 'PAIR-4',
        message: 'no pairing is in progress',
      );
    }
    await connection.setRemoteDescription(
      RTCSessionDescription(answer.sessionDescription, 'answer'),
    );
    await _addMissingCandidates(connection, answer.sessionDescription, answer.candidates);
  }

  /// Sends a pack with flow control, yielding to the UI as it goes.
  ///
  /// The loop is the whole point of this file: [FlowControl.decide] says whether to
  /// send, wait or yield, and the arithmetic behind those answers is tested in
  /// `tool/sync_verify.dart` against a simulated 52 MB transfer.
  Future<void> sendPack(
    Uint8List pack, {
    int bytesPerSecond = PumpTuning.defaultBytesPerSecond,
    int chunkSize = 0,
  }) async {
    final channel = _channel;
    if (channel == null) {
      throw const InvariantViolation(
        invariantCode: 'PAIR-5',
        message: 'the data channel is not open yet',
      );
    }
    final sizer = AdaptiveFrameSizer(
      initial: chunkSize == 0 ? PumpTuning.initialFrameBytes : chunkSize,
    );

    // A four-byte length prefix, so the receiver knows when a resumed transfer is
    // whole without trusting anything the sender says about it.
    final framed = Uint8List(pack.length + 4)
      ..[0] = (pack.length >> 24) & 0xff
      ..[1] = (pack.length >> 16) & 0xff
      ..[2] = (pack.length >> 8) & 0xff
      ..[3] = pack.length & 0xff
      ..setRange(4, pack.length + 4, pack);

    var offset = 0;
    var framesThisTick = 0;
    // Pacing counts bytes inside the *current* window, not bytes since the transfer
    // began: a running total would make the allowance grow without bound and the
    // pacer would stop pacing after the first second. (The harness caught the
    // running-total version by stalling the simulated pump.)
    var sentThisSecond = 0;
    var windowStart = DateTime.now();

    while (offset < framed.length && !_aborted) {
      final now = DateTime.now();
      final elapsedThisWindowMs = now.difference(windowStart).inMilliseconds;
      if (elapsedThisWindowMs >= 1000) {
        windowStart = now;
        sentThisSecond = 0;
      }
      final state = PumpState(
        remaining: framed.length - offset,
        // `getBufferedAmount()` is asynchronous in flutter_webrtc: the value lives in
        // the native peer connection, not in Dart. (Checked against the pinned
        // package source, not assumed — see docs/SYNC.md §6.)
        inFlight: await channel.getBufferedAmount(),
        framesThisTick: framesThisTick,
        sentThisSecond: sentThisSecond,
        frameBytes: sizer.frameBytes,
        aborted: _aborted,
      );
      final step = FlowControl.decide(
        state,
        bytesPerSecond: bytesPerSecond,
        elapsedThisSecondMs: elapsedThisWindowMs,
      );
      switch (step) {
        case PumpStep.send:
          final length = FlowControl.frameLength(state);
          final frame = Uint8List.sublistView(framed, offset, offset + length);
          await channel.send(RTCDataChannelMessage.fromBinary(frame));
          offset += length;
          sentThisSecond += length;
          framesThisTick += 1;
          sizer.onDelivered();
          onProgress?.call((offset - 4).clamp(0, pack.length), pack.length);
        case PumpStep.waitForDrain:
          await Future<void>.delayed(
            FlowControl.drainDelay(state, budgetBytes: PumpTuning.inFlightBudgetBytes),
          );
        case PumpStep.yieldToUi:
          // Hand the isolate back: this is the yield that keeps the invoice list
          // animating at 60–120 fps while a 52 MB ledger crosses the room.
          framesThisTick = 0;
          await Future<void>.delayed(Duration.zero);
        case PumpStep.done:
        case PumpStep.aborted:
          return;
      }
    }
  }

  /// Closes the channel, the connection, and any pending futures.
  Future<void> dispose() async {
    _aborted = true;
    await _frames.close();
    await _channel?.close();
    await _connection?.close();
    _channel = null;
    _connection = null;
  }

  // ── internals ────────────────────────────────────────────────────────────

  Future<RTCPeerConnection> _newConnection() async {
    final connection = await createPeerConnection({
      // Empty, and deliberately so — see the class comment.
      'iceServers': <Map<String, String>>[],
      'sdpSemantics': 'unified-plan',
    });
    connection.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
          state == RTCPeerConnectionState.RTCPeerConnectionStateClosed) {
        // A dropped connection is normal on a phone that walked out of range. The
        // transfer keeps its checkpoint and resumes on the next pairing.
        _aborted = true;
      }
    };
    _connection = connection;
    return connection;
  }

  void _attach(RTCDataChannel channel) {
    _channel = channel;
    // Half the in-flight budget: the channel fires `bufferedAmountLow` when the
    // buffer drains below this, which is the signal the pump waits for.
    channel.bufferedAmountLowThreshold = PumpTuning.inFlightBudgetBytes ~/ 2;
    channel.onMessage = (RTCDataChannelMessage message) {
      if (message.isBinary != true) return;
      final bytes = message.binary;
      if (bytes.isEmpty) return;

      // State machine: wait for the 4-byte length, then collect exactly that many
      // bytes, then emit one complete pack. Anything else is a protocol error and
      // aborts rather than emitting a truncated pack that would fail a MAC 40 MB
      // later.
      if (_expectedBytes == 0) {
        _inbound.add(bytes);
        if (_inbound.length < 4) return;
        final head = _inbound.toBytes();
        _expectedBytes = (head[0] << 24) | (head[1] << 16) | (head[2] << 8) | head[3];
        _buffer.clear();
        _buffer.add(head.sublist(4));
      } else {
        _buffer.add(bytes);
      }
      if (_buffer.length >= _expectedBytes) {
        _frames.add(_buffer.takeBytes());
        _expectedBytes = 0;
      }
    };
  }

  /// Adds the candidates a ticket carries that its description does not already
  /// mention. Skipping the duplicates matters: a stack that rejects a repeated
  /// candidate line fails the connection for a reason nobody can see.
  Future<void> _addMissingCandidates(
    RTCPeerConnection connection,
    String description,
    List<String> candidates,
  ) async {
    final alreadyDescribed = hostCandidates(description).toSet();
    for (final candidate in candidates) {
      if (alreadyDescribed.contains(candidate)) continue;
      await connection.addCandidate(RTCIceCandidate(candidate, '0', 0));
    }
  }
}

/// Collects host candidates while ICE gathering runs, and completes when gathering
/// finishes or [kIceGatheringTimeout] elapses.
///
/// Attached *before* the first description is set, because gathering starts with
/// `setLocalDescription` and a callback registered afterwards misses the first
/// candidates — the ones that matter on a LAN.
final class _IceTrap {
  _IceTrap(this._connection) {
    _connection.onIceCandidate = (candidate) {
      final line = candidate.candidate;
      // Host candidates only. A reflexive candidate would mean a STUN server.
      if (line != null && line.contains(' typ host')) _hosts.add(line);
    };
    _connection.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !_done.isCompleted) {
        _done.complete();
      }
    };
  }

  final RTCPeerConnection _connection;
  final _hosts = <String>[];
  final _done = Completer<void>();

  Future<List<String>> complete() async {
    // The timer is not a fallback for a slow network: gathering host candidates is
    // local and takes milliseconds. It exists for the phone whose radio is wedged.
    Timer(kIceGatheringTimeout, () {
      if (!_done.isCompleted) _done.complete();
    });
    await _done.future;
    return List.unmodifiable(_hosts);
  }
}
