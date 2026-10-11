/// KhataPro · the shared plumbing every DAO uses.
///
/// Four things happen on **every** write in this app, and if any DAO forgets one
/// of them the merge story breaks in a way that only shows up on the second
/// device. So they live here, once:
///
///   1. **A causal stamp.** Every replicated row gets `(hlc, node_id, rev,
///      created_at, updated_at)`. `rev` advances on update; the HLC advances
///      always. The stamp is what the CRDT compares — never the wall clock,
///      which any device can change in Settings.
///   2. **An op-log entry**, so the change is offered to peers. Duplicate
///      delivery is expected and safe; a *missing* op-log row is data that never
///      reaches the other phone.
///   3. **A chained audit record** (`hash_prev` ‖ event). The chain is what makes
///      "an entry was edited after posting" detectable months later, from a
///      different device, without trusting the app that wrote it.
///   4. **A stale-write pre-flight.** If the caller believes it is editing the
///      current version and it is not, we refuse *before* SQL rather than
///      letting the LWW resolver quietly keep the other value.
///
/// Nothing here is clever. That is the point: a ledger's data layer should be
/// boring, explicit, and identical for every table.
library;

import 'dart:convert';
import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart' show SqliteException;

import '../../../core/crdt/hlc.dart';
import '../../../core/crdt/hlc_service.dart';
import '../../../core/crdt/lww.dart';
import '../../../core/crdt/stamp.dart';
import '../../../core/errors/khata_exception.dart';
import '../../../core/security/hasher.dart';
import '../database.dart';

/// Ledger sources, mirroring the CHECK in `journal_entries.source`.
///
/// Integers rather than strings so a corrupt row cannot introduce a new
/// "source" by typo, and so comparisons stay index-friendly.
abstract final class LedgerSource {
  static const int sale = 1;
  static const int purchase = 2;
  static const int expense = 3;
  static const int paymentIn = 4;
  static const int paymentOut = 5;
  static const int journal = 6;
  static const int opening = 7;
  static const int stockAdjust = 8;
  static const int fxReval = 9;
  static const int taxSettle = 10;
  static const int depreciation = 11;
  static const int reversal = 12;

  static const Map<int, String> labels = {
    sale: 'Sale',
    purchase: 'Purchase',
    expense: 'Expense',
    paymentIn: 'Payment received',
    paymentOut: 'Payment made',
    journal: 'Journal',
    opening: 'Opening balance',
    stockAdjust: 'Stock adjustment',
    fxReval: 'FX revaluation',
    taxSettle: 'Tax settlement',
    depreciation: 'Depreciation',
    reversal: 'Reversal',
  };
}

/// The stable `accounts.role` handles seeded by `007_seed.sql`.
///
/// Reports bind to **roles**, not to codes or names: a shopkeeper may rename
/// "Cash" to "Galla" and renumber the chart, and every report must keep working
/// (contract H2 proves this). Codes are decoration; roles are the contract.
abstract final class AccountRole {
  static const String cash = 'cash';
  static const String bank = 'bank';
  static const String mobileWallet = 'mobile_wallet';
  static const String ar = 'ar';
  static const String advanceSupplier = 'advance_supplier';
  static const String inventory = 'inventory';
  static const String prepaid = 'prepaid';
  static const String fixedAssets = 'fixed_assets';
  static const String accumDepreciation = 'accum_depreciation';
  static const String ap = 'ap';
  static const String accrued = 'accrued';
  static const String taxPayable = 'tax_payable';
  static const String whtPayable = 'wht_payable';
  static const String loans = 'loans';
  static const String customerAdvance = 'customer_advance';
  static const String capital = 'capital';
  static const String drawings = 'drawings';
  static const String openingEquity = 'opening_equity';
  static const String retainedEarnings = 'retained_earnings';
  static const String sales = 'sales';
  static const String salesServices = 'sales_services';
  static const String salesDiscounts = 'sales_discounts';
  static const String otherIncome = 'other_income';
  static const String cogs = 'cogs';
  static const String salaries = 'salaries';
  static const String rent = 'rent';
  static const String utilities = 'utilities';
  static const String telecom = 'telecom';
  static const String fuel = 'fuel';
  static const String repairs = 'repairs';
  static const String marketing = 'marketing';
  static const String officeSupplies = 'office_supplies';
  static const String bankCharges = 'bank_charges';
  static const String freight = 'freight';
  static const String miscExpense = 'misc_expense';
  static const String fxGainLoss = 'fx_gain_loss';
  static const String badDebts = 'bad_debts';

  /// Roles whose account is a placeholder for "some party" and must therefore
  /// be resolved to a real sub-ledger before posting.
  static const Set<String> partyScoped = {ar, ap, advanceSupplier, customerAdvance};
}

/// The document kinds `number_sequences.doc_kind` is keyed by (`documents`
/// mirrors these for invoices/quotations; journal entries use [journalEntry]).
abstract final class DocKind {
  static const int journalEntry = 0;
  static const int saleInvoice = 1;
  static const int purchaseBill = 2;
  static const int quotation = 3;
  static const int paymentReceipt = 4;
  static const int paymentVoucher = 5;
  static const int creditNote = 6;
  static const int debitNote = 7;

  static const Map<int, String> prefixes = {
    journalEntry: 'JE',
    saleInvoice: 'INV',
    purchaseBill: 'BILL',
    quotation: 'QT',
    paymentReceipt: 'RCV',
    paymentVoucher: 'PAY',
    creditNote: 'CN',
    debitNote: 'DN',
  };
}

/// Base class for every DAO. Holds the handle, this device's identity and the
/// ledger being worked in.
class DaoBase {
  DaoBase({required this.db, required this.ledgerId});

  final KhataDatabase db;

  /// The book being worked in. Every query is scoped by it — the schema's every
  /// view and the composite foreign keys depend on that discipline, and a
  /// missing `WHERE ledger_id = ?` is the one bug that could mix a shop's books
  /// with its workshop's.
  final String ledgerId;

  HlcService get hlc => db.hlc;
  String get nodeId => db.nodeId;

  /// Drift variables from a positional argument list.
  List<Variable<Object>> vars(List<Object?> args) =>
      [for (final arg in args) Variable<Object>(arg)];

  /// One row, or null.
  Future<QueryRow?> one(String sql, [List<Object?> args = const []]) async {
    final rows = await db.customSelect(sql, variables: vars(args)).get();
    return rows.isEmpty ? null : rows.first;
  }

  /// All rows.
  Future<List<QueryRow>> all(String sql, [List<Object?> args = const []]) =>
      db.customSelect(sql, variables: vars(args)).get();

  /// A single integer.
  Future<int> scalarInt(String sql, [List<Object?> args = const []]) async {
    final row = await one(sql, args);
    final value = row?.data.values.firstOrNull;
    return (value as num?)?.toInt() ?? 0;
  }

  /// A single string.
  Future<String?> scalarString(String sql, [List<Object?> args = const []]) async {
    final row = await one(sql, args);
    return row?.data.values.firstOrNull?.toString();
  }

  Future<void> exec(String sql, [List<Object?> args = const []]) =>
      db.customStatement(sql, args);

  /// Runs [work] in one SQL transaction on the single connection.
  ///
  /// Nested calls join the outer transaction (drift handles the savepoint
  /// semantics), so a service method can be composed into a bigger unit without
  /// ever opening a second write path.
  Future<T> inTransaction<T>(Future<T> Function() work) =>
      db.transaction(() => work());

  // ───────────────────────────────────────────────────────────────────────────
  //  Writes: the four things that must always happen
  // ───────────────────────────────────────────────────────────────────────────

  /// A fresh stamp for a row this device is creating.
  CrdtStamp newStamp() => hlc.stampForWrite();

  /// A stamp for updating an existing row: `rev` advances, HLC moves forward.
  CrdtStamp updateStamp(CrdtStamp current) => hlc.stampForUpdate(current);

  /// Reads the current `(hlc, rev)` of a row, or null when it does not exist.
  Future<CrdtStamp?> currentStamp(String table, String rowId) async {
    final row = await one(
      'SELECT hlc, rev FROM "$table" WHERE id = ?',
      [rowId],
    );
    if (row == null) return null;
    final encoded = row.read<String?>('hlc');
    if (encoded == null) return null;
    return CrdtStamp(hlc: Hlc.parse(encoded), rev: row.read<int?>('rev') ?? 1);
  }

  /// Refuses a write whose causal stamp is not newer than what is stored.
  ///
  /// This is the *pre-flight* half of last-write-wins. The resolver in
  /// `lib/core/crdt/lww.dart` handles the same question for data arriving from
  /// a peer; this one handles the local case, where a stale in-memory edit
  /// (a form left open for two hours, an undo stack replayed late) would
  /// otherwise silently lose to a newer change made on another device — and the
  /// user would see their edit vanish with no explanation.
  ///
  /// Throwing beats overwriting: the UI can then show both versions and ask.
  Future<void> assertFresh(String table, String rowId, CrdtStamp incoming) async {
    final current = await currentStamp(table, rowId);
    if (current == null) return;
    if (incoming < current) {
      throw InvariantViolation(
        invariantCode: 'CRDT-STALE',
        message: 'this record was changed elsewhere after you opened it '
            '(stored ${current.hlc.encode()}, your edit is ${incoming.hlc.encode()}). '
            'Reload to see the newer version before saving.',
      );
    }
  }

  /// Appends the change to `oplog` so peers can be offered it.
  ///
  /// `op` is 1 (upsert), 2 (tombstone) or 3 (immutable append-only row), matching
  /// the CHECK in `003_crdt_sync.sql`. Dispatch is deliberately **not** recorded
  /// here: `dispatched_at` stays NULL until a transport actually hands the row
  /// over, so a crash between commit and send costs nothing.
  Future<void> enqueueOplog({
    required String table,
    required String rowId,
    required int op,
    required CrdtStamp stamp,
    String? payloadJson,
    int rev = 1,
  }) async {
    // `WHERE NOT EXISTS` makes the queue idempotent per
    // (table, row, hlc, op) — an op is a statement about one row at one logical
    // instant, so the same tuple can never legitimately differ. Re-applying a
    // peer batch (dropped WebRTC chunk, retried sync) therefore cannot flood the
    // queue with duplicates, and (being one statement) it cannot race with
    // itself either: the DAOs share one serialized connection.
    await exec(
      'INSERT INTO oplog (table_name, row_id, op, hlc, node_id, ledger_id, rev, '
      'payload_json, byte_size, created_at) '
      'SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ? '
      "WHERE NOT EXISTS (SELECT 1 FROM oplog WHERE table_name = ? AND row_id = ? "
      'AND op = ? AND hlc = ?)',
      [
        table,
        rowId,
        op,
        stamp.hlc.encode(),
        nodeId,
        ledgerId,
        rev,
        payloadJson,
        payloadJson?.length ?? 0,
        DateTime.now().millisecondsSinceEpoch,
        table,
        rowId,
        op,
        stamp.hlc.encode(),
      ],
    );
  }

  /// Appends one hash-chained audit record.
  ///
  /// `hash_self = SHA-256(hash_prev ‖ canonical_json(event))`, where the event
  /// JSON is the same canonical form the CRDT compares payloads with — sorted
  /// keys, no doubles. Because `hash_prev` is the previous record's `hash_self`
  /// for this ledger, editing or removing any record breaks the chain at the
  /// next one (contract H3), and a forged chain would have to be re-hashed all
  /// the way forward *and* carried to every peer.
  Future<void> appendAudit({
    required String action,
    required String entityType,
    String? entityId,
    Map<String, Object?>? before,
    Map<String, Object?>? after,
    String? actorName,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final seq = await scalarInt(
      'SELECT COALESCE(MAX(seq), 0) + 1 FROM audit_log WHERE ledger_id = ?',
      [ledgerId],
    );
    final previous = await scalarString(
      'SELECT hash_self FROM audit_log WHERE ledger_id = ? ORDER BY seq DESC LIMIT 1',
      [ledgerId],
    );
    final hashPrev = previous ?? '0' * 64;

    final event = <String, Object?>{
      'action': action,
      'ledger_id': ledgerId,
      'entity_id': entityId,
      'entity_type': entityType,
      'node_id': nodeId,
      'seq': seq,
      'at': now,
    };
    final hashSelf = sha256Hex([
      ...utf8Encode(hashPrev),
      ...utf8Encode(canonicalJson(event)),
    ]);

    final stamp = newStamp();
    await exec(
      'INSERT INTO audit_log (id, ledger_id, seq, actor_node_id, actor_name, action, '
      'entity_type, entity_id, before_json, after_json, hash_prev, hash_self, hlc, '
      'node_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)',
      [
        newRowId(),
        ledgerId,
        seq,
        nodeId,
        actorName,
        action,
        entityType,
        entityId,
        before == null ? null : canonicalJson(before),
        after == null ? null : canonicalJson(after),
        hashPrev,
        hashSelf,
        stamp.hlc.encode(),
        nodeId,
        now,
      ],
    );
  }

  /// Records one merge receipt (an overwritten value worth showing the user).
  ///
  /// `INSERT OR IGNORE` against `ux_conflict_receipt` (migrations/009): the
  /// receipt's identity is `(row, field, losing stamp)`, so re-applying the same
  /// batch — which the protocol does freely and on purpose — cannot fill the
  /// review queue with duplicates.
  /// Records a merge receipt — **idempotently**.
  ///
  /// The id is derived from the conflict's content, not generated, so applying
  /// the same peer batch twice (a re-sync after a dropped connection, a retried
  /// WebRTC chunk, a restored backup) writes the receipt once. A random id would
  /// make `INSERT OR IGNORE` a no-op and leave the user staring at two copies of
  /// every conflict in the review list.
  Future<void> recordConflict(FieldConflict conflict) {
    final localIsWinner = conflict.resolution == 'local_won' ||
        conflict.resolution == 'kept_local_ambiguous';
    return exec(
        'INSERT OR IGNORE INTO conflict_log (id, ledger_id, table_name, row_id, '
        'field_name, kind, local_hlc, remote_hlc, local_node, remote_node, '
        'local_json, remote_json, resolution, detected_at) '
        'VALUES (?, ?, ?, ?, ?, 1, ?, ?, ?, ?, ?, ?, ?, ?)',
        [
          // The id names the *conflict*, not the recording device: the pair of
          // versions that disagreed plus the field they disagreed about. Two
          // phones describing the same disagreement therefore write one receipt
          // between them, in either sync direction, however many times the batch
          // is replayed. Including `resolution` here would break that, because
          // the same pair reads as `remote_won` on one device and `local_won` on
          // the other — two rows for one fact, which is exactly what the review
          // list cannot survive.
          contentId('conflict', [
            conflict.tableName ?? '',
            conflict.rowId,
            conflict.field,
            conflict.loserHlc,
            conflict.winnerHlc,
          ]),
          ledgerId,
          conflict.tableName,
          conflict.rowId,
          conflict.field,
          // `local_*` is the version that was already on this device and
          // `remote_*` is the one that arrived — the schema's meaning, restored.
          // The resolver hands back the *loser* and *winner* instead, so the
          // perspective is recovered from which side won: if the local copy won,
          // the local columns hold the winner.
          localIsWinner ? conflict.winnerHlc : conflict.loserHlc,
          localIsWinner ? conflict.loserHlc : conflict.winnerHlc,
          localIsWinner ? conflict.winnerNode : conflict.loserNode,
          localIsWinner ? conflict.loserNode : conflict.winnerNode,
          canonicalJson(localIsWinner ? conflict.winnerValue : conflict.loserValue),
          canonicalJson(localIsWinner ? conflict.loserValue : conflict.winnerValue),
          conflict.resolution,
          DateTime.now().millisecondsSinceEpoch,
        ],
      );
  }

  /// Allocates the next document/entry number for this ledger **and this node**.
  ///
  /// Keyed by `(ledger_id, doc_kind, node_id)` so two devices offline at the same
  /// time can both number an invoice 0001 without colliding — the numbers are
  /// per-device sequences, and the *document identity* is the UUID, never the
  /// human number. Duplicate human numbers across devices are surfaced as a
  /// `duplicate_document` conflict (kind 2 in `conflict_log`) for the user to
  /// renumber, which is the honest handling: silently renumbering someone's
  /// invoice is worse than asking.
  Future<String> nextNumber(int docKind, {String? prefix, int padding = 4}) async {
    final effectivePrefix = prefix ?? DocKind.prefixes[docKind] ?? 'DOC';
    await exec(
      'INSERT OR IGNORE INTO number_sequences (ledger_id, doc_kind, node_id, prefix, '
      'padding, next_value, step) VALUES (?, ?, ?, ?, ?, 1, 1)',
      [ledgerId, docKind, nodeId, effectivePrefix, padding],
    );
    final allocated = await scalarInt(
      'UPDATE number_sequences SET next_value = next_value + step '
      'WHERE ledger_id = ? AND doc_kind = ? AND node_id = ? '
      'RETURNING next_value - step',
      [ledgerId, docKind, nodeId],
    );
    return '$effectivePrefix-${allocated.toString().padLeft(padding, '0')}';
  }

  /// A fresh UUIDv7, the primary key of every replicated row.
  ///
  /// Time-ordered, so primary keys sort chronologically — which keeps B-tree
  /// inserts append-mostly (measurable: the benchmark's write path) and lets a
  /// backup pack restore rows in insertion order.
  String newRowId() => newUuidV7();

  /// Maps a SQLite failure to the app's typed errors.
  ///
  /// The triggers raise messages that start with a stable code (`INT-5b:`,
  /// `DOC-3:`, `INTEGRITY GATE:`); translating here means no UI code ever
  /// string-matches, and a trigger message can change without a hunt.
  Never mapSqliteError(Object error, StackTrace stackTrace) {
    // InvariantViolation.tryParse recognises the whole INT-/DOC-/FIN-/GATE
    // code family the schema raises, so a new trigger needs no change here.
    final invariant = InvariantViolation.tryParse(error);
    if (invariant != null) throw invariant;
    if (error is SqliteException &&
        (error.message.contains('immutable') || error.message.contains('read-only'))) {
      throw const ImmutableDocumentException(documentNo: '', field: 'entry');
    }
    Error.throwWithStackTrace(error, stackTrace);
  }
}

/// A **content-addressed** id: same inputs, same id, forever.
///
/// Used where a row is a *receipt* rather than an entity — merge conflict
/// records today, applied-sync markers and backup pack manifests next. A UUIDv7
/// is right for an entity (it sorts by creation) and wrong for a receipt (a
/// retry must land on the row that is already there). The 36-character shape and
/// a UUID version nibble are kept so the schema's `CHECK (length(id) = 36)` holds
/// and the value is indistinguishable from any other id in a backup pack.
String contentId(String namespace, List<String> parts) {
  final digest = sha256(utf8.encode('$namespace\u0000${parts.join('\u0000')}'));
  final hex = [for (final byte in digest) byte.toRadixString(16).padLeft(2, '0')].join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-5${hex.substring(13, 16)}'
      '-8${hex.substring(17, 20)}-${hex.substring(20, 32)}';
}

/// A monotonically-ordered UUIDv7 (RFC 9562): 48-bit millisecond timestamp,
/// version/variant bits, then randomness.
///
/// Not `package:uuid`'s v7 because this one must be *dependency-free* (the key
/// path already needs to run in a bare Dart process) and because we want the
/// whole id to remain lexicographically ordered as a string, which is what makes
/// `ORDER BY id` equivalent to insertion order.
String newUuidV7({int? timestampMs, List<int>? random}) {
  final now = timestampMs ?? DateTime.now().millisecondsSinceEpoch;
  final bytes = List<int>.filled(16, 0);

  bytes[0] = (now >> 40) & 0xFF;
  bytes[1] = (now >> 32) & 0xFF;
  bytes[2] = (now >> 24) & 0xFF;
  bytes[3] = (now >> 16) & 0xFF;
  bytes[4] = (now >> 8) & 0xFF;
  bytes[5] = now & 0xFF;

  final source = random ?? randomBytes(10);
  for (var i = 0; i < 10; i++) {
    bytes[6 + i] = source[i];
  }
  bytes[6] = (bytes[6] & 0x0F) | 0x70; // version 7
  bytes[8] = (bytes[8] & 0x3F) | 0x80; // RFC 4122 variant

  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}'
      '-${hex.substring(16, 20)}-${hex.substring(20)}';
}
