/// KhataPro · customers and suppliers.
///
/// A party is the thing a shopkeeper actually talks about ("Ahmed Traders owes
/// me 12,500"), so this DAO is written around two questions: *what is my balance
/// with them*, and *show me everything that happened between us*. Both are
/// answered by views (`v_party_balances`, `v_party_ledger`) so the arithmetic
/// lives in SQL where the contract tests can pin it down.
library;

import 'package:drift/drift.dart' show QueryRow;

import '../../../core/crdt/stamp.dart';
import '../../../core/crdt/lww.dart';
import '../../../core/errors/khata_exception.dart';
import 'accounts_dao.dart';
import 'base_dao.dart';

/// Party kinds, mirroring the CHECK in `parties.kind`.
abstract final class PartyKind {
  static const int customer = 1;
  static const int supplier = 2;
  static const int both = 3;
}

/// A party with its balance, from `v_party_balances`.
final class PartyBalance {
  const PartyBalance({
    required this.partyId,
    required this.name,
    required this.kind,
    required this.netMinor,
    required this.receivableMinor,
    required this.payableMinor,
    required this.lineCount,
    this.nameUr,
    this.phone,
    this.isWalkIn = false,
    this.lastActivityDate,
  });

  final String partyId;
  final String name;
  final String? nameUr;
  final int kind;
  final String? phone;
  final bool isWalkIn;

  /// Debit-positive net across all of this party's sub-ledger lines: a positive
  /// value means they owe the shop.
  final int netMinor;

  final int receivableMinor;
  final int payableMinor;
  final int lineCount;
  final int? lastActivityDate;

  /// The number a shopkeeper wants: what this party owes (positive) or is owed
  /// (negative).
  int get whatTheyOweMinor => receivableMinor;
  int get whatWeOweMinor => payableMinor;

  static PartyBalance fromRow(QueryRow row) => PartyBalance(
        partyId: row.read<String>('party_id'),
        name: row.read<String>('name'),
        nameUr: row.read<String?>('name_ur'),
        kind: row.read<int>('kind'),
        phone: row.read<String?>('phone'),
        isWalkIn: row.read<int?>('is_walk_in') == 1,
        netMinor: row.read<int>('net_minor'),
        receivableMinor: row.read<int>('receivable_minor'),
        payableMinor: row.read<int>('payable_minor'),
        lineCount: row.read<int>('line_count'),
        lastActivityDate: row.read<int?>('last_activity_date'),
      );

  @override
  String toString() => '$name: owes $receivableMinor, owed $payableMinor';
}

/// One row of a party's ledger (their running statement).
final class PartyLedgerLine {
  const PartyLedgerLine({
    required this.lineId,
    required this.entryId,
    required this.entryNo,
    required this.entryDate,
    required this.entryDateIso,
    required this.amountMinor,
    required this.runningBalanceMinor,
    this.accountName,
    this.memo,
    this.docNo,
    this.source,
  });

  final String lineId;
  final String entryId;
  final String entryNo;
  final int entryDate;
  final String entryDateIso;
  final int amountMinor;

  /// Balance after this line, in the ledger's chronological order. Computed in
  /// SQL by a window function so it can never disagree with the lines above it.
  final int runningBalanceMinor;

  final String? accountName;
  final String? memo;
  final String? docNo;
  final int? source;

  static PartyLedgerLine fromRow(QueryRow row) => PartyLedgerLine(
        lineId: row.read<String>('line_id'),
        entryId: row.read<String>('entry_id'),
        entryNo: row.read<String>('entry_no'),
        entryDate: row.read<int>('entry_date'),
        entryDateIso: row.read<String>('entry_date_iso'),
        amountMinor: row.read<int>('amount_minor'),
        runningBalanceMinor: row.read<int>('running_balance_minor'),
        accountName: row.read<String?>('account_name'),
        memo: row.read<String?>('memo'),
        docNo: row.read<String?>('doc_no'),
        source: row.read<int?>('source'),
      );
}

/// What a caller supplies when creating or editing a party. Unset fields are
/// **not** written, so a partial edit from a form cannot wipe a phone number
/// someone typed last week.
final class PartyDraft {
  const PartyDraft({
    required this.name,
    this.nameUr,
    this.kind = PartyKind.customer,
    this.phone,
    this.altPhone,
    this.email,
    this.cnic,
    this.company,
    this.addressLine1,
    this.city,
    this.province,
    this.country = 'PK',
    this.creditLimitMinor = 0,
    this.paymentTermDays = 0,
    this.notes,
    this.isWalkIn = false,
  });

  final String name;
  final String? nameUr;
  final int kind;
  final String? phone;
  final String? altPhone;
  final String? email;

  /// 13 digits; the schema enforces the format (and the uniqueness) in SQL.
  final String? cnic;
  final String? company;
  final String? addressLine1;
  final String? city;
  final String? province;
  final String? country;
  final int creditLimitMinor;
  final int paymentTermDays;
  final String? notes;
  final bool isWalkIn;

  Map<String, Object?> toColumns() => {
        if (nameUr != null) 'name_ur': nameUr,
        if (phone != null) 'phone': phone,
        if (altPhone != null) 'alt_phone': altPhone,
        if (email != null) 'email': email,
        if (cnic != null) 'cnic': cnic,
        if (company != null) 'company': company,
        if (addressLine1 != null) 'address_line1': addressLine1,
        if (city != null) 'city': city,
        if (province != null) 'province': province,
        if (notes != null) 'notes': notes,
      };
}

final class PartiesDao extends DaoBase {
  PartiesDao({required super.db, required super.ledgerId});

  /// Creates a party **and** its sub-ledger account in one transaction.
  ///
  /// The two always go together: a party without a sub-ledger cannot be posted
  /// to, and a sub-ledger without a party is an orphan the integrity report
  /// flags (`UNPAIRED_PARTY_ACCOUNT`). Doing it here, transactionally, is what
  /// makes that warning unreachable through normal use.
  Future<String> create(PartyDraft draft) async {
    final accounts = AccountsDao(db: db, ledgerId: ledgerId);
    return inTransaction(() async {
      final id = newRowId();
      final stamp = newStamp();
      final now = DateTime.now().millisecondsSinceEpoch;
      final columns = <String>[
        'id', 'ledger_id', 'name', 'kind', 'is_walk_in', 'credit_limit_minor',
        'payment_term_days', 'country', 'hlc', 'node_id', 'rev', 'created_at', 'updated_at',
      ];
      final values = <Object?>[
        id, ledgerId, draft.name, draft.kind, draft.isWalkIn ? 1 : 0,
        draft.creditLimitMinor, draft.paymentTermDays, draft.country,
        stamp.hlc.encode(), nodeId, 1, now, now,
      ];
      for (final entry in draft.toColumns().entries) {
        columns.add(entry.key);
        values.add(entry.value);
      }
      await exec(
        'INSERT INTO parties (${columns.join(', ')}) '
        'VALUES (${List.filled(columns.length, '?').join(', ')})',
        values,
      );

      await enqueueOplog(
        table: 'parties',
        rowId: id,
        op: 1,
        stamp: stamp,
        payloadJson: canonicalJson({'id': id, 'name': draft.name, 'kind': draft.kind}),
      );

      final controlRole =
          draft.kind == PartyKind.supplier ? AccountRole.ap : AccountRole.ar;
      await accounts.ensurePartySubledger(id, controlRole: controlRole);

      await appendAudit(
        action: 'party.created',
        entityType: 'party',
        entityId: id,
        after: {'name': draft.name, 'kind': draft.kind},
      );
      return id;
    });
  }

  /// Applies [changes] with last-write-wins semantics, and records a receipt for
  /// anything that gets overwritten.
  ///
  /// The rule that matters: **`incoming` must be newer**, or the write is
  /// refused (`assertFresh`). A form that has been open for an hour must not
  /// silently clobber a phone number the owner typed on the other phone.
  Future<MergeAction> update(
    String partyId,
    Map<String, Object?> changes, {
    CrdtStamp? expecting,
  }) async {
    if (changes.isEmpty) return MergeAction.identical;
    return inTransaction(() async {
      final existing = await one(
        'SELECT * FROM parties WHERE id = ? AND ledger_id = ?',
        [partyId, ledgerId],
      );
      if (existing == null) {
        throw InvariantViolation(
          invariantCode: 'INT-7',
          message: 'party $partyId does not exist in this book',
        );
      }
      final current = await currentStamp('parties', partyId);
      if (current == null) {
        throw InvariantViolation(
          invariantCode: 'INT-7',
          message: 'party $partyId has no causal stamp; the row is corrupt',
        );
      }
      if (expecting != null && expecting < current) {
        throw const InvariantViolation(
          invariantCode: 'CRDT-STALE',
          message: 'this party was changed elsewhere after you opened it. '
              'Reload to see the newer version before saving.',
        );
      }

      final stamp = updateStamp(current);
      final assignments = <String>[];
      final values = <Object?>[];
      for (final entry in changes.entries) {
        assignments.add('${entry.key} = ?');
        values.add(entry.value);
      }
      await exec(
        'UPDATE parties SET ${assignments.join(', ')}, hlc = ?, node_id = ?, rev = rev + 1, '
        'updated_at = ? WHERE id = ? AND ledger_id = ?',
        [...values, stamp.hlc.encode(), nodeId,
         DateTime.now().millisecondsSinceEpoch, partyId, ledgerId],
      );

      await enqueueOplog(
        table: 'parties',
        rowId: partyId,
        op: 1,
        stamp: stamp,
        payloadJson: canonicalJson({'id': partyId, ...changes}),
        rev: stamp.rev,
      );
      await appendAudit(
        action: 'party.updated',
        entityType: 'party',
        entityId: partyId,
        // `existing.data[key]` rather than `read<Object?>(key)`: drift's typed
        // reader resolves a SQL type per call, and there is no mapping for a
        // bare `Object?`. The raw map is the honest source for an audit snapshot
        // of arbitrary columns anyway.
        before: {for (final key in changes.keys) key: existing.data[key]},
        after: changes,
      );
      return MergeAction.applied;
    });
  }

  /// Soft delete: a tombstone with a stamp, never a `DELETE`.
  ///
  /// A deleted party must still be able to explain last year's entries, and a
  /// peer that was offline for a month has to learn about the deletion. Both
  /// need the row to exist, marked, with a stamp newer than any edit it
  /// supersedes.
  Future<void> softDelete(String partyId, {required String reason}) async {
    await inTransaction(() async {
      final current = await currentStamp('parties', partyId);
      if (current == null) {
        throw InvariantViolation(
          invariantCode: 'INT-7',
          message: 'party $partyId does not exist',
        );
      }
      final outstanding = await scalarInt(
        'SELECT COALESCE(net_minor, 0) FROM v_party_balances WHERE ledger_id = ? '
        'AND party_id = ?',
        [ledgerId, partyId],
      );
      if (outstanding != 0) {
        throw const InvariantViolation(
          invariantCode: 'FIN-3',
          message: 'this party still has an outstanding balance, so their record '
              'cannot be removed — settle or write it off first',
        );
      }
      final stamp = updateStamp(current);
      final now = DateTime.now().millisecondsSinceEpoch;
      await exec(
        'UPDATE parties SET deleted_at = ?, is_active = 0, hlc = ?, node_id = ?, '
        'rev = rev + 1, updated_at = ? WHERE id = ? AND ledger_id = ?',
        [now, stamp.hlc.encode(), nodeId, now, partyId, ledgerId],
      );
      await enqueueOplog(
        table: 'parties',
        rowId: partyId,
        op: 2,
        stamp: stamp,
        payloadJson: canonicalJson({'id': partyId, 'deleted_at': now}),
        rev: stamp.rev,
      );
      await appendAudit(
        action: 'party.deleted',
        entityType: 'party',
        entityId: partyId,
        after: {'deleted_at': now, 'reason': reason},
      );
    });
  }

  Future<PartyBalance?> byId(String partyId) async {
    final row = await one(
      'SELECT * FROM v_party_balances WHERE ledger_id = ? AND party_id = ?',
      [ledgerId, partyId],
    );
    return row == null ? null : PartyBalance.fromRow(row);
  }

  /// Parties with a non-zero balance, biggest first — "who owes me the most".
  Future<List<PartyBalance>> withOutstanding({int limit = 50}) async {
    final rows = await all(
      'SELECT * FROM v_party_balances WHERE ledger_id = ? AND net_minor <> 0 '
      'ORDER BY ABS(net_minor) DESC LIMIT ?',
      [ledgerId, limit],
    );
    return [for (final row in rows) PartyBalance.fromRow(row)];
  }

  /// The party list screen: alphabetical, with balances.
  Future<List<PartyBalance>> list({int limit = 200, int offset = 0, bool activeOnly = true}) async {
    final rows = await all(
      'SELECT * FROM v_party_balances WHERE ledger_id = ? '
      '${activeOnly ? 'AND net_minor IS NOT NULL' : ''} '
      'ORDER BY name COLLATE NOCASE LIMIT ? OFFSET ?',
      [ledgerId, limit, offset],
    );
    return [for (final row in rows) PartyBalance.fromRow(row)];
  }

  /// The statement a shopkeeper shows a customer, oldest first with a running
  /// balance.
  Future<List<PartyLedgerLine>> ledger(String partyId, {int limit = 200}) async {
    final rows = await all(
      'SELECT * FROM v_party_ledger WHERE ledger_id = ? AND party_id = ? '
      'ORDER BY entry_date, line_no LIMIT ?',
      [ledgerId, partyId, limit],
    );
    return [for (final row in rows) PartyLedgerLine.fromRow(row)];
  }
}
