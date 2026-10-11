/// KhataPro · the chart of accounts.
///
/// Reads come from `v_account_balances` (the audited cache) — see
/// `docs/ARCHITECTURE.md` for why that is legitimate, and
/// `OrderBook.commitChecked` for the check that keeps it honest. Writes are
/// always "create a new account" or "rename"; an account is never deleted while
/// it carries history (`trg_account_no_delete` refuses), because deleting an
/// account that money has flowed through would make years of entries
/// unreadable.
library;

import 'package:drift/drift.dart' show QueryRow;

import '../../../core/crdt/stamp.dart';
import '../../../core/errors/khata_exception.dart';
import 'base_dao.dart';

/// Plain account kinds, mirroring the CHECK in `accounts.kind`.
abstract final class AccountKind {
  static const int asset = 1;
  static const int liability = 2;
  static const int equity = 3;
  static const int income = 4;
  static const int expense = 5;
  static const int other = 6;

  static const Map<int, String> labels = {
    asset: 'Asset',
    liability: 'Liability',
    equity: 'Equity',
    income: 'Income',
    expense: 'Expense',
    other: 'Other',
  };

  /// The side an increase lands on: +1 debit-normal, −1 credit-normal.
  static int normalBalanceFor(int kind) => switch (kind) {
        asset || expense => 1,
        liability || equity || income => -1,
        _ => 1,
      };
}

/// A ledger account with its live balance.
final class AccountBalance {
  const AccountBalance({
    required this.accountId,
    required this.code,
    required this.name,
    required this.kind,
    required this.normalBalance,
    required this.currencyCode,
    required this.netMinor,
    required this.normalNetMinor,
    required this.lineCount,
    required this.isPostable,
    this.nameUr,
    this.role,
    this.groupCode,
    this.isContra = false,
    this.isCash = false,
    this.isBank = false,
    this.lastEntryDate,
  });

  final String accountId;
  final String code;
  final String name;
  final String? nameUr;
  final int kind;
  final String? groupCode;

  /// The stable handle reports bind to (`AccountRole.*`).
  final String? role;
  final int normalBalance;
  final bool isContra;
  final bool isPostable;
  final bool isCash;
  final bool isBank;
  final String currencyCode;

  /// Debit-positive net (the schema's raw convention).
  final int netMinor;

  /// `netMinor × normalBalance` — positive always means "more of what the label
  /// says", which is what reports and the UI display.
  final int normalNetMinor;

  final int lineCount;
  final int? lastEntryDate;

  static AccountBalance fromRow(QueryRow row) => AccountBalance(
        accountId: row.read<String>('account_id'),
        code: row.read<String>('code'),
        name: row.read<String>('name'),
        nameUr: row.read<String?>('name_ur'),
        kind: row.read<int>('kind'),
        groupCode: row.read<String?>('group_code'),
        role: row.read<String?>('role'),
        normalBalance: row.read<int>('normal_balance'),
        isContra: row.read<bool?>('is_contra') ?? (row.read<int?>('is_contra') ?? 0) == 1,
        isPostable: row.read<int>('is_postable') == 1,
        isCash: row.read<int>('is_cash') == 1,
        isBank: row.read<int>('is_bank') == 1,
        currencyCode: row.read<String>('currency_code'),
        netMinor: row.read<int>('net_minor'),
        normalNetMinor: row.read<int>('normal_net_minor'),
        lineCount: row.read<int>('line_count'),
        lastEntryDate: row.read<int?>('last_entry_date'),
      );

  bool get hasActivity => lineCount > 0;

  @override
  String toString() => '$code $name: ${normalNetMinor >= 0 ? '+' : ''}$normalNetMinor';
}

final class AccountsDao extends DaoBase {
  AccountsDao({required super.db, required super.ledgerId});

  /// The account for a stable role. This is how every posting path finds its
  /// targets, and why renaming "Cash" to "Galla" changes nothing in the code.
  Future<AccountBalance?> byRole(String role) async {
    final row = await one(
      'SELECT * FROM v_account_balances WHERE ledger_id = ? AND role = ? '
      'AND is_postable = 1 LIMIT 1',
      [ledgerId, role],
    );
    return row == null ? null : AccountBalance.fromRow(row);
  }

  /// The sub-ledger account of a party, or null if it has none yet.
  ///
  /// Note what this is **not**: it is not a lookup by `role`. The schema allows
  /// exactly one account per role per ledger (`ux_accounts_role`), and the
  /// seeded control account ("1200 Accounts Receivable") holds `role = 'ar'`.
  /// A party's own account therefore carries `party_id` and a **NULL role**, and
  /// the money is attributed to the party through `journal_lines.party_id` —
  /// which is what `v_party_balances` sums. Getting this wrong is how a
  /// sub-ledger insert silently became a no-op (`INSERT OR IGNORE` against the
  /// unique index) and then failed at posting time with "INT-2d: lines may only
  /// post to postable accounts"; the schema was right and this DAO was not.
  Future<String?> partyAccountId(String partyId) => scalarString(
        'SELECT id FROM accounts WHERE ledger_id = ? AND party_id = ? '
        'AND deleted_at IS NULL LIMIT 1',
        [ledgerId, partyId],
      );

  /// Reads a **live** balance for an account straight from the lines.
  ///
  /// `v_account_balances` reads the audited cache, which is exactly right for
  /// reports and wrong for a just-created account: nothing has touched it, so it
  /// is not in the cache yet. Reports use the cache; a "did this account get
  /// created correctly" question uses the lines.
  Future<int> liveBalanceMinor(String accountId) => scalarInt(
        'SELECT COALESCE(SUM(l.amount_minor), 0) FROM journal_lines l '
        'JOIN journal_entries e ON e.id = l.entry_id AND e.status = 1 '
        'WHERE l.ledger_id = ? AND l.account_id = ?',
        [ledgerId, accountId],
      );

  Future<AccountBalance?> byId(String accountId) async {
    final row = await one(
      'SELECT * FROM v_account_balances WHERE ledger_id = ? AND account_id = ?',
      [ledgerId, accountId],
    );
    return row == null ? null : AccountBalance.fromRow(row);
  }

  /// The accounts a picker should offer: postable, not deleted, alive or with
  /// history.
  Future<List<AccountBalance>> list({bool postableOnly = true, bool withHistoryOnly = false}) async {
    final rows = await all(
      'SELECT * FROM v_account_balances WHERE ledger_id = ? '
      '${postableOnly ? 'AND is_postable = 1' : ''} '
      '${withHistoryOnly ? 'AND line_count > 0' : ''} '
      'ORDER BY kind, code',
      [ledgerId],
    );
    return [for (final row in rows) AccountBalance.fromRow(row)];
  }

  /// Every posting path calls this to make sure a party has its sub-ledger.
  ///
  /// Idempotent: the `accounts` table has a partial unique index on
  /// `(ledger_id, party_id, role)`, so a race between two callers cannot create
  /// two accounts for one party — the second insert is ignored and the existing
  /// row is returned.
  Future<String> ensurePartySubledger(
    String partyId, {
    String controlRole = AccountRole.ar,
  }) async {
    final existing = await scalarString(
      'SELECT id FROM accounts WHERE ledger_id = ? AND party_id = ? '
      'AND role IS NULL AND deleted_at IS NULL LIMIT 1',
      [ledgerId, partyId],
    );
    if (existing != null) return existing;

    final party = await one(
      'SELECT name, name_ur FROM parties WHERE id = ? AND ledger_id = ?',
      [partyId, ledgerId],
    );
    if (party == null) {
      throw InvariantViolation(
        invariantCode: 'INT-7',
        message: 'cannot open a sub-ledger for a party that does not exist ($partyId)',
      );
    }

    // The control account supplies the account NATURE (asset vs liability, which
    // side is normal, and the group it reports under). The party account is a
    // leaf of that control account, so a rename of the control account keeps
    // working and reports keep grouping correctly.
    final control = await one(
      'SELECT id, kind, group_code, normal_balance, currency_code FROM accounts '
      'WHERE ledger_id = ? AND role = ? AND deleted_at IS NULL LIMIT 1',
      [ledgerId, controlRole],
    );
    if (control == null) {
      throw InvariantViolation(
        invariantCode: 'INT-4',
        message: 'this book has no "$controlRole" control account, so a party '
            'sub-ledger cannot be opened. Restore the default chart of accounts '
            'in Settings.',
      );
    }

    final partyName = party.read<String>('name');
    final shortName = partyName.length <= 24 ? partyName : partyName.substring(0, 24);
    final controlCode = await scalarString(
      'SELECT code FROM accounts WHERE id = ?',
      [control.read<String>('id')],
    );

    final id = newRowId();
    final stamp = newStamp();
    final now = DateTime.now().millisecondsSinceEpoch;
    await exec(
      'INSERT OR IGNORE INTO accounts (id, ledger_id, parent_id, code, name, name_ur, '
      'kind, group_code, role, normal_balance, is_postable, is_system, currency_code, '
      'party_id, hlc, node_id, rev, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, 1, 0, ?, ?, ?, ?, 1, ?, ?)',
      [
        id,
        ledgerId,
        control.read<String>('id'),
        '${controlCode ?? controlRole}·$shortName',
        '$shortName (${controlCode ?? controlRole})',
        party.read<String?>('name_ur'),
        control.read<int>('kind'),
        control.read<String?>('group_code'),
        control.read<int>('normal_balance'),
        control.read<String>('currency_code'),
        partyId,
        stamp.hlc.encode(),
        nodeId,
        now,
        now,
      ],
    );

    await enqueueOplog(
      table: 'accounts',
      rowId: id,
      op: 1,
      stamp: stamp,
      payloadJson: canonicalJson({'id': id, 'party_id': partyId, 'role': null}),
    );

    // Either we inserted it, or the unique index told us a concurrent caller
    // did. Read back rather than trusting the insert — and never return an id we
    // did not confirm.
    final resolved = await scalarString(
      'SELECT id FROM accounts WHERE ledger_id = ? AND party_id = ? '
      'AND role IS NULL AND deleted_at IS NULL LIMIT 1',
      [ledgerId, partyId],
    );
    if (resolved == null) {
      throw InvariantViolation(
        invariantCode: 'INT-7',
        message: 'the sub-ledger account for party $partyId could not be created '
            '(a unique code or role constraint rejected it)',
      );
    }
    return resolved;
  }

  /// Creates a user account (a new expense head, a second bank account…).
  Future<String> create({
    required String code,
    required String name,
    required int kind,
    String? nameUr,
    String? role,
    String? groupCode,
    bool isCash = false,
    bool isBank = false,
    int sortOrder = 0,
  }) async {
    final id = newRowId();
    final stamp = newStamp();
    final now = DateTime.now().millisecondsSinceEpoch;
    await exec(
      'INSERT INTO accounts (id, ledger_id, code, name, name_ur, kind, group_code, role, '
      'normal_balance, is_postable, is_system, is_cash, is_bank, currency_code, sort_order, '
      'hlc, node_id, rev, created_at, updated_at) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?, (SELECT base_currency FROM ledgers '
      'WHERE id = ?), ?, ?, ?, 1, ?, ?)',
      [
        id,
        ledgerId,
        code,
        name,
        nameUr,
        kind,
        groupCode,
        role,
        AccountKind.normalBalanceFor(kind),
        isCash ? 1 : 0,
        isBank ? 1 : 0,
        ledgerId,
        sortOrder,
        stamp.hlc.encode(),
        nodeId,
        now,
        now,
      ],
    );
    await enqueueOplog(
      table: 'accounts',
      rowId: id,
      op: 1,
      stamp: stamp,
      payloadJson: canonicalJson({'id': id, 'code': code, 'name': name, 'kind': kind}),
    );
    await appendAudit(
      action: 'account.created',
      entityType: 'account',
      entityId: id,
      after: {'code': code, 'name': name, 'kind': kind},
    );
    return id;
  }

  /// Renames an account. Renaming is free — reports bind to `role`, not to names
  /// (contract H2) — but it still advances the CRDT stamp, so the newest name
  /// wins on every device.
  ///
  /// `is_system` accounts may be renamed and never deleted: the seed's slots are
  /// load-bearing.
  Future<void> rename(String accountId, {required String name, String? nameUr}) async {
    final current = await currentStamp('accounts', accountId);
    if (current == null) {
      throw InvariantViolation(
        invariantCode: 'INT-7',
        message: 'account $accountId does not exist',
      );
    }
    final stamp = updateStamp(current);
    await exec(
      'UPDATE accounts SET name = ?, name_ur = COALESCE(?, name_ur), hlc = ?, node_id = ?, '
      'rev = rev + 1, updated_at = ? WHERE id = ? AND ledger_id = ?',
      [name, nameUr, stamp.hlc.encode(), nodeId,
       DateTime.now().millisecondsSinceEpoch, accountId, ledgerId],
    );
    await enqueueOplog(
      table: 'accounts',
      rowId: accountId,
      op: 1,
      stamp: stamp,
      payloadJson: canonicalJson({'id': accountId, 'name': name}),
      rev: stamp.rev,
    );
  }

  /// Total of a set of roles that share an account nature (cash + bank +
  /// mobile wallet = "money I can spend today").
  Future<int> totalForRoles(List<String> roles) async {
    if (roles.isEmpty) return 0;
    final placeholders = List.filled(roles.length, '?').join(', ');
    return scalarInt(
      'SELECT COALESCE(SUM(normal_net_minor), 0) FROM v_account_balances '
      'WHERE ledger_id = ? AND role IN ($placeholders)',
      [ledgerId, ...roles],
    );
  }
}
