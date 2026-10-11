/// KhataPro · the process-wide clock and stamp factory.
///
/// One instance per process, owned by `DatabaseOpen` and shared by every DAO
/// through Riverpod. It exists as a service (rather than a bare [HlcClock])
/// because the clock has to survive two awkward moments:
///
///   · **App start.** Logical time must not restart at 0, or a device whose
///     real clock is behind would hand out stamps that *lose* to rows it wrote
///     yesterday — and the database's monotonicity guard (INT-7e) would reject
///     the write. So the last emitted stamp is persisted in `session_flags` and
///     restored on open.
///   · **App lock.** When the user locks the app we close the database (the
///     key leaves memory). The clock keeps running so that background
///     notifications still stamp correctly, and it is re-persisted on unlock.
///
/// Pure Dart on purpose: it is exercised by `tool/crdt_verify.dart` and by the
/// data-layer harness without a Flutter toolchain.
library;

import 'hlc.dart';
import 'stamp.dart';

/// A clock value that can be persisted across runs.
abstract interface class HlcPersistence {
  /// Reads the last emitted stamp (null on a fresh install).
  Future<String?> readLastHlc();

  /// Persists the last emitted stamp. Must be cheap: called at most every
  /// [HlcService.persistInterval] writes, never on the write path's critical
  /// section.
  Future<void> writeLastHlc(String hlc);
}

/// In-memory persistence for tests and for the (rare) unlocked-first-run case.
final class MemoryHlcPersistence implements HlcPersistence {
  String? _value;

  @override
  Future<String?> readLastHlc() async => _value;

  @override
  Future<void> writeLastHlc(String hlc) async => _value = hlc;
}

/// Process-wide clock + stamp factory.
final class HlcService {
  HlcService({required this.nodeId, HlcPersistence? persistence})
      : persistence = persistence ?? MemoryHlcPersistence(),
        _clock = HlcClock(nodeId: nodeId);

  /// This device's UUIDv7 (the `nodes.node_id` row).
  final String nodeId;
  final HlcPersistence persistence;
  final HlcClock _clock;

  /// How many writes may pass between persistence flushes. Persisting on every
  /// write would add an fsync to every keystroke-level save; not persisting at
  /// all would let a crash rewind logical time by however much we had advanced.
  /// 64 writes (~a burst of activity) is the balance, and [flush] is also
  /// called on app pause, lock and shutdown.
  static const int persistInterval = 64;

  int _writesSinceFlush = 0;
  Hlc? _lastFlushed;

  /// Wall clock, injectable so tests can drive time deterministically.
  int Function() nowMs = () => DateTime.now().millisecondsSinceEpoch;

  /// The most recent reading emitted.
  Hlc get last => _clock.last;

  /// Diagnostics surfaced in Settings → Sync health.
  List<HlcWarning> get warnings => _clock.warnings;

  /// Loads the persisted stamp and seeds logical time from it. Called once,
  /// during database open, before any write.
  Future<void> load() async {
    final stored = await persistence.readLastHlc();
    if (stored == null) return;
    final parsed = Hlc.tryParse(stored);
    if (parsed == null) return; // corrupt persisted value: start fresh, never throw
    _clock.restore(parsed);
  }

  /// Local write: the stamp for a row this device is touching now.
  CrdtStamp stampForWrite() {
    final stamp = CrdtStamp(hlc: _clock.tick(nowMs()), rev: 1);
    _afterEmit();
    return stamp;
  }

  /// Local update to an existing row: `rev` advances.
  CrdtStamp stampForUpdate(CrdtStamp current) {
    final stamp = current.bump(_clock, nowMs());
    _afterEmit();
    return stamp;
  }

  /// Observe a remote stamp (from an applied batch). Called for every row a
  /// peer sends, so the next local write is ordered after everything seen.
  void observe(Hlc remote) {
    if (remote > _clock.last) _clock.observe(remote, nowMs());
  }

  /// Observe a whole batch in one pass (the sync applier calls this once per
  /// transaction instead of once per row).
  void observeAll(Iterable<Hlc> remotes) {
    final cutoff = _clock.last;
    for (final remote in remotes) {
      if (remote > cutoff) _clock.observe(remote, nowMs());
    }
  }

  /// Force a persist (app pause, lock, shutdown, before a backup).
  Future<void> flush() async {
    final last = _clock.last;
    if (_lastFlushed == last) return;
    await persistence.writeLastHlc(last.encode());
    _lastFlushed = last;
    _writesSinceFlush = 0;
  }

  void _afterEmit() {
    if (++_writesSinceFlush >= persistInterval) {
      // Deliberately not awaited: the write path must not block on I/O. A lost
      // flush costs at most `persistInterval` stamps of clock advancement,
      // which the HLC absorbs on the next open without any correctness impact.
      unawaited(flush());
    }
  }

  @override
  String toString() => 'HlcService($nodeId, last=${_clock.last.encode()})';
}

/// Local `unawaited` so this file needs no `dart:async` import.
void unawaited(Future<void> future) {
  future.ignore();
}
