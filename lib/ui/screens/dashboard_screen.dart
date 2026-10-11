import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apps/deep_links.dart';
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
import '../widgets/live_charts.dart';
import '../widgets/money_label.dart';
import '../widgets/outcome_toast.dart';
import '../widgets/skeletons.dart';
import 'package:go_router/go_router.dart';
import '../widgets/nav_shell.dart';

/// The shop at a glance: what came in, who owes, what is in the drawer, and what moved today.
///
/// ## Two queries, two providers, on purpose
///
/// The tiles come from `dashboardProvider` (`v_dashboard_metrics` plus the top-debtor roll-up)
/// and the chart from `cashFlowProvider` (a 14-day series). One provider for "the home screen"
/// would re-run the series — another 6 ms and another set of rows through the cipher — every
/// time an invoice changed a debtor's balance, for a chart that did not move. Splitting them is
/// what keeps a background sync from re-rendering the whole screen: a change to `payments`
/// rebuilds the *chart*, a change to a party's sub-ledger rebuilds the *tiles and the list*,
/// and neither rebuilds the other.
///
/// ## The tiles are not signed
///
/// `MoneyText(absolute: ...)` — no. The tiles show the figures the reports show, and a
/// receivables tile reading `Rs 0.00` on a shop that owes nothing is the point. Colours come
/// from `KhataColors` through [MoneyLabel]/[MoneyText], never from a literal.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final today = ref.watch(businessDayProvider).value ?? EpochDay.today();

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.appTitle),
        actions: const [SyncBadge()],
      ),
      body: ref.watch(dashboardProvider).when(
            loading: () => const SkeletonRows(count: 6, rowHeight: 92),
            error: (error, _) => ErrorState(
              error: error,
              title: strings.dashboard,
              onRetry: () async => ref.invalidate(dashboardProvider),
            ),
            data: (metrics) => SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: Spacing.sm),
                  _tiles(context, ref, metrics, money, strings),
                  if (metrics.draftCount > 0)
                    Padding(
                      padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, 0),
                      child: AttentionBanner(
                        message: strings.unpostedEntries(metrics.draftCount),
                        actionLabel: strings.checkBooks,
                        onAction: () => ref.invalidate(dashboardProvider),
                      ),
                    ),
                  SectionHeader(title: strings.cashFlow),
                  Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, 0),
                    child: ref.watch(cashFlowProvider(CashWindow.lastDays(today, 14))).when(
                          loading: () => const SkeletonRows(count: 1, rowHeight: 176),
                          error: (error, _) => ErrorState(error: error, title: strings.cashFlow),
                          data: (points) => CashFlowChart(
                            points: points,
                            money: money,
                            height: 176,
                            emptyLabel: strings.noCashMovement,
                          ),
                        ),
                  ),
                  _debtors(context, metrics, money, strings),
                  const SizedBox(height: 96),
                ],
              ),
            ),
          ),
      floatingActionButton: const QuickAddButton(),
    );
  }

  Widget _tiles(
    BuildContext context,
    WidgetRef ref,
    Dashboard metrics,
    MoneyFormat money,
    UiStrings strings,
  ) {
    final colors = KhataTheme.colorsOf(context);

    Widget row(List<Widget> tiles) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
          child: Row(
            children: [
              for (var i = 0; i < tiles.length; i += 1) ...[
                if (i > 0) const SizedBox(width: Spacing.sm),
                Expanded(child: tiles[i]),
              ],
            ],
          ),
        );

    return Column(
      children: [
        row([
          MoneyKpiTile(
            label: strings.todaysSales,
            amountMinor: metrics.todaySalesMinor,
            money: money,
            icon: Icons.trending_up,
            onTap: () => context.go(KhataRoutes.bills),
          ),
          MoneyKpiTile(
            label: strings.thisMonthSales,
            amountMinor: metrics.monthSalesMinor,
            money: money,
            icon: Icons.receipt_long,
            compactValue: true,
          ),
        ]),
        row([
          MoneyKpiTile(
            label: strings.receivables,
            amountMinor: metrics.receivableMinor,
            money: money,
            icon: Icons.payments,
            tone: metrics.receivableMinor > 0 ? colors.warning : colors.onCanvas,
            compactValue: true,
            onTap: () => context.go(KhataRoutes.parties),
          ),
          MoneyKpiTile(
            label: strings.payables,
            amountMinor: metrics.payableMinor,
            money: money,
            icon: Icons.inventory_2,
            compactValue: true,
            onTap: () => context.go(KhataRoutes.bills),
          ),
        ]),
        row([
          MoneyKpiTile(
            label: strings.cashAndBank,
            amountMinor: metrics.cashMinor,
            money: money,
            icon: Icons.account_balance_wallet,
            compactValue: true,
            onTap: () => context.go(KhataRoutes.cash),
          ),
          MoneyKpiTile(
            label: strings.thisMonthProfit,
            amountMinor: metrics.monthProfitMinor,
            money: money,
            icon: Icons.trending_up,
            tone: metrics.monthProfitMinor >= 0 ? colors.moneyIn : colors.moneyOut,
            compactValue: true,
          ),
        ]),
      ],
    );
  }

  Widget _debtors(BuildContext context, Dashboard metrics, MoneyFormat money, UiStrings strings) {
    if (metrics.topDebtors.isEmpty) {
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.xl, Spacing.lg, 0),
        child: EmptyState(
          icon: Icons.check,
          title: strings.noDebtors,
          message: strings.noDebtorsHint,
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionHeader(
          title: strings.topDebtors,
          actionLabel: strings.parties,
          onAction: () => context.go(KhataRoutes.parties),
        ),
        for (final party in metrics.topDebtors)
          ListRowTile(
            key: ValueKey('debtor-${party.partyId}'),
            title: party.nameUr ?? party.name,
            subtitle: party.phone,
            onTap: () => context.go(KhataRoutes.partyLedger(party.partyId)),
            trailing: MoneyLabel(
              amountMinor: party.receivableMinor,
              money: money,
              kind: LedgerColumnKind.receivable,
            ),
          ),
      ],
    );
  }
}

/// The one "new entry" button.
///
/// A sheet rather than five buttons: the entries are not equally common, and a screen covered
/// in buttons makes the common one harder to hit. The order is the order of use in a kiryana
/// shop — sale, credit sale, receipt, expense, supplier bill.
class QuickAddButton extends ConsumerWidget {
  const QuickAddButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    return FloatingActionButton(
      tooltip: strings.quickActions,
      onPressed: () => showQuickAdd(context, ref),
      child: const Icon(Icons.add),
    );
  }
}

/// Opens the quick-add sheet. Separate from [QuickAddButton] so a screen can also trigger it
/// from an app-bar action (the cash book does not, the stock book does).
Future<void> showQuickAdd(BuildContext context, WidgetRef ref) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: KhataTheme.colorsOf(context).surface,
    builder: (context) => const _QuickAddSheet(),
  );
}

class _QuickAddSheet extends ConsumerWidget {
  const _QuickAddSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final commands = ref.watch(bookCommandsProvider);
    if (commands == null) {
      return const Padding(
        padding: EdgeInsets.all(Spacing.xl),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    Future<void> open(EntrySheetSpec spec) async {
      Navigator.of(context).pop();
      final outcome = await showEntrySheet(context, spec);
      if (outcome != null && context.mounted) showOutcome(context, outcome);
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SectionHeader(title: strings.quickActions),
          ListTile(
            leading: const Icon(Icons.payments, size: 20),
            title: Text(strings.newSale),
            subtitle: Text(strings.saleHint),
            onTap: () => open(saleSpec(commands: commands, money: money, strings: strings)),
          ),
          ListTile(
            leading: const Icon(Icons.receipt_long, size: 20),
            title: Text(strings.newInvoice),
            subtitle: Text(strings.invoiceHint),
            onTap: () => open(invoiceSpec(commands: commands, money: money, strings: strings)),
          ),
          ListTile(
            leading: const Icon(Icons.edit_note, size: 20),
            title: Text(strings.newExpense),
            subtitle: Text(strings.expenseHint),
            onTap: () => open(expenseSpec(commands: commands, money: money, strings: strings)),
          ),
          ListTile(
            leading: const Icon(Icons.inventory_2, size: 20),
            title: Text(strings.newSupplierBill),
            subtitle: Text(strings.billHint),
            onTap: () => open(billSpec(commands: commands, money: money, strings: strings)),
          ),
          ListTile(
            leading: const Icon(Icons.person_add, size: 20),
            title: Text(strings.addParty),
            onTap: () => open(invoiceSpec(commands: commands, money: money, strings: strings)),
          ),
          const SizedBox(height: Spacing.sm),
        ],
      ),
    );
  }
}
