/// KhataPro · what happens when a batch of someone else's changes arrives.
///
/// The transport (WebRTC or a backup pack) delivers *bytes*. This file turns those
/// bytes into a decision, and the decision has exactly three possible answers:
///
///  1. **Apply the whole batch, or none of it.** A batch is one transaction. A
///     ledger that is half-merged from another device is worse than one that is not
///     merged at all: the trial balance would disagree with the journal lines, which
///     is precisely the state the Deliverable 2 gate exists to prevent. So the batch
///     goes in through one `inTransaction`, and a `GATE-2` finding rolls the whole
///     thing back.
///
///  2. **Refuse anything unsigned.** A batch carries a MAC taken under a key derived
///     from the pairing, and a batch id that is a content hash. Anyone on the café
///     Wi-Fi can send bytes to a data channel that has been offered; only a paired
///     peer can produce a batch this file will accept. Replays are then free: the
///     same batch id arriving twice is a no-op rather than a double-posted sale.
///
///  3. **Say what happened.** [ApplyOutcome] reports applied/skipped/conflicted
///     counts and the gate findings, so the sync screen can tell the shopkeeper
///     "12 changes came in from the other phone" rather than "sync complete", which
///     tells them nothing.
///
/// ## What this file deliberately leaves out
///
/// It does **not** know how to write rows of a particular table. That mapping —
/// table name → column list → stamp comparison → upsert or tombstone — lives behind
/// [OpApplier], because it is per-table SQL and belongs next to the DAOs (Deliverable
/// 4's `lib/sync/crdt/`), where the schema's own triggers and generated columns are
/// visible. Defining the seam here keeps the *contract* (atomic, gated, idempotent,
/// ordered) in one testable place while the SQL grows table by table.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/crdt/hlc.dart';
import '../../core/crdt/stamp.dart';
import '../../core/errors/khata_exception.dart';
import '../../core/security/hasher.dart';
import '../../core/security/kdf.dart';

/// One change, as it travels: which row, which field set, under whose stamp.
final class SyncOp {
  const SyncOp({
    required this.table,
    required this.rowId,
    required this.stamp,
    required this.payload,
    this.tombstone = false,
  });

  final String table;
  final String rowId;
  final CrdtStamp stamp;

  /// The row's columns as they stood at [stamp]. JSON rather than column-by-column
  /// fields so a schema change (a new nullable column) does not need a protocol
  /// version bump: the applier ignores keys it does not know and leaves them at
  /// their defaults.
  final Map<String, Object?> payload;

  /// True when this op says "this row is deleted". Tombstones travel as ops rather
  /// than as absences, because "I deleted it" and "I never heard of it" are
  /// different statements — see the Deliverable 2 merge contract.
  final bool tombstone;

  Map<String, Object?> toJson() => {
        't': table,
        'r': rowId,
        // The stamp's node id travels inside the encoded HLC — which is what makes
        // SQLite's BINARY ordering over `hlc TEXT` the causal order (see
        // `docs/DATA_LAYER.md`), so there is no separate node field to disagree
        // with the stamp.
        'h': stamp.hlc.encode(),
        'v': stamp.rev,
        'p': payload,
        if (tombstone) 'x': true,
      };

  static SyncOp fromJson(Map<String, Object?> json) => SyncOp(
        table: '${json['t']}',
        rowId: '${json['r']}',
        stamp: CrdtStamp(
          hlc: Hlc.parse('${json['h']}'),
          rev: (json['v'] as num).toInt(),
        ),
        payload: ((json['p'] as Map?) ?? const {}).cast<String, Object?>(),
        tombstone: json['x'] == true,
      );
}

/// A batch of changes from one peer, covering one HLC range.
final class SyncBatch {
  SyncBatch({
    required this.senderNodeId,
    required this.ledgerId,
    required this.ops,
    required this.sentAtMs,
    this.generation = 0,
  });

  final String senderNodeId;
  final String ledgerId;
  final List<SyncOp> ops;
  final int sentAtMs;

  /// Increments per batch from one sender, so a gap is visible ("the other phone
  /// has sent 41 batches; I have seen 39") without a central counter.
  final int generation;

  static const int currentVersion = 1;

  /// The batch's identity: a hash over its content. Two things follow, and both are
  /// what make replay safe:
  ///   * the same batch always has the same id, so applying it twice is detectable;
  ///   * any edit to the content changes the id, so the MAC below covers the identity.
  ///
  /// Ops are hashed in canonical order (sorted by HLC, then row id), so two peers
  /// that carry the same changes in a different arrival order produce the same id —
  /// otherwise a re-send after a reshuffle would look like a new batch and be
  /// applied twice.
  String get id => _hashOf(_canonicalJson());

  List<SyncOp> get orderedOps {
    final sorted = [...ops]..sort((a, b) {
        final byStamp = a.stamp.hlc.compareTo(b.stamp.hlc);
        if (byStamp != 0) return byStamp;
        return a.rowId.compareTo(b.rowId);
      });
    return sorted;
  }

  Map<String, Object?> toJson() => {
        'v': currentVersion,
        'from': senderNodeId,
        'ledger': ledgerId,
        'at': sentAtMs,
        'gen': generation,
        'ops': [for (final op in ops) op.toJson()],
      };

  static SyncBatch fromJson(Map<String, Object?> json) {
    final version = (json['v'] as num?)?.toInt();
    if (version != currentVersion) {
      throw InvariantViolation(
        invariantCode: 'SYNC-10',
        message: 'this device sent sync batches in v$version format; this app reads '
            'v$currentVersion. Update both phones before syncing.',
      );
    }
    final ops = [
      for (final op in (json['ops'] as List? ?? const []))
        SyncOp.fromJson((op as Map).cast<String, Object?>()),
    ];
    return SyncBatch(
      senderNodeId: '${json['from']}',
      ledgerId: '${json['ledger']}',
      sentAtMs: (json['at'] as num?)?.toInt() ?? 0,
      generation: (json['gen'] as num?)?.toInt() ?? 0,
      ops: ops,
    );
  }

  String _canonicalJson() {
    // Rebuilt from orderedOps, so the hash does not depend on arrival order.
    final ordered = SyncBatch(
      senderNodeId: senderNodeId,
      ledgerId: ledgerId,
      sentAtMs: sentAtMs,
      generation: generation,
      ops: orderedOps,
    );
    return canonicalJson(ordered.toJson());
  }
}

/// The batch, framed for a data channel or a file: a length prefix, a version, the
/// JSON, and a MAC.
///
/// The MAC key is derived from the pairing secret with its own `info` string, so the
/// same pairing secret can also key the payload encryption without the two ever
/// colliding. A batch without a valid MAC is dropped before it is parsed — the
/// receiver never touches attacker-shaped JSON.
abstract final class BatchCodec {
  static const String macInfo = 'khata-pro/sync/batch-mac/v1';

  static Uint8List macKeyFor(Uint8List pairingSecret) =>
      hkdfSha256(ikm: pairingSecret, info: utf8Encode(macInfo), length: 32);

  static Uint8List encode(SyncBatch batch, Uint8List pairingSecret) {
    final json = utf8.encode(canonicalJson(batch.toJson()));
    final header = Uint8List.fromList([SyncBatch.currentVersion]);
    final mac = HmacSha256(key: macKeyFor(pairingSecret))
        .compute(Uint8List.fromList([...header, ...json]));
    final body = Uint8List.fromList([...header, ...json, ...mac]);
    return Uint8List(4 + body.length)
      ..[0] = (body.length >> 24) & 0xff
      ..[1] = (body.length >> 16) & 0xff
      ..[2] = (body.length >> 8) & 0xff
      ..[3] = body.length & 0xff
      ..setRange(4, body.length + 4, body);
  }

  static SyncBatch decode(Uint8List frame, Uint8List pairingSecret) {
    // 4-byte length prefix, version byte, at least one content byte, 32-byte MAC.
    if (frame.length < 4 + 1 + 1 + 32) {
      throw const InvariantViolation(
        invariantCode: 'SYNC-11',
        message: 'the batch is too short to be one',
      );
    }
    final body = Uint8List.sublistView(frame, 4);
    final version = body[0];
    if (version != SyncBatch.currentVersion) {
      throw InvariantViolation(
        invariantCode: 'SYNC-10',
        message: 'sync batch v$version is not readable by this app '
            '(v${SyncBatch.currentVersion})',
      );
    }
    final macStart = body.length - 32;
    final expected = HmacSha256(key: macKeyFor(pairingSecret))
        .compute(Uint8List.sublistView(body, 0, macStart));
    final actual = Uint8List.sublistView(body, macStart);
    if (!constantTimeEquals(expected, actual)) {
      // Refused before parsing: an unauthenticated batch is not JSON, it is noise
      // from whoever else is on this Wi-Fi.
      throw const InvariantViolation(
        invariantCode: 'SYNC-12',
        message: 'this sync batch is not signed by a device you paired with, so it '
            'was ignored',
      );
    }
    final json = utf8.decode(Uint8List.sublistView(body, 1, macStart));
    return SyncBatch.fromJson((jsonDecode(json) as Map).cast<String, Object?>());
  }
}

/// How a received op becomes rows. Implemented per table, next to the DAOs.
///
/// The contract the applier must honour, and which [ApplyPipeline] relies on:
///  * it is called inside a transaction that the pipeline owns — it must not commit;
///  * it must use the row's own stamp for compare-and-set (refusing an older stamp
///    with `CRDT-STALE` rather than overwriting);
///  * it must be idempotent for a given [SyncOp] (the same op applied twice leaves
///    one row, one stamp, and the conflict receipts unchanged).
abstract interface class OpApplier {
  /// True when this device already holds [batchId] — the pipeline then skips it
  /// entirely, so a re-sent batch costs one lookup instead of a merge.
  Future<bool> hasApplied(String batchId);

  /// Applies one op. Returns the number of rows actually written (0 when the op was
  /// already reflected in the local state).
  Future<int> apply(SyncOp op);

  /// Records that [batchId] was applied, with a count for the sync log. Must be
  /// called inside the same transaction as the ops.
  Future<void> markApplied(String batchId, int opCount);
}

/// Runs the Deliverable 2 integrity gate inside the same transaction. Implemented by
/// the data layer (`commitChecked`); this interface is what keeps the pipeline free
/// of SQL.
abstract interface class GateRunner {
  /// Throws [InvariantViolation] (with a `GATE` code) when the books would be left
  /// inconsistent. The pipeline lets that exception roll the transaction back.
  Future<void> verify();
}

/// What a batch did.
final class ApplyOutcome {
  const ApplyOutcome({
    required this.batchId,
    required this.applied,
    required this.rowsWritten,
    required this.skippedReason,
    this.conflicts = const <String>[],
  });

  final String batchId;

  /// False when the batch was a duplicate or was refused.
  final bool applied;
  final int rowsWritten;

  /// Why nothing happened, in a sentence the sync log can show: `duplicate`,
  /// `wrong ledger`, `gate refused`, …
  final String? skippedReason;

  /// Conflict receipt ids raised while merging, for the review screen.
  final List<String> conflicts;

  bool get isDuplicate => skippedReason == 'duplicate';
}

/// The pipeline: one batch, one transaction, one gate, one outcome.
final class ApplyPipeline {
  ApplyPipeline({
    required this.applier,
    required this.gate,
    required this.ledgerId,
    required this.beginTransaction,
  });

  final OpApplier applier;
  final GateRunner gate;

  /// The ledger this device holds. A batch from a *different* ledger is refused
  /// outright: merging two businesses' books would be catastrophic and is exactly
  /// what a shared family Google Drive could otherwise cause.
  final String ledgerId;

  final Future<T> Function<T>(Future<T> Function() work) beginTransaction;

  Future<ApplyOutcome> applyBatch(SyncBatch batch) async {
    final batchId = batch.id;

    if (batch.ledgerId != ledgerId) {
      return ApplyOutcome(
        batchId: batchId,
        applied: false,
        rowsWritten: 0,
        skippedReason: 'different ledger',
      );
    }

    if (await applier.hasApplied(batchId)) {
      return ApplyOutcome(
        batchId: batchId,
        applied: false,
        rowsWritten: 0,
        skippedReason: 'duplicate',
      );
    }

    try {
      return await beginTransaction(() async {
        var written = 0;
        for (final op in batch.orderedOps) {
          // Oldest first: a row's fields should be touched in causal order, so the
          // conflict receipts on the way record the *first* rejection and the final
          // winner, not an artefact of arrival order.
          written += await applier.apply(op);
        }
        // The gate runs inside the transaction, on the merged state. A single
        // unbalanced entry anywhere in the batch takes the whole batch with it.
        await gate.verify();
        await applier.markApplied(batchId, batch.ops.length);
        return ApplyOutcome(
          batchId: batchId,
          applied: true,
          rowsWritten: written,
          skippedReason: null,
        );
      });
    } on InvariantViolation catch (error) {
      // The transaction is already rolled back by the caller's `inTransaction`.
      return ApplyOutcome(
        batchId: batchId,
        applied: false,
        rowsWritten: 0,
        skippedReason: error.invariantCode.startsWith('GATE')
            ? 'gate refused'
            : 'refused: ${error.invariantCode}',
      );
    }
  }
}

/// The content hash used for batch ids and conflict receipts.
String _hashOf(String canonical) => base64UrlNoPad(sha256(utf8.encode(canonical)));
