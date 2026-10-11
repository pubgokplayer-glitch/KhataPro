/// KhataPro · Hybrid Logical Clock.
///
/// An HLC is `(physical milliseconds, logical counter, node id)` — a wall clock
/// glued to a Lamport counter so that
///
///   1. time never goes backwards, even when the device clock does, and
///   2. two events on two devices are *totally* ordered without any
///      coordination, which is precisely what a server-free CRDT needs.
///
/// The encoding is intentionally fixed-width (57 characters):
///
///     `00000001800000000:0001:11111111-1111-7111-8111-000000000001`
///      └── 15 digits ──┘ └4 hex┘ └────────── 36 UUID ──────────┘
///
/// Because every field is zero-padded, SQLite's ordinary BINARY collation
/// orders the encoded strings *exactly* as causal time orders them. That single
/// property is why the sync layer needs no custom collation, no per-row parsing
/// during a delta scan, and no index on anything but a plain TEXT column.
///
/// The class is pure Dart (no `package:` imports) so it can be exercised by
/// `tool/crdt_verify.dart` and property-tested without a Flutter toolchain.
library;


/// Why a warning was raised. Warnings are advisory, never fatal.
enum HlcWarningKind {
  /// A peer's physical clock is far ahead of ours; its stamp was clamped for
  /// the purpose of advancing *our* clock (the row keeps the peer's own stamp).
  remoteClockAhead,

  /// A peer's physical clock is far behind; harmless, noted for diagnostics.
  remoteClockBehind,

  /// 65 536 events inside one millisecond — the counter rolled into a new ms.
  counterOverflow,

  /// The device clock jumped backwards; logical time absorbed the shock.
  localClockWentBackwards,
}

final class HlcWarning {
  const HlcWarning(this.kind, this.detail, this.atMs);
  final HlcWarningKind kind;
  final String detail;
  final int atMs;

  @override
  String toString() => '${kind.name}: $detail';
}

/// An immutable hybrid logical clock reading.
final class Hlc implements Comparable<Hlc> {
  /// Fast constructor for trusted internal call sites (skips UUID validation).
  const Hlc.unchecked(this.physicalMs, this.counter, this.nodeId);

  factory Hlc.of({
    required int physicalMs,
    required int counter,
    required String nodeId,
  }) {
    if (physicalMs < 0 || physicalMs > maxPhysicalMs) {
      throw ArgumentError.value(physicalMs, 'physicalMs', 'out of range 0..$maxPhysicalMs');
    }
    if (counter < 0 || counter > maxCounter) {
      throw ArgumentError.value(counter, 'counter', 'out of range 0..$maxCounter');
    }
    if (!isValidNodeId(nodeId)) {
      throw ArgumentError.value(nodeId, 'nodeId', 'must be a lowercase 36-char UUID');
    }
    return Hlc.unchecked(physicalMs, counter, nodeId);
  }

  /// Milliseconds since the Unix epoch, as the *writer* observed it.
  final int physicalMs;

  /// Logical counter disambiguating events inside the same millisecond.
  final int counter;

  /// The writing device's UUIDv7. Also the final tie-breaker of the order.
  final String nodeId;

  static const int maxCounter = 0xFFFF;
  static const int maxPhysicalMs = 999999999999999; // 15 digits
  static const int encodedLength = 57;
  static const int physicalDigits = 15;
  static const int counterDigits = 4;
  static const int nodeIdLength = 36;

  /// The smallest possible HLC: used for seeded rows, seeds and "beginning of
  /// time" cursors. Zero HLCs lose to every real write, which is what makes
  /// seed data merge-cost-free across independently installed devices.
  factory Hlc.zero(String nodeId) => Hlc.unchecked(0, 0, nodeId);

  factory Hlc.seed() => const Hlc.unchecked(0, 0, seedNodeId);

  /// Synthetic node id used by 007_seed.sql for deterministic seed rows.
  static const String seedNodeId = '00000000-0000-7000-8000-000000000000';

  // ── encoding ────────────────────────────────────────────────────────────

  /// The 57-character form stored in `hlc` columns and compared bytewise.
  ///
  /// **Fixed width or nothing.** Every field is zero-padded to its exact width and
  /// the node id must be a 36-character UUID, because that is the *only* reason
  /// SQLite's BINARY ordering over these strings equals causal ordering. A shorter
  /// node id would still sort, silently, in the wrong order — so it is refused here,
  /// at the moment of writing, rather than discovered during a merge.
  String encode() {
    if (!isValidNodeId(nodeId)) {
      throw ArgumentError.value(
        nodeId,
        'nodeId',
        'must be a 36-character UUID: the fixed width is what makes bytewise '
            'ordering causal (see docs/DATA_LAYER.md)',
      );
    }
    if (physicalMs < 0 || physicalMs > maxPhysicalMs) {
      throw ArgumentError.value(
        physicalMs,
        'physicalMs',
        'does not fit in $physicalDigits digits — a clock this far from 1970 means '
            'the device clock is wrong, not that the format is too small',
      );
    }
    return [
      physicalMs.toString().padLeft(physicalDigits, '0'),
      counter.toRadixString(16).padLeft(counterDigits, '0'),
      nodeId,
    ].join(':');
  }

  /// Strict parse. Rejects anything that would break bytewise ordering — a
  /// lenient parser here would silently corrupt causal ordering, which is the
  /// one thing the sync layer cannot recover from.
  static Hlc parse(String encoded) {
    final result = tryParse(encoded);
    if (result == null) {
      throw FormatException('malformed HLC (expected $encodedLength chars '
          'PPPPPPPPPPPPPPP:CCCC:<uuid>)', encoded);
    }
    return result;
  }

  static Hlc? tryParse(String encoded) {
    if (encoded.length != encodedLength) return null;
    if (encoded[physicalDigits] != ':' || encoded[physicalDigits + 1 + counterDigits] != ':') {
      return null;
    }
    final physicalPart = encoded.substring(0, physicalDigits);
    final counterPart = encoded.substring(
        physicalDigits + 1, physicalDigits + 1 + counterDigits);
    final nodePart = encoded.substring(physicalDigits + 1 + counterDigits + 1);

    for (final unit in physicalPart.codeUnits) {
      if (unit < 0x30 || unit > 0x39) return null; // must be zero-padded decimal
    }
    for (final unit in counterPart.codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isLowerHex = unit >= 0x61 && unit <= 0x66;
      if (!isDigit && !isLowerHex) return null;
    }
    if (!isValidNodeId(nodePart)) return null;

    final physical = int.tryParse(physicalPart);
    final counter = int.tryParse(counterPart, radix: 16);
    if (physical == null || counter == null) return null;
    return Hlc.unchecked(physical, counter, nodePart);
  }

  static bool isValidNodeId(String nodeId) {
    if (nodeId.length != nodeIdLength) return false;
    for (var i = 0; i < nodeId.length; i++) {
      final unit = nodeId.codeUnitAt(i);
      final isDash = unit == 0x2D;
      final isHex = (unit >= 0x30 && unit <= 0x39) || (unit >= 0x61 && unit <= 0x66);
      if (!isDash && !isHex) return false;
    }
    // Standard UUID dash positions (8-4-4-4-12).
    return nodeId[8] == '-' && nodeId[13] == '-' && nodeId[18] == '-' && nodeId[23] == '-';
  }

  // ── ordering ────────────────────────────────────────────────────────────

  /// Causal then arbitrary (but deterministic) order: physical, counter, node.
  /// The node-id tie-break is what makes two devices that write in the same
  /// millisecond with the same counter converge on the same winner forever —
  /// no arbitration, and no re-flapping on the next sync round.
  @override
  int compareTo(Hlc other) {
    if (physicalMs != other.physicalMs) return physicalMs.compareTo(other.physicalMs);
    if (counter != other.counter) return counter.compareTo(other.counter);
    return nodeId.compareTo(other.nodeId);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator <=(Hlc other) => compareTo(other) <= 0;
  bool operator >(Hlc other) => compareTo(other) > 0;
  bool operator >=(Hlc other) => compareTo(other) >= 0;

  bool sameNode(Hlc other) => nodeId == other.nodeId;

  /// True when this reading comes from [other]'s writer at a strictly earlier
  /// logical instant.
  bool isBefore(Hlc other) => compareTo(other) < 0;

  int get asEpochMs => physicalMs;

  @override
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  // A value type: every field is final and instances are compared by
  // value. The class stays free of package imports so it can run in a
  // bare Dart process (see tool/crdt_verify.dart).
  bool operator ==(Object other) =>
      other is Hlc &&
      other.physicalMs == physicalMs &&
      other.counter == counter &&
      other.nodeId == nodeId;

  @override
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  // A value type: every field is final and instances are compared by
  // value. The class stays free of package imports so it can run in a
  // bare Dart process (see tool/crdt_verify.dart).
  int get hashCode => Object.hash(physicalMs, counter, nodeId);

  /// Wire form for the oplog and backup packs: the encoded string, so the
  /// 57-char invariant is exercised on every round-trip.
  String toJson() => encode();

  static Hlc fromJson(Object? value) {
    if (value is! String) throw FormatException('HLC must be a string, got ${value.runtimeType}');
    return parse(value);
  }

  @override
  String toString() => encode();
}

/// Mutable clock that produces monotonic [Hlc] readings for one device.
///
/// One instance per process (see `HlcService`), fed by [tick] for local writes
/// and [observe] for every incoming remote stamp — including your own stamps
/// read back from the database on startup, which is what stops a clock that
/// went backwards from handing out stamps the database's monotonicity guard
/// would then reject.
final class HlcClock {
  HlcClock({required this.nodeId, int? startPhysicalMs})
      : _physical = startPhysicalMs ?? 0,
        _counter = 0 {
    if (!Hlc.isValidNodeId(nodeId)) {
      throw ArgumentError.value(nodeId, 'nodeId', 'must be a lowercase 36-char UUID');
    }
  }

  /// How far ahead of local time a peer's stamp may drag our clock. Beyond
  /// this we clamp for *local advancement* purposes (the peer's own row keeps
  /// its original stamp, untouched) so one phone with a broken clock cannot
  /// push every subsequent local write into the year 3000.
  static const int maxDriftMs = 5 * 60 * 1000;

  /// How many anomalies to retain for diagnostics before dropping the oldest.
  static const int maxWarnings = 50;

  final String nodeId;
  int _physical;
  int _counter;
  final List<HlcWarning> _warnings = [];
  final List<HlcWarning> _allWarnings = [];

  /// Readings emitted so far (diagnostics + tests).
  int _emitted = 0;
  int get emittedCount => _emitted;

  /// The most recent reading; also the value to persist as `last_hlc` so the
  /// next process start resumes logical time instead of restarting it.
  Hlc get last => Hlc.unchecked(_physical, _counter, nodeId);

  /// Recent warnings (bounded ring — never grows without limit in a long-lived
  /// process, which matters on a device that stays open for days).
  List<HlcWarning> get warnings => List.unmodifiable(_warnings);

  /// Every warning since construction, for the diagnostics screen.
  List<HlcWarning> get allWarnings => List.unmodifiable(_allWarnings);

  int get physicalMs => _physical;
  int get counter => _counter;

  /// Resume from the last persisted reading after an app restart, so logical
  /// time never regresses across sessions.
  void restore(Hlc lastSeen) {
    if (lastSeen.physicalMs > _physical ||
        (lastSeen.physicalMs == _physical && lastSeen.counter > _counter)) {
      _physical = lastSeen.physicalMs;
      _counter = lastSeen.counter;
    }
  }

  /// Local event (a write by this device).
  ///
  /// `tick(nowMs)`:
  ///   · clock advanced            → adopt wall time, reset the counter
  ///   · clock same or went back   → keep logical time, bump the counter
  Hlc tick(int nowMs) {
    if (nowMs > _physical) {
      _physical = nowMs;
      _counter = 0;
    } else {
      if (nowMs < _physical) {
        _warn(HlcWarningKind.localClockWentBackwards,
            'device clock reports ${nowMs - _physical} ms earlier than logical time; '
            'keeping logical time ahead', nowMs);
      }
      _counter++;
      if (_counter > Hlc.maxCounter) {
        _physical++;
        _counter = 0;
        _warn(HlcWarningKind.counterOverflow,
            'more than ${Hlc.maxCounter + 1} events in one millisecond', nowMs);
      }
    }
    return _emit();
  }

  /// Remote event (an oplog row or replicated snapshot from a peer).
  ///
  /// Returns the **local clock after absorbing the remote reading** — which is
  /// always strictly greater than the remote stamp, so the next local write is
  /// correctly ordered after everything we have seen. This is the standard HLC
  /// receive rule; the deviation worth noting is the clamping at
  /// [maxDriftMs], which trades a sliver of theoretical causal fidelity for
  /// immunity to a peer with a badly wrong clock.
  Hlc observe(Hlc remote, int nowMs) {
    var remotePhysical = remote.physicalMs;
    if (remotePhysical > nowMs + maxDriftMs) {
      _warn(HlcWarningKind.remoteClockAhead,
          'peer ${remote.nodeId} is ${(remotePhysical - nowMs) ~/ 1000}s ahead; '
          'clamping to +${maxDriftMs ~/ 1000}s for local advancement '
          '(their stored stamp is unchanged)', nowMs);
      remotePhysical = nowMs + maxDriftMs;
    } else if (nowMs - remotePhysical > maxDriftMs) {
      _warn(HlcWarningKind.remoteClockBehind,
          'peer ${remote.nodeId} is ${(nowMs - remotePhysical) ~/ 1000}s behind', nowMs);
    }

    final maxPhysical = _max3(_physical, nowMs, remotePhysical);
    if (maxPhysical == _physical && maxPhysical == remotePhysical) {
      _counter = (counter > remote.counter ? counter : remote.counter) + 1;
    } else if (maxPhysical == _physical) {
      _counter++;
    } else if (maxPhysical == remotePhysical) {
      _counter = remote.counter + 1;
    } else {
      _counter = 0;
    }
    if (_counter > Hlc.maxCounter) {
      _physical = maxPhysical + 1;
      _counter = 0;
      _warn(HlcWarningKind.counterOverflow, 'counter overflow while merging a remote stamp', nowMs);
      return _emit();
    }
    _physical = maxPhysical;
    return _emit();
  }

  /// Absorb many remote stamps (a whole applied batch) in one pass.
  Hlc observeAll(Iterable<Hlc> remotes, int nowMs) {
    for (final remote in remotes) {
      if (remote.compareTo(last) > 0) observe(remote, nowMs);
    }
    return last;
  }

  Hlc _emit() {
    _emitted++;
    return Hlc.unchecked(_physical, _counter, nodeId);
  }

  void _warn(HlcWarningKind kind, String detail, int atMs) {
    final warning = HlcWarning(kind, detail, atMs);
    _allWarnings.add(warning);
    _warnings.add(warning);
    if (_warnings.length > maxWarnings) _warnings.removeAt(0);
  }

  static int _max3(int a, int b, int c) {
    var m = a;
    if (b > m) m = b;
    if (c > m) m = c;
    return m;
  }

  @override
  String toString() => 'HlcClock($nodeId @ ${last.encode()})';
}
