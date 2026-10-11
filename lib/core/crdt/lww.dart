/// KhataPro · the last-write-wins resolver.
///
/// This is the function that decides what happens when two devices that have
/// been offline for a week both edited the same customer. It runs identically
/// on every device, with no server, no negotiation and no user prompt, and it
/// must satisfy four properties:
///
///   1. **Deterministic** — every device that sees the same two versions picks
///      the same winner. Guaranteed by ordering on `(physical, counter, nodeId)`
///      only; `nodeId` is in the key precisely so that two writes in the same
///      millisecond cannot be ordered by "whichever arrived first locally".
///   2. **Idempotent** — replaying the same remote row changes nothing.
///      (Deliverable 5 depends on this: peers re-send freely.)
///   3. **Commutative** — applying A then B converges to the same state as B
///      then A. The merge of a *set* of rows is therefore order-free, which is
///      what makes the whole no-server sync design safe.
///   4. **Lossless in the sense that matters** — the losing value is never
///      silently dropped. Every field that differed is emitted as a
///      [FieldConflict] for `conflict_log`, so the user can review and reverse
///      a merge they disagree with. (A CRDT cannot preserve both values in one
///      column; pretending otherwise would be dishonest. Preserving the loser
///      *beside* the winner, with a review path, is the honest version of
///      "no data loss".)
///
/// Two situations the rules cannot resolve are reported as [MergeAnomaly]s, at
/// two different strengths — and the difference is deliberate:
///
///   * **Identical stamps, different content** (one writer, one logical instant,
///     two payloads) is *undecidable*: there is no ordering that is correct, only
///     a coin flip. The local copy is kept and the anomaly is **blocking**, so
///     the sync layer stops and asks rather than inventing an answer.
///   * **A revision that went backwards for one writer** (the signature of a
///     restored or rolled-back replica) is *decidable* — the newer HLC still wins
///     and no value is lost — so the merge proceeds and the anomaly is
///     **non-blocking**, a warning the sync layer turns into "ask this peer for a
///     fresh snapshot". Blocking here would strand a shopkeeper who merely
///     restored their phone from a backup, which is a normal Tuesday.
///
/// **Precondition:** every [StampedRow] carries the row's *complete* column set
/// (which the transport guarantees — the oplog re-reads the live row, and
/// tombstones carry `payload_json`). Merge receipts are computed field-by-field
/// against that complete set, so a partial payload would make them
/// order-dependent. This is asserted by the property test in
/// `tool/crdt_verify.dart`.
///
/// Pure Dart, no `package:` imports — property-tested by `tool/crdt_verify.dart`.
library;

import 'stamp.dart';

/// What the merge did.
enum MergeAction {
  /// The incoming row was newer and has replaced the local row.
  applied,

  /// The incoming row was older (or a tombstone that lost); local kept.
  keptLocal,

  /// Same stamp, same content — a replay. Nothing written, nothing logged.
  identical,

  /// The incoming row is newer and un-deletes a tombstoned row. Users do
  /// restore deleted parties; the review card says who did it and when.
  resurrected,
}

/// A single field that differed between the two versions.
///
/// These become rows in `conflict_log`, giving the app a "merge receipt"
/// screen: "Ahmed Traders' phone number was changed at 4:12 pm on Bilal's
/// phone; your edit at 4:15 pm was kept." Nothing is hidden and nothing is
/// unrecoverable — which is the difference between a CRDT users trust and one
/// that quietly eats their data.
final class FieldConflict {
  const FieldConflict({
    required this.rowId,
    required this.tableName,
    required this.field,
    required this.winnerValue,
    required this.loserValue,
    required this.winnerNode,
    required this.loserNode,
    required this.winnerHlc,
    required this.loserHlc,
    required this.resolution,
  });

  final String rowId;
  final String? tableName;
  final String field;
  final Object? winnerValue;
  final Object? loserValue;
  final String winnerNode;
  final String loserNode;
  final String winnerHlc;
  final String loserHlc;

  /// One of `remote_won`, `local_won`, `kept_local_ambiguous`.
  final String resolution;

  /// Stable identity of this receipt, matching the `ux_conflict_receipt`
  /// unique index from migrations/009: **(row, field, losing stamp)**.
  ///
  /// The *winner* is deliberately not part of the key. A losing version can be
  /// superseded by different newer versions on different passes (a peer that
  /// re-sends a stale row compares it against whatever the local state is at
  /// that moment), yet it is still the same loss and deserves exactly one
  /// review card. Keying on the loser's own stamp makes the applier's
  /// `INSERT OR IGNORE` idempotent *across* passes, not merely exact for an
  /// identical batch — which is what keeps the review queue bounded when two
  /// devices disagree for weeks.
  String get receiptKey => '$rowId|$field|$loserHlc';

  Map<String, Object?> toConflictLogRow({
    required String id,
    required int detectedAt,
    String? ledgerId,
  }) =>
      {
        'id': id,
        'ledger_id': ledgerId,
        'table_name': tableName ?? 'unknown',
        'row_id': rowId,
        'field_name': field,
        'kind': 1, // lww_overwrite
        'local_hlc': loserHlc,
        'remote_hlc': winnerHlc,
        'local_node': loserNode,
        'remote_node': winnerNode,
        'local_json': canonicalJson(loserValue),
        'remote_json': canonicalJson(winnerValue),
        'resolution': resolution,
        'detected_at': detectedAt,
      };

  @override
  String toString() => '$tableName.$field: ${canonicalJson(loserValue)} → '
      '${canonicalJson(winnerValue)} ($resolution by $winnerNode)';
}

/// Something the rules cannot resolve. Blocking anomalies must be surfaced to
/// the user (or the peer rejected); non-blocking ones are diagnostics.
final class MergeAnomaly {
  const MergeAnomaly({
    required this.kind,
    required this.detail,
    required this.rowId,
    this.tableName,
    this.blocking = false,
    this.remoteNode,
  });

  /// `same_stamp_different_content` · `revision_not_monotonic` · `row_id_mismatch`
  final String kind;
  final String detail;
  final String rowId;
  final String? tableName;
  final bool blocking;
  final String? remoteNode;

  @override
  String toString() => '[$kind${blocking ? ' BLOCKING' : ''}] $detail';
}

/// The result of merging one remote row into one local row.
final class MergeOutcome {
  const MergeOutcome({
    required this.action,
    required this.winner,
    this.loser,
    this.conflicts = const <FieldConflict>[],
    this.anomalies = const <MergeAnomaly>[],
  });

  final MergeAction action;

  /// The version that survives (equals the local row when the action is
  /// [MergeAction.keptLocal] or [MergeAction.identical]).
  final StampedRow winner;

  /// The version that lost, when there was one. Retained so the caller can
  /// write it to `conflict_log` — this is the "no data loss" guarantee.
  final StampedRow? loser;

  final List<FieldConflict> conflicts;
  final List<MergeAnomaly> anomalies;

  bool get isWrite => action == MergeAction.applied || action == MergeAction.resurrected;
  bool get hasBlockingAnomaly => anomalies.any((a) => a.blocking);
  bool get hasConflicts => conflicts.isNotEmpty;

  @override
  String toString() => 'MergeOutcome(${action.name}, '
      '${conflicts.length} field conflicts, ${anomalies.length} anomalies)';
}

/// The whole-set merge result, used by the sync applier and by tests.
final class MergeBatchResult {
  MergeBatchResult({
    required this.state,
    required this.conflicts,
    required this.anomalies,
    required this.applied,
    required this.keptLocal,
    required this.identical,
    required this.resurrected,
  });

  /// Converged rows, keyed by row id.
  final Map<String, StampedRow> state;
  final List<FieldConflict> conflicts;
  final List<MergeAnomaly> anomalies;
  final int applied;
  final int keptLocal;
  final int identical;
  final int resurrected;

  int get total => applied + keptLocal + identical + resurrected;
  bool get isClean => anomalies.isEmpty;

  @override
  String toString() => 'MergeBatchResult(state: ${state.length} rows, '
      'applied: $applied, keptLocal: $keptLocal, identical: $identical, '
      'resurrected: $resurrected, conflicts: ${conflicts.length}, '
      'anomalies: ${anomalies.length})';
}

/// Stateless resolver. Safe to share; every method is pure.
final class LwwResolver {
  const LwwResolver();

  /// Merge one incoming row into the local copy.
  ///
  /// Throws [ArgumentError] if the rows are for different ids — that would
  /// mean a bug in the caller (a mis-keyed map), and merging across ids is the
  /// sort of silent corruption this class exists to prevent.
  MergeOutcome merge({
    required StampedRow local,
    required StampedRow incoming,
  }) {
    if (local.rowId != incoming.rowId) {
      throw ArgumentError(
        'LWW cannot merge different rows: local=${local.rowId} incoming=${incoming.rowId}',
      );
    }

    final comparison = incoming.stamp.compareTo(local.stamp);

    // ── Case 1 · same stamp ────────────────────────────────────────────────
    if (comparison == 0) {
      if (local.sameContent(incoming)) {
        return MergeOutcome(action: MergeAction.identical, winner: local);
      }
      // One writer, one logical instant, two different payloads. Impossible
      // for a correct writer; either a bug or a forged op. We keep the local
      // copy (deterministic, no flapping) and raise a blocking anomaly rather
      // than silently choosing.
      return MergeOutcome(
        action: MergeAction.keptLocal,
        winner: local,
        loser: incoming,
        conflicts: _diffFields(loser: incoming, winner: local, resolution: 'kept_local_ambiguous'),
        anomalies: [
          MergeAnomaly(
            kind: 'same_stamp_different_content',
            detail: 'stamp ${incoming.stamp} carries two different payloads '
                '(local ${local.canonicalPayload().hashCode.toRadixString(16)}, '
                'remote ${incoming.canonicalPayload().hashCode.toRadixString(16)}); '
                'a writer must never reuse a stamp',
            rowId: local.rowId,
            tableName: local.tableName ?? incoming.tableName,
            blocking: true,
            remoteNode: incoming.stamp.nodeId,
          ),
        ],
      );
    }

    // ── Case 2 · strict ordering by HLC ────────────────────────────────────
    final incomingWins = comparison > 0;
    final winner = incomingWins ? incoming : local;
    final loser = incomingWins ? local : incoming;

    final anomalies = <MergeAnomaly>[];

    // Consistency guard: for a single writer, rev and hlc must advance
    // together. If they disagree, one of the two versions comes from a
    // restored/rolled-back replica — the sync layer should ask that peer to
    // re-send from a snapshot rather than trusting its stream.
    if (winner.stamp.sameWriter(loser.stamp) && winner.stamp.rev <= loser.stamp.rev) {
      anomalies.add(MergeAnomaly(
        kind: 'revision_not_monotonic',
        detail: 'writer ${winner.stamp.nodeId} produced hlc ${winner.stamp.hlc.encode()} '
            'with rev ${winner.stamp.rev} after rev ${loser.stamp.rev}; '
            'the writer\'s state may have been rolled back',
        rowId: local.rowId,
        tableName: local.tableName ?? incoming.tableName,
        remoteNode: incoming.stamp.nodeId,
      ));
    }

    final conflicts = winner.sameContent(loser)
        ? const <FieldConflict>[]
        : _diffFields(
            loser: loser,
            winner: winner,
            resolution: incomingWins ? 'remote_won' : 'local_won',
          );

    final action = switch ((incomingWins, local.isDeleted, incoming.isDeleted)) {
      (false, _, _) => MergeAction.keptLocal,
      (true, _, true) => MergeAction.applied,        // tombstone applied
      (true, true, false) => MergeAction.resurrected, // update beats old tombstone
      (true, false, false) => MergeAction.applied,
    };

    return MergeOutcome(
      action: action,
      winner: winner,
      loser: loser,
      conflicts: conflicts,
      anomalies: anomalies,
    );
  }

  /// Merge a batch, in any order, and return the converged state.
  ///
  /// Order-independence is a property of [merge], so this simply folds. The
  /// proof is not verbal: `tool/crdt_verify.dart` generates random op sets,
  /// applies them under hundreds of permutations, and asserts identical final
  /// state plus a complete conflict ledger.
  MergeBatchResult mergeAll({
    required Map<String, StampedRow> local,
    required Iterable<StampedRow> incoming,
  }) {
    final state = Map<String, StampedRow>.of(local);
    final conflicts = <FieldConflict>[];
    final anomalies = <MergeAnomaly>[];
    var applied = 0;
    var keptLocal = 0;
    var identical = 0;
    var resurrected = 0;

    for (final row in incoming) {
      final current = state[row.rowId];
      if (current == null) {
        // Brand-new replicated row: nothing to resolve.
        state[row.rowId] = row;
        applied++;
        continue;
      }
      final outcome = merge(local: current, incoming: row);
      state[row.rowId] = outcome.winner;
      conflicts.addAll(outcome.conflicts);
      anomalies.addAll(outcome.anomalies);
      switch (outcome.action) {
        case MergeAction.applied:
          applied++;
        case MergeAction.keptLocal:
          keptLocal++;
        case MergeAction.identical:
          identical++;
        case MergeAction.resurrected:
          resurrected++;
      }
    }

    return MergeBatchResult(
      state: state,
      conflicts: conflicts,
      anomalies: anomalies,
      applied: applied,
      keptLocal: keptLocal,
      identical: identical,
      resurrected: resurrected,
    );
  }

  /// Field-by-field receipts for the losing version.
  ///
  /// Note that this catches the genuinely useful case: device A changed the
  /// customer's phone number, device B changed the address. Row-level LWW picks
  /// one row, so one of those edits *is* lost — but both are reported here, the
  /// user sees a review card, and can restore the lost value with one tap.
  /// (Field-level stamps, which would preserve both automatically, are a
  /// schema change: a per-field vector in the oplog payload. Deliberately out
  /// of scope for v1 — the review path gives the same outcome with far less
  /// machinery, and it is honest about what happened.)
  List<FieldConflict> _diffFields({
    required StampedRow loser,
    required StampedRow winner,
    required String resolution,
  }) {
    final result = <FieldConflict>[];
    final winnerPayload = winner.payload;
    final loserPayload = loser.payload;
    final fields = <String>{...winnerPayload.keys, ...loserPayload.keys}..remove('deleted_at');
    final sorted = fields.toList()..sort();

    for (final field in sorted) {
      final winnerValue = winnerPayload[field];
      final loserValue = loserPayload[field];
      if (canonicalJson(winnerValue) == canonicalJson(loserValue)) continue;
      result.add(FieldConflict(
        rowId: winner.rowId,
        tableName: winner.tableName ?? loser.tableName,
        field: field,
        winnerValue: winnerValue,
        loserValue: loserValue,
        winnerNode: winner.stamp.nodeId,
        loserNode: loser.stamp.nodeId,
        winnerHlc: winner.stamp.hlc.encode(),
        loserHlc: loser.stamp.hlc.encode(),
        resolution: resolution,
      ));
    }

    // A tombstone flip is itself a content change worth reporting.
    if (winner.isDeleted != loser.isDeleted) {
      result.add(FieldConflict(
        rowId: winner.rowId,
        tableName: winner.tableName ?? loser.tableName,
        field: 'deleted_at',
        winnerValue: winner.deletedAt,
        loserValue: loser.deletedAt,
        winnerNode: winner.stamp.nodeId,
        loserNode: loser.stamp.nodeId,
        winnerHlc: winner.stamp.hlc.encode(),
        loserHlc: loser.stamp.hlc.encode(),
        resolution: resolution,
      ));
    }
    return result;
  }

  // ───────────────────────────────────────────────────────────────────────
  //  Pre-flight checks used by the writer side (before a local edit is saved)
  // ───────────────────────────────────────────────────────────────────────

  /// Verify the invariant that makes the whole scheme work: a new write's
  /// stamp must be strictly greater than the row's current stamp. If a caller
  /// ever hands us a stale stamp (a cached entity, a background job holding an
  /// old snapshot), this catches it in the app layer rather than letting the
  /// database trigger reject it with a less helpful message.
  static bool isStaleWrite({required StampedRow current, required CrdtStamp proposed}) =>
      proposed.compareTo(current.stamp) <= 0;

  /// Stamp guard for a batch of local edits: returns the ids whose proposed
  /// stamps would not advance the row.
  static List<String> findStaleWrites({
    required Map<String, StampedRow> current,
    required Map<String, CrdtStamp> proposed,
  }) {
    final stale = <String>[];
    for (final entry in proposed.entries) {
      final existing = current[entry.key];
      if (existing != null && isStaleWrite(current: existing, proposed: entry.value)) {
        stale.add(entry.key);
      }
    }
    stale.sort();
    return stale;
  }
}

/// Extension kept out of the public surface (see [MergeBatchResult]).
extension MergeBatchResultDiagnostics on MergeBatchResult {
  /// Human-readable one-liner for the sync health card.
  String get summary => isClean
      ? '$total ops merged cleanly (${conflicts.length} field receipts)'
      : '$total ops merged with ${anomalies.length} anomalies requiring review';
}
