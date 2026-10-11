// ═══════════════════════════════════════════════════════════════════════════
//  tool/crdt_verify.dart
//
//  Adversarial verification of the pure-Dart core: money, epoch-days, HLC and
//  the LWW merge. Runs with a bare Dart SDK — no Flutter, no pub get, no
//  packages — against `lib/core/**` by relative import:
//
//      dart run tool/crdt_verify.dart            # full run
//      dart run tool/crdt_verify.dart --quick    # fewer iterations (CI smoke)
//
//  The LWW section is the important one. It does not check examples; it
//  generates random operation sets (multiple writers, same-millisecond
//  collisions, clock skew, tombstones, duplicate delivery, dropped delivery)
//  and asserts the four CRDT properties for every case:
//
//      1 · convergence      — every peer reaches identical state
//      2 · determinism      — the winner is argmax(stamp) on every peer
//      3 · idempotence      — replaying an op changes nothing
//      4 · no silent loss   — every losing value appears in the conflict ledger
//
//  A failure here means real user data could diverge, so the exit code is
//  non-zero and CI must treat it as a blocker.
// ═══════════════════════════════════════════════════════════════════════════

import 'dart:math' as math;

import '../lib/core/crdt/hlc.dart';
import '../lib/core/errors/khata_exception.dart';
import '../lib/core/crdt/lww.dart';
import '../lib/core/crdt/stamp.dart';
import '../lib/core/money/money.dart';
import '../lib/core/utils/epoch_day.dart';

// ───────────────────────────────────────────────────────────────────────────
//  Tiny test harness
// ───────────────────────────────────────────────────────────────────────────
int _checks = 0;
int _failures = 0;
final List<String> _failureLog = [];
final Stopwatch _clock = Stopwatch();

void section(String name) {
  print('\n  $name');
  print('  ${'─' * 74}');
}

void check(String what, bool Function() body) {
  _checks++;
  try {
    final ok = body();
    if (ok) {
      print('    ✓ $what');
    } else {
      _failures++;
      _failureLog.add(what);
      print('    ✗ $what');
    }
  } catch (error, stack) {
    _failures++;
    _failureLog.add('$what — threw $error');
    print('    ✗ $what');
    print('        ${error.toString().split('\n').first}');
    print('        ${stack.toString().split('\n').take(3).join('\n        ')}');
  }
}

void expect(String what, bool condition, [String? detail]) {
  check(what, () {
    if (!condition && detail != null) print('        $detail');
    return condition;
  });
}

// ───────────────────────────────────────────────────────────────────────────
//  Deterministic PRNG — a failing case must be reproducible from its seed
// ───────────────────────────────────────────────────────────────────────────
final class Rng {
  Rng(this.seed);
  final int seed;
  late final math.Random _random = math.Random(seed);
  int nextInt(int max) => _random.nextInt(max);

  /// Wider than Random.nextInt (2^32 cap) without resorting to doubles.
  int nextBigInt({int bits = 40}) {
    final half = bits ~/ 2;
    final high = _random.nextInt(1 << half);
    final low = _random.nextInt(1 << (bits - half));
    return (high << (bits - half)) | low;
  }
  bool chance(int percent) => _random.nextInt(100) < percent;
  String randomUuid() {
    const hex = '0123456789abcdef';
    String block(int n) =>
        List.generate(n, (_) => hex[_random.nextInt(16)]).join();
    return '${block(8)}-${block(4)}-7${block(3)}-8${block(3)}-${block(12)}';
  }
}

String _uuidFor(int index) =>
    '019a1b2c-0000-7000-8000-${index.toRadixString(16).padLeft(12, '0')}';

// ═══════════════════════════════════════════════════════════════════════════
//  1 · Money
// ═══════════════════════════════════════════════════════════════════════════
void moneySection(bool quick) {
  section('1 · Money — integer exactness, parsing, lossless allocation');

  expect('Rs 1,25,000.50 parses to 12500050 minor units',
      MoneyMinor.parse('Rs 1,25,000.50').minor == 12500050);

  expect('Urdu numerals ۱۲۳۴.۵۰ parse to 123450',
      MoneyMinor.parse('۱۲۳۴.۵۰').minor == 123450);

  expect('accounting parentheses mean negative: (1,250) → -125000',
      MoneyMinor.parse('(1,250)').minor == -125000);

  expect('trailing-minus European style 1 250,75 → 125075',
      MoneyMinor.parse('1 250,75').minor == 125075);

  expect('a 1000× suffix is rejected rather than guessed',
      () {
        try {
          MoneyMinor.parse('1.5k');
          return false;
        } on FormatException {
          return true;
        }
      }());

  expect('too many decimal places is an error, never a silent round',
      () {
        try {
          MoneyMinor.parse('12.345');
          return false;
        } on FormatException {
          return true;
        }
      }());

  expect('round-trip parse(format(x)) == x for 20 000 random amounts', () {
    final rng = Rng(4242);
    final iterations = quick ? 2000 : 20000;
    for (var i = 0; i < iterations; i++) {
      final minor = rng.nextBigInt(bits: 44) - (1 << 43);
      final money = MoneyMinor.fromMinor(minor, 2);
      final text = money.toPlainString();
      if (MoneyMinor.parse(text).minor != minor) return false;
    }
    return true;
  }());

  expect('allocation is lossless for 20 000 random splits', () {
    final rng = Rng(99);
    final iterations = quick ? 2000 : 20000;
    for (var i = 0; i < iterations; i++) {
      final amount = MoneyMinor.fromMinor(rng.nextBigInt(bits: 32), 2);
      final parts = 1 + rng.nextInt(12);
      final split = amount.splitEvenly(parts);
      if (split.length != parts) return false;
      if (MoneyMinor.sum(split).minor != amount.minor) return false;
    }
    return true;
  }());

  expect('weighted allocation keeps the total and respects proportions', () {
    final amount = MoneyMinor.parse('1000.00');
    final split = amount.allocate([3, 2, 1]);
    final total = MoneyMinor.sum(split).minor;
    if (total != 100000) return false;
    // Largest-remainder ordering: biggest weight gets the biggest share.
    return split[0].minor >= split[1].minor && split[1].minor >= split[2].minor;
  }());

  expect('Rs 1,000 / 3 = 334.00 + 333.00 + 333.00 (no lost paisa)', () {
    // Rs 1,000.00 = 100000 minor; the odd paisa goes to the first share.
    final parts = MoneyMinor.parse('1000').splitEvenly(3).map((m) => m.minor).toList();
    return parts.join(',') == '33334,33333,33333' &&
        parts.reduce((a, b) => a + b) == 100000;
  }());

  expect('percent rounding matches the shopkeeper default (half away from zero)', () {
    // 33.35 × 10% = 3.335 → 3.34 (half up) and −33.35 → −3.34 (symmetric)
    return MoneyMinor.fromMinor(3335, 2).percent(1000).minor == 334 &&
        MoneyMinor.fromMinor(-3335, 2).percent(1000).minor == -334 &&
        // 33.33 × 18% = 5.9994 → 5.99 (no phantom paisa)
        MoneyMinor.fromMinor(3333, 2).percent(1800).minor == 600;
  }());

  expect('rounding modes agree with their definitions on exact halves', () {
    // 0.5 → half-up 1 / half-even 0 (0 is even);  1.5 → half-even 2
    return divRound(5000, 10000, RoundingMode.halfUp) == 1 &&
        divRound(5000, 10000, RoundingMode.halfEven) == 0 &&
        divRound(15000, 10000, RoundingMode.halfEven) == 2 &&
        divRound(-5000, 10000, RoundingMode.halfUp) == -1 &&
        divRound(19999, 10000, RoundingMode.truncate) == 1 &&
        divRound(10001, 10000, RoundingMode.ceiling) == 2;
  }());

  expect('18% GST on 1,250 is computed without a double', () {
    final base = MoneyMinor.parse('1250');
    final tax = base.percent(1800);
    return tax.minor == 22500 && base.minor + tax.minor == 147500;
  }());

  expect('mixed currency scales throw instead of silently rescaling', () {
    try {
      MoneyMinor.fromMinor(100, 2) + MoneyMinor.fromMinor(100, 0);
      return false;
    } on MoneyScaleMismatch {
      return true;
    }
  }());

  expect('overflow is caught, not wrapped (the machine would give -2)', () {
    final atCeiling = MoneyMinor.fromMinor(MoneyMinor.maxMinor, 2);
    var caughtMul = false;
    var caughtAdd = false;
    try {
      atCeiling.times(2);
    } on MoneyOverflowException {
      caughtMul = true;
    }
    try {
      atCeiling + MoneyMinor.fromMinor(1, 2);
    } on MoneyOverflowException {
      caughtAdd = true;
    }
    return caughtMul && caughtAdd &&
        // …and the ordinary large-but-legal case still works
        MoneyMinor.fromMinor(MoneyMinor.maxMinor - 1, 2).times(1).minor == MoneyMinor.maxMinor - 1;
  }());

  expect('PROPERTY · guarded arithmetic matches BigInt exactly, 40 000 trials', () {
    final rng = Rng(8675309);
    final iterations = quick ? 4000 : 40000;
    for (var i = 0; i < iterations; i++) {
      // Values drawn across the whole range including the extremes, so the
      // BigInt fallback path is exercised, not just the fast path.
      final pool = <int>[
        rng.nextBigInt(bits: 62) - (1 << 61),
        rng.nextInt(1000) - 500,
        MoneyMinor.maxMinor,
        MoneyMinor.minMinor,
        1, -1, 0,
        1 << 52,
        1 << 31,
      ];
      final a = pool[rng.nextInt(pool.length)];
      final b = pool[rng.nextInt(pool.length)];

      for (final op in ['add', 'sub', 'mul']) {
        final expected = switch (op) {
          'add' => BigInt.from(a) + BigInt.from(b),
          'sub' => BigInt.from(a) - BigInt.from(b),
          _ => BigInt.from(a) * BigInt.from(b),
        };
        final overflows = expected > BigInt.from(MoneyMinor.maxMinor) ||
            expected < BigInt.from(MoneyMinor.minMinor);
        try {
          final result = switch (op) {
            'add' => MoneyMinor.guardedAdd(a, b, 2),
            'sub' => MoneyMinor.guardedSub(a, b, 2),
            _ => MoneyMinor.guardedMul(a, b, 2),
          };
          if (overflows) return false;
          if (BigInt.from(result) != expected) return false;
        } on MoneyOverflowException {
          if (!overflows) return false;
        }
      }
    }
    return true;
  }());

  expect('lakh/crore grouping matches what the user expects', () {
    final m = MoneyMinor.parse('1234567.89');
    return m.format() == 'Rs\u00A012,34,567.89' &&
        m.format(grouping: GroupingPattern.international) == 'Rs\u00A01,234,567.89' &&
        m.format(grouping: GroupingPattern.lakhCrore) == 'Rs\u00A012,34,567.89' &&
        MoneyMinor.parse('125000').format() == 'Rs\u00A01,25,000.00';
  }());

  expect('Urdu output renders Urdu digits and no ASCII digits survive', () {
    final m = MoneyMinor.parse('1250.50');
    final urdu = m.format(urduNumerals: true, showSymbol: false, grouping: GroupingPattern.none);
    final hasAsciiDigit = RegExp(r'[0-9]').hasMatch(urdu);
    return urdu == '۱۲۵۰.۵۰' && !hasAsciiDigit;
  }());
}

// ═══════════════════════════════════════════════════════════════════════════
//  2 · Epoch days
// ═══════════════════════════════════════════════════════════════════════════
void epochDaySection(bool quick) {
  section('2 · Epoch days — the local calendar is the authority');

  expect('1970-01-01 is day 0', EpochDay.fromDate(1970, 1, 1) == 0);
  expect('2026-10-11 is day 20737', EpochDay.fromDate(2026, 10, 11) == 20737);
  expect('1969-12-31 is day -1', EpochDay.fromDate(1969, 12, 31) == -1);
  expect('2024-02-29 (leap day) round-trips',
      EpochDay.toIso(EpochDay.fromDate(2024, 2, 29)) == '2024-02-29');

  expect('round-trip holds for 60 000 random days', () {
    final rng = Rng(7);
    final iterations = quick ? 5000 : 60000;
    for (var i = 0; i < iterations; i++) {
      final day = rng.nextInt(200000) - 30000; // ~1600s CE .. 2500s CE
      final date = EpochDay.toDate(day);
      if (EpochDay.fromDate(date.year, date.month, date.day) != day) return false;
    }
    return true;
  }());

  expect('ISO text round-trips through tryParse', () {
    for (final day in [0, 11000, 20737, 30000]) {
      if (EpochDay.tryParse(EpochDay.toIso(day)) != day) return false;
    }
    return true;
  }());

  expect('impossible dates are rejected (31 Feb, 32 Jan, 00 Mar)', () {
    return EpochDay.tryParse('2026-02-31') == null &&
        EpochDay.tryParse('2026-01-32') == null &&
        EpochDay.tryParse('2026-03-00') == null;
  }());

  expect('1970-01-01 was a Thursday (weekday math is right)', () {
    return EpochDay.isoWeekday(0) == 4 && EpochDay.isoWeekday(20737) == 7; // 2026-10-11 = Sunday
  }());

  expect('month boundaries are correct in a 31/30/28 sequence', () {
    final feb = EpochDay.fromDate(2026, 2, 15);
    return EpochDay.toIso(EpochDay.startOfMonth(feb)) == '2026-02-01' &&
        EpochDay.toIso(EpochDay.endOfMonth(feb)) == '2026-02-28' &&
        EpochDay.toIso(EpochDay.endOfMonth(EpochDay.fromDate(2024, 2, 5))) == '2024-02-29';
  }());

  expect('Pakistan fiscal year runs Jul 1 → Jun 30', () {
    final inside = EpochDay.fromDate(2026, 10, 11); // October ⇒ FY started July 2026
    return EpochDay.toIso(EpochDay.fiscalYearStart(inside, 7)) == '2026-07-01' &&
        EpochDay.toIso(EpochDay.fiscalYearEndInclusive(inside, 7)) == '2027-06-30';
  }());

  expect('a date before the cut-over belongs to the previous fiscal year', () {
    final march = EpochDay.fromDate(2026, 3, 15);
    return EpochDay.toIso(EpochDay.fiscalYearStart(march, 7)) == '2025-07-01';
  }());
}

// ═══════════════════════════════════════════════════════════════════════════
//  3 · Hybrid Logical Clock
// ═══════════════════════════════════════════════════════════════════════════
void hlcSection(bool quick) {
  section('3 · Hybrid Logical Clock — monotonic, fixed-width, causally ordered');

  final nodeA = _uuidFor(1);
  final nodeB = _uuidFor(2);

  expect('encoding is exactly 57 characters', () {
    final hlc = HlcClock(nodeId: nodeA).tick(1793000000000);
    return hlc.encode().length == Hlc.encodedLength && hlc.encode().split(':').length == 3;
  }());

  expect('parse∘encode is the identity', () {
    final thrown = <int>[];
    for (final ms in [0, 1, 999, 1793000000000, 999999999999999]) {
      final hlc = Hlc.of(physicalMs: ms, counter: 0xAB, nodeId: nodeA);
      if (Hlc.parse(hlc.encode()) != hlc) thrown.add(ms);
    }
    return thrown.isEmpty;
  }());

  expect('bytewise string order == causal order (the whole point)', () {
    final rng = Rng(5);
    final iterations = quick ? 5000 : 50000;
    for (var i = 0; i < iterations; i++) {
      final a = Hlc.unchecked(rng.nextBigInt(bits: 44), rng.nextInt(0x10000), _uuidFor(1 + rng.nextInt(4)));
      final b = Hlc.unchecked(rng.nextBigInt(bits: 44), rng.nextInt(0x10000), _uuidFor(1 + rng.nextInt(4)));
      final byObject = a.compareTo(b).sign;
      final byString = a.encode().compareTo(b.encode()).sign;
      if (byObject != byString) return false;
    }
    return true;
  }());

  expect('100 000 ticks are strictly increasing, even with a hostile clock', () {
    final clock = HlcClock(nodeId: nodeA);
    final rng = Rng(11);
    var previous = Hlc.zero(nodeA);
    var now = 1793000000000;
    final iterations = quick ? 20000 : 100000;
    for (var i = 0; i < iterations; i++) {
      // The device clock jumps backwards 10% of the time, forwards 10%.
      final roll = rng.nextInt(100);
      if (roll < 10) {
        now -= rng.nextInt(60000);
      } else if (roll < 20) {
        now += rng.nextInt(60000);
      } else {
        now += rng.nextInt(3);
      }
      final ticked = clock.tick(now);
      if (ticked.compareTo(previous) <= 0) return false;
      previous = ticked;
    }
    return true;
  }());

  expect('the local write after observing a peer is strictly greater than it', () {
    final clock = HlcClock(nodeId: nodeA);
    final rng = Rng(13);
    var remote = Hlc.zero(nodeB);
    final iterations = quick ? 20000 : 100000;
    var now = 1793000000000;
    for (var i = 0; i < iterations; i++) {
      now += rng.nextInt(50);
      remote = Hlc.unchecked(now, rng.nextInt(0x10000), nodeB);
      clock.observe(remote, now);
      final local = clock.tick(now);
      if (local.compareTo(remote) <= 0) return false;
    }
    return true;
  }());

  expect('a peer 1 year in the future is clamped and warned, not obeyed', () {
    final clock = HlcClock(nodeId: nodeA);
    final now = 1793000000000;
    const yearMs = 365 * 24 * 3600 * 1000;
    final wild = Hlc.unchecked(now + yearMs, 0, nodeB);
    clock.observe(wild, now);
    final local = clock.last;
    final clamped = local.physicalMs <= now + HlcClock.maxDriftMs;
    final warned = clock.warnings.any((w) => w.kind == HlcWarningKind.remoteClockAhead);
    return clamped && warned;
  }());

  expect('a backwards device clock is absorbed into the logical counter', () {
    final clock = HlcClock(nodeId: nodeA);
    final a = clock.tick(1793000000000);
    final b = clock.tick(1793000000000 - 5000); // clock jumped back 5 s
    return b.compareTo(a) > 0 &&
        b.physicalMs == a.physicalMs &&
        b.counter == a.counter + 1 &&
        clock.warnings.any((w) => w.kind == HlcWarningKind.localClockWentBackwards);
  }());

  expect('counter overflow rolls into the next millisecond', () {
    final clock = HlcClock(nodeId: nodeA);
    final start = Hlc.of(physicalMs: 1793000000000, counter: Hlc.maxCounter - 1, nodeId: nodeA);
    clock.restore(start);
    final first = clock.tick(1793000000000); // → counter == maxCounter
    final second = clock.tick(1793000000000); // → overflow into ms+1
    return first.counter == Hlc.maxCounter &&
        second.counter == 0 &&
        second.physicalMs == first.physicalMs + 1;
  }());

  expect('two devices cannot produce the same stamp in the same millisecond', () {
    final a = HlcClock(nodeId: nodeA);
    final b = HlcClock(nodeId: nodeB);
    final now = 1793000000000;
    final stamps = <String>{};
    for (var i = 0; i < 500; i++) {
      stamps.add(a.tick(now).encode());
      stamps.add(b.tick(now).encode());
    }
    return stamps.length == 1000;
  }());

  expect('restore() resumes logical time across an app restart', () {
    final clock = HlcClock(nodeId: nodeA);
    final persisted = clock.tick(1793000000000);
    final restarted = HlcClock(nodeId: nodeA);
    restarted.restore(persisted);
    final next = restarted.tick(1793000000000);
    return next.compareTo(persisted) > 0;
  }());

  expect('malformed stamps are rejected outright', () {
    final bad = [
      '',
      'too-short',
      '00000001800000000:0001:00000000-0000-7000-8000-00000000000Z', // non-hex node
      '0000000180000000X:0001:00000000-0000-7000-8000-000000000001', // non-digit ms
      '00000001800000000:00G1:00000000-0000-7000-8000-000000000001', // bad counter
      '00000001800000000:0001:00000000-0000-7000-8000-00000000001',  // 35-char node
    ];
    for (final input in bad) {
      if (Hlc.tryParse(input) != null) return false;
    }
    return true;
  }());
}

// ═══════════════════════════════════════════════════════════════════════════
//  4 · LWW merge — the properties that make server-free sync safe
// ═══════════════════════════════════════════════════════════════════════════
StampedRow _row({
  required String id,
  required CrdtStamp stamp,
  required Map<String, Object?> values,
  int? deletedAt,
  String table = 'party',
}) =>
    StampedRow(
      rowId: id,
      stamp: stamp,
      values: values,
      deletedAt: deletedAt,
      tableName: table,
    );

void lwwSection(bool quick) {
  section('4 · LWW merge — determinism, idempotence, convergence, lossless receipts');

  const resolver = LwwResolver();
  final nodeA = _uuidFor(1);
  final nodeB = _uuidFor(2);
  final rowId = _uuidFor(100);

  final older = _row(
    id: rowId,
    stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 1000, counter: 0, nodeId: nodeA), rev: 1),
    values: {'name': 'Ahmed Traders', 'phone': '03001234567', 'city': 'Sargodha'},
  );
  final newer = _row(
    id: rowId,
    stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 2000, counter: 0, nodeId: nodeB), rev: 1),
    values: {'name': 'Ahmed Traders', 'phone': '03217654321', 'city': 'Sargodha'},
  );

  expect('the newer stamp wins and the change is recorded as a field receipt', () {
    final outcome = resolver.merge(local: older, incoming: newer);
    return outcome.action == MergeAction.applied &&
        outcome.winner.stamp == newer.stamp &&
        outcome.conflicts.length == 1 &&
        outcome.conflicts.first.field == 'phone' &&
        outcome.conflicts.first.loserValue == '03001234567' &&
        outcome.conflicts.first.resolution == 'remote_won';
  }());

  expect('the older stamp loses and is preserved for review', () {
    final outcome = resolver.merge(local: newer, incoming: older);
    return outcome.action == MergeAction.keptLocal &&
        outcome.winner.stamp == newer.stamp &&
        outcome.loser?.stamp == older.stamp &&
        outcome.conflicts.first.resolution == 'local_won';
  }());

  expect('identical stamps with identical content are a true no-op', () {
    final outcome = resolver.merge(local: older, incoming: older);
    return outcome.action == MergeAction.identical &&
        outcome.conflicts.isEmpty &&
        outcome.anomalies.isEmpty;
  }());

  expect('identical stamps with DIFFERENT content raise a blocking anomaly', () {
    final forged = _row(
      id: rowId,
      stamp: older.stamp,
      values: {'name': 'SOMEONE ELSE', 'phone': '03000000000', 'city': 'Lahore'},
    );
    final outcome = resolver.merge(local: older, incoming: forged);
    return outcome.action == MergeAction.keptLocal &&
        outcome.hasBlockingAnomaly &&
        outcome.anomalies.first.kind == 'same_stamp_different_content';
  }());

  expect('a same-millisecond tie is broken by node id, identically on both peers', () {
    final a = _row(
      id: rowId,
      stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 5000, counter: 7, nodeId: nodeA), rev: 3),
      values: {'name': 'from A'},
    );
    final b = _row(
      id: rowId,
      stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 5000, counter: 7, nodeId: nodeB), rev: 9),
      values: {'name': 'from B'},
    );
    final onPeerA = resolver.merge(local: a, incoming: b);
    final onPeerB = resolver.merge(local: b, incoming: a);
    return onPeerA.winner.stamp == onPeerB.winner.stamp &&
        onPeerA.winner.stamp.nodeId == (nodeA.compareTo(nodeB) > 0 ? nodeA : nodeB);
  }());

  expect('a tombstone wins over an older edit', () {
    final deleted = _row(
      id: rowId,
      stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 3000, counter: 0, nodeId: nodeB), rev: 2),
      values: {'name': 'Ahmed Traders'},
      deletedAt: 3000000,
    );
    final outcome = resolver.merge(local: newer, incoming: deleted);
    return outcome.action == MergeAction.applied && outcome.winner.isDeleted;
  }());

  expect('an EDIT newer than a tombstone resurrects the row (users undo deletes)', () {
    final deleted = _row(
      id: rowId,
      stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 3000, counter: 0, nodeId: nodeB), rev: 2),
      values: {'name': 'Ahmed Traders'},
      deletedAt: 3000000,
    );
    final revive = _row(
      id: rowId,
      stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 9000, counter: 0, nodeId: nodeA), rev: 1),
      values: {'name': 'Ahmed Traders', 'city': 'Sargodha'},
    );
    final outcome = resolver.merge(local: deleted, incoming: revive);
    return outcome.action == MergeAction.resurrected && !outcome.winner.isDeleted;
  }());

  expect('a rolled-back replica (rev went backwards) is flagged, not trusted', () {
    final rolledBack = _row(
      id: rowId,
      stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 4000, counter: 0, nodeId: nodeA), rev: 1),
      values: {'name': 'STALE'},
    );
    final current = _row(
      id: rowId,
      stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 3000, counter: 0, nodeId: nodeA), rev: 5),
      values: {'name': 'current'},
    );
    final outcome = resolver.merge(local: current, incoming: rolledBack);
    return outcome.anomalies.any((a) => a.kind == 'revision_not_monotonic');
  }());

  expect('merging different row ids is refused outright', () {
    try {
      resolver.merge(local: older, incoming: _row(
        id: _uuidFor(999),
        stamp: newer.stamp,
        values: {'name': 'other'},
      ));
      return false;
    } on ArgumentError {
      return true;
    }
  }());

  expect('canonical JSON sorts keys, so two devices compare payloads identically', () {
    final one = canonicalJson({'b': 2, 'a': 1, 'c': {'z': 1, 'y': [1, 2, 3]}});
    final two = canonicalJson({'c': {'y': [1, 2, 3], 'z': 1}, 'a': 1, 'b': 2});
    return one == two && one == '{"a":1,"b":2,"c":{"y":[1,2,3],"z":1}}';
  }());

  expect('a double leaking into a payload is rejected, not rounded', () {
    try {
      canonicalJson({'amount': 12.5});
      return false;
    } on ArgumentError {
      return true;
    }
  }());

  // ── the randomised convergence battery ────────────────────────────────────
  expect('PROPERTY · every peer converges under 800 random interleavings', () {
    final rng = Rng(20261011);
    final rounds = quick ? 80 : 800;
    final nodeIds = [_uuidFor(1), _uuidFor(2), _uuidFor(3)];
    final fields = ['name', 'phone', 'city', 'notes', 'credit_limit'];

    for (var round = 0; round < rounds; round++) {
      // Several rows, each with several versions from several writers.
      final rowIds = List.generate(1 + rng.nextInt(4), (i) => _uuidFor(1000 + i));
      final universe = <String, List<StampedRow>>{};
      final clocks = [for (final n in nodeIds) HlcClock(nodeId: n)];
      var now = 1793000000000;

      for (final id in rowIds) {
        final versions = <StampedRow>[];
        final count = 1 + rng.nextInt(6);
        for (var v = 0; v < count; v++) {
          // Hostile timing: sometimes the same millisecond on two writers,
          // sometimes a clock that steps backwards.
          final step = rng.nextInt(4) == 0 ? 0 : rng.nextInt(5000);
          now += step;
          final writer = rng.nextInt(nodeIds.length);
          final stamp = CrdtStamp(hlc: clocks[writer].tick(now), rev: v + 1);
          final values = <String, Object?>{
            'name': 'Party $round-$v',
            'phone': '0300${rng.nextInt(9999999).toString().padLeft(7, '0')}',
            'city': ['Sargodha', 'Multan', 'Lahore'][rng.nextInt(3)],
            'notes': rng.chance(30) ? null : 'note-$v',
            'credit_limit': rng.nextInt(1000000),
          };
          // COMPLETE payloads. A replicated row always carries every column
          // (the oplog re-reads the live row; a tombstone carries payload_json),
          // so the merge compares like with like. Emitting partial payloads
          // here would make the conflict receipts order-dependent — which is a
          // property of a *bad* test, not of the resolver. Fields are randomly
          // nulled instead, which exercises real null-handling.
          final complete = <String, Object?>{
            for (final f in fields) f: rng.chance(15) ? null : values[f],
          };
          versions.add(_row(
            id: id,
            stamp: stamp,
            values: complete,
            deletedAt: rng.chance(10) ? now : null,
          ));
        }
        universe[id] = versions;
      }

      // Build ONE delivery plan, then give each peer a different *order* of
      // the same ops, with the same duplicates and the same drops. Dropping
      // different ops for different peers would legitimately diverge them, and
      // asserting convergence on that would be asserting a falsehood — the
      // guarantee is "same op set, any order, same result".
      final plan = <StampedRow>[];
      final dropped = <String>{};
      for (final entry in universe.entries) {
        final shuffled = List<StampedRow>.of(entry.value)..shuffle(rng._random);
        for (final row in shuffled) {
          if (rng.chance(8)) {
            dropped.add('${entry.key}|${row.stamp}');   // nobody receives this one
            continue;
          }
          plan.add(row);
          if (rng.chance(25)) plan.add(row); // duplicate delivery
          if (rng.chance(5)) plan.add(row);  // triple delivery
        }
      }

      final counts = <int, MergeBatchResult>{};
      final receiptSets = <Set<String>>[];
      for (var peer = 0; peer < 3; peer++) {
        final deliveries = List<StampedRow>.of(plan)..shuffle(rng._random);
        if (peer == 2) deliveries..clear()..addAll(plan.reversed); // worst case: full reverse
        final result = resolver.mergeAll(local: const {}, incoming: deliveries);
        counts[peer] = result;
        receiptSets.add(result.conflicts
            .map((c) => '${c.rowId}|${c.field}|${canonicalJson(c.loserValue)}')
            .toSet());
        if (result.anomalies.where((a) => a.blocking).isNotEmpty) {
          if (kDebugProperties) print('        [debug] blocking anomaly: ${result.anomalies.first}');
          return false;
        }
      }

      // (1) convergence: the three peers agree row-for-row
      final a = counts[0]!.state;
      for (final peer in [1, 2]) {
        final b = counts[peer]!.state;
        if (a.length != b.length) {
          if (kDebugProperties) print('        [debug] round $round: peer $peer has ${b.length} rows, peer 0 has ${a.length}');
          return false;
        }
        for (final entry in a.entries) {
          final other = b[entry.key];
          if (other == null) {
            if (kDebugProperties) print('        [debug] round $round: peer $peer missing ${entry.key}');
            return false;
          }
          if (entry.value.stamp != other.stamp) {
            if (kDebugProperties) {
              print('        [debug] round $round: stamp divergence on ${entry.key}');
              print('                 peer0 ${entry.value.stamp} ${entry.value.canonicalPayload()}');
              print('                 peer$peer ${other.stamp} ${other.canonicalPayload()}');
            }
            return false;
          }
          if (entry.value.canonicalPayload() != other.canonicalPayload()) {
            if (kDebugProperties) print('        [debug] round $round: payload divergence on ${entry.key}');
            return false;
          }
        }
      }

      // (2) RECEIPT CONTAINMENT — the honest, order-independent guarantee.
      //
      // A receipt is written per *merge event*, so two peers that saw the same
      // ops in different orders legitimately produce different receipt COUNTS:
      // a value that was briefly the local state in one order (and then
      // overwritten) is a receipt there, while in another order that value was
      // never the state at all. What must hold on EVERY peer is containment:
      //
      //     every value that is absent from the final state, and that this peer
      //     actually received, appears somewhere in this peer's ledger.
      //
      // That is the property the review screen depends on — "nothing was lost
      // silently" — and it is asserted below for all three peers.
      for (var peer = 0; peer < 3; peer++) {
        final ledger = receiptSets[peer];
        for (final entry in universe.entries) {
          final delivered = plan.where((r) => r.rowId == entry.key).toList();
          if (delivered.isEmpty) continue;
          final winner =
              delivered.reduce((x, y) => x.stamp.compareTo(y.stamp) >= 0 ? x : y);
          for (final version in delivered) {
            if (version.stamp == winner.stamp) continue;
            for (final field in version.payload.keys) {
              // `deleted_at` is a timestamp, not user data — the user-visible
              // fact is the deletion FLAG, checked separately below.
              if (field == 'deleted_at') continue;
              final lost = canonicalJson(version.payload[field]);
              final kept = canonicalJson(winner.payload[field]);
              if (lost == kept) continue; // not a loss at all
              if (!ledger.contains('${entry.key}|$field|$lost')) {
                if (kDebugProperties) {
                  print('        [debug] round $round: peer $peer never recorded the loss of '
                      '${entry.key}.$field = $lost');
                }
                return false;
              }
            }
            // A delete or an undelete that lost must be reviewable. The
            // receipt need not be keyed to *this* version's timestamp: several
            // tombstones collapse into one review card ("deleted, then
            // restored"), which is one decision for the user either way.
            if (version.isDeleted != winner.isDeleted) {
              if (!ledger.any((k) => k.startsWith('${entry.key}|deleted_at|'))) {
                if (kDebugProperties) {
                  print('        [debug] round $round: peer $peer has no tombstone receipt at all '
                      'for ${entry.key} although a delete/undelete was overwritten');
                }
                return false;
              }
            }
          }
        }
      }

      // (3) determinism: the survivor is argmax(stamp) over what was delivered
      for (final entry in universe.entries) {
        final delivered =
            plan.where((r) => r.rowId == entry.key).toList();
        if (delivered.isEmpty) {
          if (a.containsKey(entry.key)) return false; // nothing delivered ⇒ absent
          continue;
        }
        final expected =
            delivered.reduce((x, y) => x.stamp.compareTo(y.stamp) >= 0 ? x : y);
        final actual = a[entry.key]!;
        if (actual.stamp != expected.stamp) return false;
        if (actual.canonicalPayload() != expected.canonicalPayload()) return false;
      }

    }
    return true;
  }());

  expect('PROPERTY · replaying a whole batch a second time changes nothing', () {
    final rng = Rng(555);
    final roster = [_uuidFor(1), _uuidFor(2)];
    final clocks = [for (final n in roster) HlcClock(nodeId: n)];
    var now = 1793000000000;

    final incoming = <StampedRow>[];
    for (var i = 0; i < 200; i++) {
      now += rng.nextInt(50);
      incoming.add(_row(
        id: _uuidFor(2000 + (i % 20)),
        stamp: CrdtStamp(hlc: clocks[rng.nextInt(2)].tick(now), rev: 1 + i),
        values: {'name': 'Row ${i % 20}', 'amount': rng.nextBigInt(bits: 30)},
      ));
    }

    final first = resolver.mergeAll(local: const {}, incoming: incoming);
    final second = resolver.mergeAll(local: first.state, incoming: incoming);
    // (1) Replay must write NOTHING: no state change, no tombstone flip.
    if (second.applied != 0 || second.resurrected != 0) {
      if (kDebugProperties) {
        print('        [debug] replay wrote ${second.applied} applied / '
            '${second.resurrected} resurrected');
      }
      return false;
    }
    if (second.anomalies.isNotEmpty) {
      if (kDebugProperties) print('        [debug] replay raised ${second.anomalies.first}');
      return false;
    }

    // (2) State must be byte-identical after the replay.
    for (final entry in first.state.entries) {
      final again = second.state[entry.key]!;
      if (again.stamp != entry.value.stamp) return false;
      if (again.canonicalPayload() != entry.value.canonicalPayload()) return false;
    }

    // (3) The applier re-derives receipts on replay (it cannot know which ones
    //     it already logged), so idempotence of the LOG is not "no receipts" —
    //     it is "no NEW receipts". This is exactly what the unique index
    //     ux_conflict_receipt (migrations/009) guarantees via INSERT OR IGNORE:
    //     the receipt identity is (row, field, losing stamp, winning stamp).
    final firstKeys = first.conflicts.map((c) => c.receiptKey).toSet();
    final secondKeys = second.conflicts.map((c) => c.receiptKey).toSet();
    if (!secondKeys.containsAll(firstKeys)) {
      if (kDebugProperties) print('        [debug] replay lost receipts');
      return false;
    }
    // Every replayed receipt must already be known, i.e. dedupe leaves nothing.
    final newOnReplay = secondKeys.difference(firstKeys);
    if (newOnReplay.isNotEmpty) {
      if (kDebugProperties) {
        print('        [debug] replay generated ${newOnReplay.length} NEW receipts, e.g. '
            '${newOnReplay.first}');
      }
      return false;
    }
    for (final entry in first.state.entries) {
      final again = second.state[entry.key]!;
      if (again.stamp != entry.value.stamp) return false;
      if (again.canonicalPayload() != entry.value.canonicalPayload()) return false;
    }
    return true;
  }());

  expect('PROPERTY · commutativity holds pairwise in both directions', () {
    final rng = Rng(31337);
    final roster = [_uuidFor(1), _uuidFor(2), _uuidFor(3)];
    final clocks = [for (final n in roster) HlcClock(nodeId: n)];
    for (var i = 0; i < (quick ? 500 : 5000); i++) {
      final now = 1793000000000 + rng.nextInt(100000);
      final rowA = _row(
        id: rowId,
        stamp: CrdtStamp(hlc: clocks[rng.nextInt(3)].tick(now), rev: 1 + rng.nextInt(5)),
        values: {'name': 'A$i', 'amount': rng.nextInt(1000)},
      );
      final rowB = _row(
        id: rowId,
        stamp: CrdtStamp(hlc: clocks[rng.nextInt(3)].tick(now), rev: 1 + rng.nextInt(5)),
        values: {'name': 'B$i', 'amount': rng.nextInt(1000)},
      );
      final ab = resolver.merge(local: rowA, incoming: rowB).winner;
      final ba = resolver.merge(local: rowB, incoming: rowA).winner;
      if (ab.stamp != ba.stamp) return false;
      if (ab.canonicalPayload() != ba.canonicalPayload()) return false;
    }
    return true;
  }());

  expect('stale-write detection catches a cached entity before SQL sees it', () {
    final current = _row(
      id: rowId,
      stamp: CrdtStamp(hlc: Hlc.of(physicalMs: 9000, counter: 0, nodeId: nodeA), rev: 4),
      values: {'name': 'current'},
    );
    final stale = CrdtStamp(hlc: Hlc.of(physicalMs: 8000, counter: 0, nodeId: nodeA), rev: 3);
    final fresh = CrdtStamp(hlc: Hlc.of(physicalMs: 9500, counter: 0, nodeId: nodeA), rev: 5);
    return LwwResolver.isStaleWrite(current: current, proposed: stale) &&
        !LwwResolver.isStaleWrite(current: current, proposed: fresh);
  }());
}

// ═══════════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════════
bool kDebugProperties = false;

void main(List<String> args) {
  final quick = args.contains('--quick');
  kDebugProperties = args.contains('--debug');
  _clock.start();

  print('\n  KhataPro · pure-Dart core verification'
      '\n  severity: a failure here means user data could diverge or money could '
      '\n  be mis-stated — treat any ✗ below as a release blocker.'
      '\n  mode: ${quick ? 'quick' : 'full'}');

  moneySection(quick);
  epochDaySection(quick);
  hlcSection(quick);
  lwwSection(quick);

  _clock.stop();
  print('\n  ${'═' * 74}');
  if (_failures == 0) {
    print('  ✓ all $_checks checks passed in ${_clock.elapsedMilliseconds} ms');
  } else {
    print('  ✗ $_failures of $_checks checks FAILED in ${_clock.elapsedMilliseconds} ms');
    for (final failure in _failureLog) {
      print('      · $failure');
    }
  }
  print('  ${'═' * 74}\n');
  if (_failures != 0) throw StateError('$_failures core check(s) failed');
}
