import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/epoch_day.dart';
import '../commands/book_commands.dart';
import '../commands/entry_specs.dart';
import '../format/formatting.dart';
import '../format/strings.dart';
import '../state/providers.dart';
import '../state/queries.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/forms.dart';
import '../widgets/ledger_view.dart';
import '../widgets/outcome_toast.dart';
import '../widgets/skeletons.dart';
import '../widgets/live_charts.dart';

/// The cash book: what moved, and what is left.
///
/// ## The chart and the list are the same window
///
/// [cashFlowProvider] and [cashBookProvider] take the same [CashWindow], so the bars and the
/// rows below them can never be showing two different fortnights. Changing the window rebuilds
/// both from one tap; a screen with two independent window pickers is a screen where the
/// chart disagrees with the list by accident.
///
/// ## Balances are the account balances, not a sum of the rows
///
/// The three chips at the top are `cashAccountsProvider` — the same figures the dashboard
/// calls "Cash & bank", read from `v_account_balances` through the accounts' own sub-ledgers.
/// Adding up the visible rows would give a different number (the window starts after the month
/// opened), and the difference would look like a bug in the books rather than a filter.
class CashBookScreen extends ConsumerStatefulWidget {
  const CashBookScreen({super.key});

  @override
  ConsumerState<CashBookScreen> createState() => _CashBookScreenState();
}

class _CashBookScreenState extends ConsumerState<CashBookScreen> {
  int _windowDays = 31;

  CashWindow _window(int today) => switch (_windowDays) {
        <= 7 => CashWindow.lastDays(today, 7),
        <= 31 => CashWindow.thisMonth(today),
        _ => CashWindow.thisYear(today),
      };

  @override
  Widget build(BuildContext context) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final commands = ref.watch(bookCommandsProvider);
    final today = ref.watch(businessDayProvider).value ?? EpochDay.today();
    final window = _window(today);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.cashBook),
        actions: [
          IconButton(
            tooltip: strings.newExpense,
            onPressed: commands == null
                ? null
                : () async {
                    final outcome = await showEntrySheet(
                      context,
                      expenseSpec(commands: commands, money: money, strings: strings),
                    );
                    if (outcome != null && context.mounted) showOutcome(context, outcome);
                  },
            icon: const Icon(Icons.edit_note),
          ),
        ],
      ),
      body: Column(
        children: [
          _windowChips(strings),
          _balances(money, strings),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.md, Spacing.lg, Spacing.sm),
            child: ref.watch(cashFlowProvider(window)).when(
                  loading: () => const SkeletonRows(count: 1, rowHeight: 170),
                  error: (error, _) => ErrorState(error: error, title: strings.cashFlow),
                  data: (points) => CashFlowChart(
                    points: points,
                    money: money,
                    height: 170,
                    emptyLabel: strings.noCashMovement,
                  ),
                ),
          ),
          const ListHairline(),
          Expanded(
            child: ref.watch(cashBookProvider(window)).when(
                  loading: () => const SkeletonRows(count: 10, rowHeight: Spacing.listRowHeight),
                  error: (error, _) => ErrorState(error: error, title: strings.cashBook),
                  data: (lines) => CashEntryList(
                    lines: lines,
                    money: money,
                    onOpenEntry: (line) => showCashEntry(context, line, money),
                  ),
                ),
          ),
        ],
      ),
    );
  }

  Widget _windowChips(UiStrings strings) {
    Widget chip(String label, int days) => Padding(
          padding: const EdgeInsetsDirectional.only(end: Spacing.xs),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _windowDays = days),
            child: Container(
              padding: const EdgeInsetsDirectional.fromSTEB(Spacing.md, 5, Spacing.md, 5),
              decoration: BoxDecoration(
                color: _windowDays == days
                    ? KhataTheme.colorsOf(context).brand.withValues(alpha: 0.14)
                    : KhataTheme.colorsOf(context).surfaceVariant,
                borderRadius: BorderRadius.circular(Radii.pill),
                border: Border.all(
                  color: _windowDays == days
                      ? KhataTheme.colorsOf(context).brand
                      : KhataTheme.colorsOf(context).outline,
                ),
              ),
              child: Text(label, style: TextStyle(fontSize: TypeScale.caption)),
            ),
          ),
        );

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.xs),
      child: Row(
        children: [
          chip(strings.last7Days, 7),
          chip(strings.thisMonth, 31),
          chip(strings.thisYear, 366),
        ],
      ),
    );
  }

  Widget _balances(MoneyFormat money, UiStrings strings) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.xs, Spacing.lg, 0),
      child: ref.watch(cashAccountsProvider).when(
            loading: () => const SizedBox(height: 58),
            error: (error, _) => const SizedBox(height: 58),
            data: (accounts) => SizedBox(
              height: 58,
              child: ListView(
                scrollDirection: Axis.horizontal,
                itemCount: accounts.length,
                itemExtent: 132,
                itemBuilder: (context, index) {
                  final account = accounts[index];
                  return Padding(
                    padding: const EdgeInsetsDirectional.only(end: Spacing.sm),
                    child: KpiTile(
                      label: account.name,
                      height: 58,
                      icon: account.isBank ? Icons.account_balance_wallet : Icons.payments,
                      value: MoneyText(
                        amountMinor: account.balanceMinor,
                        money: money,
                        size: TypeScale.section,
                        color: account.balanceMinor < 0
                            ? KhataTheme.colorsOf(context).moneyOut
                            : KhataTheme.colorsOf(context).onCanvas,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
    );
  }
}

/// One cash movement, with the entry behind it. Same read-only detail sheet the party ledger
/// uses, reached from a different list.
Future<void> showCashEntry(BuildContext context, LedgerLine line, MoneyFormat money) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: KhataTheme.colorsOf(context).surface,
    builder: (context) => Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(line.entryNo, style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: Spacing.xs),
          Text(line.memo ?? '', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: Spacing.md),
          Row(
            children: [
              Expanded(child: Text(line.accountName ?? '')),
              MoneyLabel(amountMinor: line.amountMinor, money: money, kind: LedgerColumnKind.cash),
            ],
          ),
        ],
      ),
    ),
  );
}
