/// KhataPro · the party ledger, paged from the database.
///
/// Implements the `LedgerSource` seam that `lib/ui/lists/paged_list.dart` walks —
/// backwards, from the party's current balance, one keyset page at a time. Everything
/// about *why* the walk goes backwards is in that file's header; this one is the SQL.
///
/// Two details worth the ink:
///
///  * **Keyset, not offset.** The cursor is the `(entry_date, line_id)` of the last row
///    the caller has, and the page query is
///    `entry_date < ? OR (entry_date = ? AND line_id < ?)`. `OFFSET 95000` asks SQLite to
///    produce and discard 95 000 rows; the keyset form asks the index
///    (`ix_jl_party_date (ledger_id, party_id, entry_date DESC)`) to seek straight to the
///    right place. On a three-year-old shop's ledger that is the difference between
///    ~0.2 ms and ~90 ms per page.
///  * **The id tie-break matters.** Four lines posted in one transaction share an
///    `entry_date`, and a page boundary that falls between two of them must not repeat or
///    skip one when the next page is fetched. Ordering by date alone would do exactly
///    that, non-deterministically, roughly once per page on a busy day.
library;

import 'package:drift/drift.dart' show Variable;

import '../../data/db/database.dart';
import '../lists/paged_list.dart';
import 'queries.dart';

/// A [LedgerSource] backed by `v_party_ledger`.
final class SqlLedgerSource implements LedgerSource {
  SqlLedgerSource({required this.db, required this.ledgerId, required this.partyId});

  final KhataDatabase db;
  final String ledgerId;
  final String partyId;

  @override
  Future<LedgerSlice> page({LedgerCursor? before, required int limit}) async {
    // One extra row: if it exists, there is more, and the extra is dropped before the
    // page is returned. The alternative — a second `COUNT(*)` query — would count every
    // line of the party on every page.
    final rows = await db.readAll(
      UiSql.partyLedger,
      [
        Variable<String>(ledgerId),
        Variable<String>(partyId),
        Variable<int>(before?.entryDate),
        Variable<int>(before?.entryDate),
        Variable<int>(before?.entryDate),
        Variable<String>(before?.lineId),
        Variable<int>(limit + 1),
      ],
      LedgerLine.fromRow,
    );
    final hasMore = rows.length > limit;
    final page = hasMore ? rows.sublist(0, limit) : rows;
    return LedgerSlice(
      rows: [
        for (final line in page)
          LedgerRow(
            lineId: line.lineId,
            entryId: line.entryId,
            entryNo: line.entryNo,
            entryDate: line.entryDate,
            amountMinor: line.amountMinor,
            accountName: line.accountName,
            memo: line.memo,
            docNo: line.docNo,
          ),
      ],
      hasMore: hasMore,
    );
  }
}

/// The party's current balance, in the orientation the ledger walk needs.
///
/// `v_party_balances.net_minor` is exactly that number: the same figure the header shows,
/// which is the property that makes the walk's integrity check meaningful — if the walk
/// does not land on zero, the header and the rows disagree, and that is worth saying out
/// loud rather than hiding.
extension PartyBalanceReader on KhataDatabase {
  Future<int> partyBalanceMinor(String ledgerId, String partyId) async {
    final value = await readOne<int?>(
      'SELECT net_minor FROM v_party_balances WHERE ledger_id = ? AND party_id = ?',
      [Variable<String>(ledgerId), Variable<String>(partyId)],
      (row) => row.data['net_minor'] as int?,
    );
    return value ?? 0;
  }

  /// The party's own row (name, phone, kind, balance) for the ledger screen's header.
  Future<PartyBalance?> party(String ledgerId, String partyId) => readOne(
        'SELECT party_id, name, name_ur, kind, phone, is_walk_in, '
        'net_minor, receivable_minor, payable_minor, line_count, last_activity_date '
        'FROM v_party_balances WHERE ledger_id = ? AND party_id = ?',
        [Variable<String>(ledgerId), Variable<String>(partyId)],
        PartyBalance.fromRow,
      );
}
