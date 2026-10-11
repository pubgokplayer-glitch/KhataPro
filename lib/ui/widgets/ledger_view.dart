/// KhataPro · the ledger rows: day headers, `Dr`/`Cr`, running balances.
///
/// ## What "reflects the double-entry truth" means here
///
/// Every row on screen comes from `v_party_ledger` (or the cash-book query) and carries a
/// **signed** amount: positive is a net debit, negative a net credit — the same sign
/// convention the schema uses and the same one `BalanceSide.of()` names. So the `Dr`/`Cr`
/// suffix is not a decoration the UI invents: it is the entry's own sign, printed. A ledger
/// where those two can disagree is a ledger that lies, which is why the suffix is rendered
/// from the amount and never passed in alongside it.
///
/// The **running balance** is the other half of that contract. It is computed by
/// `LedgerPager` walking *backwards* from the party's current balance (see
/// `lists/paged_list.dart`), and when that walk does not land on zero the pager says so and
/// [LedgerList] shows the integrity banner instead of a plausible-looking column of numbers.
///
/// ## The colour decision (and why it is not "positive is green")
///
/// [ledgerTone] is the single place a ledger row's colour is chosen, and it is deliberately
/// not a function of the sign alone — because the *same* sign means opposite things on
/// different ledgers:
///
/// | ledger | amount `+` | amount `−` |
/// | --- | --- | --- |
/// | receivable (customer) | a credit sale: they owe more — **default ink**, a healthy sale is not an alarm | a receipt: money arrived — **`moneyIn`** |
/// | payable (supplier) | a bill received: we owe more — **default ink** | a payment made: money left the till — **`moneyOut`** |
/// | cash / bank | cash in — **`moneyIn`** | cash out — **`moneyOut`** |
///
/// The rule a shopkeeper actually uses when reading a ledger is "where did money move?", so
/// the colour marks movement, and the `Dr`/`Cr` suffix plus the balance column carry the
/// accounting. Colour is never the only signal: the suffix is mandatory and the amounts are
/// right-aligned with tabular figures, so the column scans vertically.
library;

import 'package:flutter/material.dart';

// The colour rule and the money primitives live in `money_label.dart` (one place for both);
// re-exported here because a screen that renders a ledger should not have to know that.
export 'money_label.dart' show LedgerColumnKind, MoneyLabel, MoneyText, ledgerTone;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../format/formatting.dart';
import '../lists/paged_list.dart';
import '../state/providers.dart';
import '../state/queries.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'money_label.dart';
import 'skeletons.dart';
import 'virtual_list.dart';

/// One entry, as a row.
///
/// Fixed at [Spacing.listRowHeight] because the list's `itemExtentBuilder` promised that
/// height to the viewport: a tile that grows would desynchronise the scrollbar and the
/// prefetch window. Text that does not fit is ellipsised, never wrapped — a two-line row in
/// a 30 000-entry ledger is a re-layout of the whole viewport.
class LedgerEntryTile extends StatelessWidget {
  const LedgerEntryTile({
    super.key,
    required this.amountMinor,
    required this.title,
    required this.kind,
    required this.money,
    this.subtitle,
    this.balanceMinor,
    this.onTap,
    this.emphasis = false,
    this.trailingNote,
  });

  /// Signed: positive is a net debit. Drives the suffix, the colour and the sign shown.
  final int amountMinor;

  /// The entry's own words: its memo, or its number when there is no memo.
  final String title;

  /// Account name, document number — whatever identifies the contra side.
  final String? subtitle;

  final LedgerColumnKind kind;
  final MoneyFormat money;

  /// The running balance after this entry. Null in views that do not walk a balance (the
  /// cash book shows the level in its chart instead).
  final int? balanceMinor;

  final VoidCallback? onTap;

  /// True for the row a deep link pointed at (an invoice opened from a reminder message).
  final bool emphasis;

  /// A short right-aligned note under the amount: "overdue 12 days", "unpaid".
  final String? trailingNote;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    final amountColor = ledgerTone(amountMinor, kind, colors);
    final side = BalanceSide.of(amountMinor);

    final row = SizedBox(
      height: Spacing.listRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyMedium,
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall,
                    ),
                ],
              ),
            ),
            const SizedBox(width: Spacing.md),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${money.signed(amountMinor)}${side == BalanceSide.zero ? '' : ' ${side.label}'}',
                  maxLines: 1,
                  style: text.bodyMedium?.copyWith(
                    color: amountColor,
                    fontFeatures: KhataType.tabular,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (balanceMinor != null)
                  Text(
                    money.balance(balanceMinor!),
                    maxLines: 1,
                    style: text.labelSmall?.copyWith(fontFeatures: KhataType.tabular),
                  )
                else if (trailingNote != null)
                  Text(trailingNote!, maxLines: 1, style: text.labelSmall),
              ],
            ),
          ],
        ),
      ),
    );

    return DecoratedBox(
      decoration: BoxDecoration(
        color: emphasis ? colors.surfaceVariant : colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.outline.withValues(alpha: 0.5)),
        ),
      ),
      child: onTap == null ? row : InkWell(onTap: onTap, child: row),
    );
  }
}

/// One day's header: the date, the day's net, and how many entries are under it.
class LedgerDayHeader extends StatelessWidget {
  const LedgerDayHeader({
    super.key,
    required this.epochDay,
    required this.dayNetMinor,
    required this.count,
    required this.money,
  });

  final int epochDay;
  final int dayNetMinor;
  final int count;
  final MoneyFormat money;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: Spacing.dayHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
        child: Row(
          children: [
            Expanded(
              child: Text(
                DateText.short(epochDay, digits: money.digits),
                style: text.labelMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            Text(
              '$count ${count == 1 ? 'entry' : 'entries'}',
              style: text.labelSmall,
            ),
            const SizedBox(width: Spacing.md),
            Text(
              money.signed(dayNetMinor),
              style: text.labelMedium?.copyWith(
                color: dayNetMinor == 0 ? colors.onSurfaceMuted : colors.onCanvas,
                fontFeatures: KhataType.tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The party ledger. Watches one provider and renders one list — the whole screen-level
/// granularity directive in practice: a sync that touches another party's rows does not
/// rebuild this, and a scroll does not rebuild the header.
class LedgerList extends ConsumerWidget {
  const LedgerList({
    super.key,
    required this.partyId,
    required this.kind,
    this.onOpenEntry,
  });

  final String partyId;
  final LedgerColumnKind kind;
  final void Function(LedgerPosition position)? onOpenEntry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatProvider);
    final ledger = ref.watch(ledgerProvider(partyId));

    return ledger.when(
      loading: () => const SkeletonRows(),
      error: (error, _) => ErrorState(
        error: error,
        title: 'This ledger could not be loaded',
        onRetry: () => ref.read(ledgerProvider(partyId).notifier).refresh(),
      ),
      data: (state) {
        if (state.positions.isEmpty && !state.isLoading) {
          return const EmptyState(
            icon: Icons.add,
            title: 'No entries yet',
            message: 'Nothing has been recorded for this party. A sale, a payment or an '
                'opening balance will appear here.',
          );
        }

        final cells = state.cells;
        final headerIndices = <int>[];
        final keys = <Key>[];
        final indexOfKey = <Object?, int>{};
        for (var i = 0; i < cells.length; i++) {
          final cell = cells[i];
          // The cell hierarchy is sealed, so this switch needs no default arm — and if a
          // third cell kind is ever added, the analyzer fails here rather than drawing a
          // blank row at runtime.
          final key = switch (cell) {
            DayHeaderCell(:final epochDay) => ValueKey('day-$epochDay'),
            LedgerRowCell(:final position) => ValueKey(position.row.lineId),
          };
          if (cell is DayHeaderCell) headerIndices.add(i);
          keys.add(key);
          indexOfKey[key.value] = i;
        }

        return Column(
          children: [
            if (state.integrityNote != null)
              IntegrityBanner(
                note: state.integrityNote!,
                onReload: () => ref.read(ledgerProvider(partyId).notifier).refresh(),
              ),
            Expanded(
              child: VirtualList(
                itemCount: cells.length,
                itemExtentBuilder: CellExtents.ofHeaderIndices(headerIndices),
                keyOf: (index) => keys[index],
                // Answered from a map built in this same build: O(1) per key the framework
                // asks about, and no scan of 30 000 rows on the frame a sync lands.
                indexOfKey: (key) => indexOfKey[key.value],
                canLoadMore: state.hasMore && !state.isLoading,
                onLoadMore: () => ref.read(ledgerProvider(partyId).notifier).loadMore(),
                padding: EdgeInsetsDirectional.zero,
                rowBuilder: (context, index) {
                  final cell = cells[index];
                  return switch (cell) {
                    DayHeaderCell(:final epochDay, :final dayNetMinor, :final count) =>
                      LedgerDayHeader(
                        epochDay: epochDay,
                        dayNetMinor: dayNetMinor,
                        count: count,
                        money: money,
                      ),
                    LedgerRowCell(:final position) => LedgerEntryTile(
                        amountMinor: position.amountMinor,
                        title: position.row.memo?.isNotEmpty == true
                            ? position.row.memo!
                            : position.row.entryNo,
                        subtitle: position.row.docNo ?? position.row.accountName,
                        kind: kind,
                        money: money,
                        balanceMinor: position.balanceAfterMinor,
                        onTap: onOpenEntry == null
                            ? null
                            : () => onOpenEntry!(position),
                      ),
                  };
                },
              ),
            ),
            LoadMoreFooter(
              isLoading: state.isLoading,
              hasMore: state.hasMore,
              count: state.positions.length,
            ),
          ],
        );
      },
    );
  }
}

/// The cash book's list: the same tiles, over `List<LedgerLine>` grouped into days.
///
/// It exists because the cash book's rows are movements, not positions: there is no running
/// balance per row (the level lives in the chart above the list), so the backwards walk the
/// party ledger needs would be *wrong* here — the same account is debited and credited across
/// the window, and a per-row balance would be a number nobody asked for.
///
/// Grouping is one pass over the lines, and each day's net is accumulated in that same pass:
/// a `where(...).fold(...)` per header would be O(days × lines), which on a year window is
/// a quarter of a million iterations to draw thirty subtotals.
class CashEntryList extends StatelessWidget {
  const CashEntryList({
    super.key,
    required this.lines,
    required this.money,
    this.onOpenEntry,
    this.emptyMessage = 'No cash movement in this window',
  });

  final List<LedgerLine> lines;
  final MoneyFormat money;
  final void Function(LedgerLine line)? onOpenEntry;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return EmptyState(
        icon: Icons.sync,
        title: 'Nothing moved',
        message: emptyMessage,
      );
    }

    // One pass: flatten to cells, and accumulate each day's net and count as we go.
    final cells = <Object>[];
    final nets = <int, int>{};
    final counts = <int, int>{};
    final keys = <Key>[];
    final headerIndices = <int>[];
    int? currentDay;
    for (final line in lines) {
      if (line.entryDate != currentDay) {
        currentDay = line.entryDate;
        headerIndices.add(cells.length);
        cells.add(DayHeader(epochDay: line.entryDate));
        keys.add(ValueKey('day-${line.entryDate}'));
      }
      cells.add(line);
      keys.add(ValueKey(line.lineId));
      nets[line.entryDate] = (nets[line.entryDate] ?? 0) + line.amountMinor;
      counts[line.entryDate] = (counts[line.entryDate] ?? 0) + 1;
    }

    return VirtualList(
      itemCount: cells.length,
      itemExtentBuilder: CellExtents.ofHeaderIndices(headerIndices),
      keyOf: (index) => keys[index],
      padding: EdgeInsetsDirectional.zero,
      rowBuilder: (context, index) {
        final cell = cells[index];
        if (cell is DayHeader) {
          return LedgerDayHeader(
            epochDay: cell.epochDay,
            dayNetMinor: nets[cell.epochDay] ?? 0,
            count: counts[cell.epochDay] ?? 0,
            money: money,
          );
        }
        final line = cell as LedgerLine;
        return LedgerEntryTile(
          amountMinor: line.amountMinor,
          title: line.memo?.isNotEmpty == true ? line.memo! : line.entryNo,
          subtitle: line.docNo ?? line.accountName,
          kind: LedgerColumnKind.cash,
          money: money,
          onTap: onOpenEntry == null ? null : () => onOpenEntry!(line),
        );
      },
    );
  }
}

/// A day boundary in the flattened cash list. Local to this file: the party ledger uses the
/// verified `DayHeaderCell` from the state layer, and this is the cash book's equivalent.
class DayHeader {
  const DayHeader({required this.epochDay});

  final int epochDay;
}

/// The closing balance line above a ledger: the number the whole walk hangs from, plus the
/// date the book thinks "today" is — which comes from `session_flags` through
/// `businessDayProvider`, so a shop that works past midnight sees the day it is billing in.
class LedgerBalanceHeader extends ConsumerWidget {
  const LedgerBalanceHeader({
    super.key,
    required this.partyId,
    required this.kind,
  });

  final String partyId;
  final LedgerColumnKind kind;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final money = ref.watch(moneyFormatProvider);
    final party = ref.watch(partyProvider(partyId)).value;
    final ledger = ref.watch(ledgerProvider(partyId)).value;
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;

    final balance = ledger == null || ledger.positions.isEmpty
        ? party?.netMinor ?? 0
        : ledger.positions.first.balanceAfterMinor;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg, vertical: Spacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(
          bottom: BorderSide(color: colors.outline),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  party?.name ?? '',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium,
                ),
                if (party?.phone != null)
                  Text(party!.phone!, style: text.labelSmall),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                money.balance(balance),
                style: text.titleMedium?.copyWith(
                  fontFeatures: KhataType.tabular,
                  color: balance == 0 ? colors.onSurfaceMuted : colors.onCanvas,
                ),
              ),
              Text(
                kind == LedgerColumnKind.receivable
                    ? 'Customer balance'
                    : (kind == LedgerColumnKind.payable ? 'Supplier balance' : 'Cash balance'),
                style: text.labelSmall,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
