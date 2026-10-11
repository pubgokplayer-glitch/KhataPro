/// KhataPro · the merge contract.
///
/// "Bulletproof LWW" is the acceptance criterion for this layer, and it decomposes
/// into properties that can be *executed* rather than asserted in prose. A
/// two-phone shop is the running example: the counter phone and the back-office
/// phone, both offline, both editing the same customer.
///
/// What is proven here, in order:
///
///   1. **Deterministic** — the same two versions always pick the same winner.
///   2. **Commutative** — A-then-B and B-then-A converge to the same row.
///   3. **Idempotent** — replaying a batch changes nothing (peers re-send freely).
///   4. **Lossless in the honest sense** — the losing *value* is never discarded
///      silently; it is handed back as a `FieldConflict` for `conflict_log`.
///   5. **Tombstones are writes too** — an old delete cannot kill a newer edit.
///   6. **No guessing** — the two situations the rules cannot decide become
///      blocking anomalies instead of a coin flip.
///
/// Run: `flutter test test/core/crdt_merge_test.dart`
library;

import 'package:khata_pro/core/crdt/hlc.dart';
import 'package:khata_pro/core/crdt/lww.dart';
import 'package:khata_pro/core/crdt/stamp.dart';
import 'package:khata_pro/data/db/dao/base_dao.dart' show contentId;
import 'package:test/test.dart';

const counterPhone = '019a1b2c-0000-7000-8000-0000000000aa';
const officeLaptop = '019a1b2c-0000-7000-8000-0000000000bb';

const resolver = LwwResolver();

/// A customer row as both phones would hold it.
StampedRow party({
  required String node,
  required int ms,
  required int counter,
  required String city,
  String name = 'Ahmed Traders',
  String phone = '03001234567',
  int rev = 1,
  int? deletedAt,
}) => StampedRow(
      rowId: '01a129ec-83d0-7631-b59c-3143b44144f8',
      stamp: CrdtStamp(hlc: Hlc.unchecked(ms, counter, node), rev: rev),
      values: {'name': name, 'city': city, 'phone': phone},
      deletedAt: deletedAt,
      tableName: 'parties',
    );

void main() {
  group('the winner is decided by the clock, not by who arrived first', () {
    test('the later write wins, whichever phone it came from', () {
      final earlier = party(node: counterPhone, ms: 1000, counter: 0, city: 'Sargodha');
      final later = party(node: officeLaptop, ms: 2000, counter: 0, city: 'Lahore');

      final onCounter = resolver.merge(local: earlier, incoming: later);
      final onLaptop = resolver.merge(local: later, incoming: earlier);

      expect(onCounter.action, MergeAction.applied);
      expect(onCounter.winner.values['city'], 'Lahore');
      expect(onLaptop.action, MergeAction.keptLocal);
      expect(onLaptop.winner.values['city'], 'Lahore');
      expect(onCounter.winner.stamp, onLaptop.winner.stamp,
          reason: 'both phones must converge on one row, stamp included');
    });

    test('in the same millisecond the node id breaks the tie — deterministically',
        () {
      final a = party(node: counterPhone, ms: 5000, counter: 0, city: 'A');
      final b = party(node: officeLaptop, ms: 5000, counter: 0, city: 'B');

      final forward = resolver.merge(local: a, incoming: b);
      final backward = resolver.merge(local: b, incoming: a);

      expect(forward.winner.stamp.hlc, backward.winner.stamp.hlc,
          reason: 'a tie broken by anything but the key would flap between devices');
      expect(forward.winner.values['city'], backward.winner.values['city']);
    });

    test('a whole batch converges to the same state in any order (3 offline days)',
        () {
      final monday = party(node: counterPhone, ms: 1000, counter: 0, city: 'Sargodha', rev: 2);
      final tuesday = party(node: officeLaptop, ms: 2000, counter: 3, city: 'Lahore', rev: 5);
      final wednesday = party(node: counterPhone, ms: 3000, counter: 1, city: 'Multan', rev: 3);

      // Every permutation of the *same* two remote writes, over the same local
      // row. This is the shape of a real re-sync: three offline days arriving in
      // whatever order the link happens to deliver them.
      final permutations = [
        [tuesday, wednesday],
        [wednesday, tuesday],
      ];
      final states = {
        for (final order in permutations)
          resolver
              .mergeAll(local: {monday.rowId: monday}, incoming: order)
              .state[monday.rowId]!
              .values['city'],
      };
      expect(states, hasLength(1), reason: 'order-free merge is what makes P2P sync safe');
      expect(states.single, 'Multan', reason: 'the newest write wins from either direction');

      // And the same property from the other side: a phone that already has the
      // newest row converges to the same place when it receives the older ones.
      final fromNewest = resolver.mergeAll(
        local: {wednesday.rowId: wednesday},
        incoming: [monday, tuesday],
      );
      expect(fromNewest.state[monday.rowId]!.values['city'], 'Multan');
    });
  });

  group('replaying a batch is a no-op', () {
    test('the same remote row twice changes the row exactly once', () {
      final local = party(node: counterPhone, ms: 1000, counter: 0, city: 'Sargodha');
      final remote = party(node: officeLaptop, ms: 2000, counter: 0, city: 'Lahore', rev: 4);

      final first = resolver.merge(local: local, incoming: remote);
      final second = resolver.merge(local: first.winner, incoming: remote);

      expect(first.action, MergeAction.applied);
      expect(second.action, MergeAction.identical);
      expect(second.isWrite, isFalse);
      expect(second.conflicts, isEmpty, reason: 'a replay must not re-open a settled conflict');
      expect(second.winner.stamp, first.winner.stamp);
    });

    test('a batch that arrives twice cannot move the row or double the receipts',
        () {
      final local = party(node: counterPhone, ms: 1000, counter: 0, city: 'Sargodha');
      final batch = [
        party(node: officeLaptop, ms: 2000, counter: 0, city: 'Lahore', rev: 2),
        party(node: officeLaptop, ms: 3000, counter: 0, city: 'Multan', rev: 3),
      ];

      final once = resolver.mergeAll(local: {local.rowId: local}, incoming: batch);
      final twice = resolver.mergeAll(local: once.state, incoming: batch);

      expect(once.state[local.rowId]!.values['city'], 'Multan');
      expect(twice.state[local.rowId]!.values['city'], 'Multan');

      // The second pass may re-*notice* that the old Lahore row lost to Multan,
      // but it must not write anything: no applied writes, no new convergence.
      expect(twice.applied, 0);
      expect(twice.resurrected, 0);
      expect(twice.state[local.rowId]!.stamp, once.state[local.rowId]!.stamp);

      // And every conflict it re-notices carries the same content-addressed id as
      // the first pass, so `conflict_log`'s INSERT OR IGNORE collapses it. That
      // is what makes a re-sync free of duplicate review items.
      for (final conflict in twice.conflicts) {
        expect(
          // Note what is *not* in the id: the resolution string. The same pair of
          // versions reads as `remote_won` on the phone that received it and
          // `local_won` on the phone that held it, so a perspective-dependent id
          // would file one disagreement twice.
          contentId('conflict', [
            conflict.tableName ?? '',
            conflict.rowId,
            conflict.field,
            conflict.loserHlc,
            conflict.winnerHlc,
          ]),
          isIn([
            for (final first in once.conflicts)
              contentId('conflict', [
                first.tableName ?? '',
                first.rowId,
                first.field,
                first.loserHlc,
                first.winnerHlc,
              ]),
          ]),
          reason: 'a replayed conflict must land on the receipt already stored',
        );
      }
    });
  });

  group('the loser is never silently dropped', () {
    test('a beaten edit is handed back field by field, with both values', () {
      final local = party(node: counterPhone, ms: 1000, counter: 0, city: 'Sargodha');
      final remote = party(
        node: officeLaptop,
        ms: 2000,
        counter: 0,
        city: 'Lahore',
        phone: '03211234567',
      );

      final outcome = resolver.merge(local: local, incoming: remote);

      expect(outcome.hasConflicts, isTrue);
      final cities = outcome.conflicts.where((c) => c.field == 'city').toList();
      expect(cities, hasLength(1));
      expect(cities.single.winnerValue, 'Lahore');
      expect(cities.single.loserValue, 'Sargodha',
          reason: 'this value is what conflict_log stores for the user to review');
      expect(cities.single.winnerNode, officeLaptop);
      expect(cities.single.loserNode, counterPhone);
      expect(outcome.conflicts.where((c) => c.field == 'name'), isEmpty,
          reason: 'fields that agree must not generate noise');
    });
  });

  group('deletes are writes, and they lose to newer edits', () {
    test('a stale tombstone cannot kill a newer edit', () {
      final deletedEarlier = party(
        node: officeLaptop,
        ms: 1000,
        counter: 0,
        city: 'Lahore',
        deletedAt: 1000,
      );
      final editedLater = party(node: counterPhone, ms: 9000, counter: 0, city: 'Sargodha');

      final outcome = resolver.merge(local: deletedEarlier, incoming: editedLater);

      expect(outcome.action, MergeAction.resurrected,
          reason: 'a party restored on one phone must not be killed again by an old delete');
      expect(outcome.winner.isDeleted, isFalse);
      expect(outcome.winner.values['city'], 'Sargodha');
    });

    test('a newer delete does delete', () {
      final local = party(node: counterPhone, ms: 1000, counter: 0, city: 'Sargodha');
      final deleted = party(
        node: officeLaptop,
        ms: 8000,
        counter: 0,
        city: 'Sargodha',
        deletedAt: 8000,
      );

      final outcome = resolver.merge(local: local, incoming: deleted);

      expect(outcome.action, MergeAction.applied);
      expect(outcome.winner.isDeleted, isTrue);
    });
  });

  group('the two undecidable cases block instead of guessing', () {
    test('the same stamp carrying different content is refused, not coin-flipped',
        () {
      final local = party(node: counterPhone, ms: 1000, counter: 0, city: 'Sargodha');
      final forged = party(node: counterPhone, ms: 1000, counter: 0, city: 'Karachi');

      final outcome = resolver.merge(local: local, incoming: forged);

      expect(outcome.action, MergeAction.keptLocal);
      expect(outcome.hasBlockingAnomaly, isTrue);
      expect(outcome.anomalies.single.kind, 'same_stamp_different_content');
    });

    test('a revision that goes backwards is reported but does not strand the device',
        () {
      final local = party(node: counterPhone, ms: 5000, counter: 0, city: 'Lahore', rev: 9);
      final restoredBackup =
          party(node: counterPhone, ms: 6000, counter: 0, city: 'Sargodha', rev: 2);

      final outcome = resolver.merge(local: local, incoming: restoredBackup);

      expect(outcome.anomalies.map((a) => a.kind), contains('revision_not_monotonic'));
      // Deliberately NOT blocking: the newer HLC still wins, no value is lost,
      // and refusing here would strand a shopkeeper who restored their phone
      // from a backup. The sync layer turns this into "ask that peer for a fresh
      // snapshot" instead of an error the user cannot act on.
      expect(outcome.hasBlockingAnomaly, isFalse);
      expect(outcome.action, MergeAction.applied);
      expect(outcome.winner.values['city'], 'Sargodha');
      expect(outcome.loser!.values['city'], 'Lahore',
          reason: 'the pre-rollback value is still handed to conflict_log');
    });
  });

  group('the stamp itself is the guarantee', () {
    test('encoded stamps sort as strings in exactly causal order', () {
      final stamps = [
        Hlc.unchecked(1000, 0, counterPhone),
        Hlc.unchecked(1000, 1, counterPhone),
        Hlc.unchecked(999, 999, officeLaptop),
        Hlc.unchecked(1000, 0, officeLaptop),
      ];

      final byValue = [...stamps]..sort();
      final encoded = [for (final stamp in stamps) stamp.encode()];

      expect(encoded, hasLength(stamps.length));
      // The oplog is ordered by the text column, so text order must equal causal
      // order: sorting the strings must produce the same sequence as sorting the
      // objects. If this ever diverges, sync cursors silently skip rows.
      expect([...encoded]..sort(),
          equals([for (final stamp in byValue) stamp.encode()]));
      expect(byValue.first.physicalMs, 999,
          reason: 'an earlier millisecond loses even with the largest counter');
      expect(byValue[1].physicalMs, 1000,
          reason: 'then the same millisecond is broken by the counter…');
      expect(byValue[1].counter, 0);
      expect(byValue[1].nodeId, counterPhone,
          reason: '…and within a counter, by node id');
    });
  });
}
