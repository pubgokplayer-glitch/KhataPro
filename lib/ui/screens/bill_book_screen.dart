import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
import '../widgets/money_label.dart';
import '../widgets/outcome_toast.dart';
import '../widgets/skeletons.dart';
import '../widgets/virtual_list.dart';
import '../../data/db/dao/base_dao.dart' show DocKind;

/// The bill book: what is still owed, oldest first, in two directions.
///
/// ## It is a worklist, not an archive
///
/// The query behind it is `v_document_outstanding` filtered to `balance_minor > 0`, and the
/// ordering is by how late each bill is. A fully settled invoice *leaves* this screen — that is
/// the feature. The archive lives in the party's ledger, where every entry ever posted is still
/// readable, and in the dashboard's totals.
///
/// ## Two lists, one screen
///
/// Sales invoices (customers owe you) and supplier bills (you owe them) are the same table read
/// with a different `doc_kind`, so they share the row, the aging pill and the settle action.
/// What they do **not** share is the settlement command: [settleInvoiceSpec] takes money in,
/// [settleBillSpec] pays money out. A boolean would be one flag away from reconciling a payable
/// into a receivable.
class BillBookScreen extends ConsumerStatefulWidget {
  const BillBookScreen({super.key, this.documentId});

  /// A bill opened from a deep link (a shared invoice, a reminder) — highlighted in the list
  /// and, on the first build, opened for settlement.
  final String? documentId;

  @override
  ConsumerState<BillBookScreen> createState() => _BillBookScreenState();
}

class _BillBookScreenState extends ConsumerState<BillBookScreen> {
  bool _showPayables = false;
  bool _deepLinkHandled = false;

  int get _docKind => _showPayables ? DocKind.purchaseBill : DocKind.saleInvoice;

  @override
  Widget build(BuildContext context) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final commands = ref.watch(bookCommandsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(_showPayables ? strings.purchaseBills : strings.salesInvoices),
        actions: [
          IconButton(
            tooltip: strings.switchToPayables,
            onPressed: () => setState(() => _showPayables = !_showPayables),
            icon: const Icon(Icons.filter_list),
          ),
        ],
      ),
      body: ref.watch(billsProvider(_docKind)).when(
            loading: () => const SkeletonRows(count: 8, rowHeight: Spacing.listRowHeight),
            error: (error, _) => ErrorState(error: error, title: strings.billBook),
            data: (bills) {
              if (bills.isEmpty) {
                return EmptyState(
                  icon: Icons.check,
                  title: _showPayables ? strings.noBillsToPay : strings.nothingToCollect,
                  message: strings.allSettled,
                  actionLabel: _showPayables ? strings.newSupplierBill : null,
                  onAction: _showPayables || commands == null
                      ? null
                      : () async {
                          final outcome = await showEntrySheet(
                            context,
                            invoiceSpec(commands: commands, money: money, strings: strings),
                          );
                          if (outcome != null && context.mounted) showOutcome(context, outcome);
                        },
                );
              }

              // The deep link: open the bill the user tapped in a message. Once only — a
              // rebuild must not reopen the same sheet every frame, which is what an
              // unguarded "if it is in the list, open it" does.
              if (!_deepLinkHandled && widget.documentId != null) {
                _deepLinkHandled = true;
                final match = bills.where((b) => b.documentId == widget.documentId);
                if (match.isNotEmpty) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _settle(match.first, commands, money, strings);
                  });
                }
              }

              return VirtualList(
                itemCount: bills.length,
                itemExtent: Spacing.listRowHeight,
                padding: const EdgeInsetsDirectional.only(bottom: 96),
                keyOf: (index) => ValueKey(bills[index].documentId),
                rowBuilder: (context, index) {
                  final bill = bills[index];
                  return ListRowTile(
                    title: bill.partyName ?? bill.docNo,
                    subtitle: '${bill.docNo} · ${DateText.short(bill.docDate, digits: money.digits)}',
                    badges: [
                      if (bill.daysOverdue > 0)
                        TonePill(
                          label: strings.overdueDays(bill.daysOverdue),
                          tone: bill.daysOverdue > 60
                              ? KhataTheme.colorsOf(context).critical
                              : KhataTheme.colorsOf(context).warning,
                        )
                      else
                        TonePill(
                          label: strings.notOverdue,
                          tone: KhataTheme.colorsOf(context).onSurfaceMuted,
                        ),
                    ],
                    onTap: commands == null ? null : () => _settle(bill, commands, money, strings),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        MoneyLabel(
                          amountMinor: _showPayables ? -bill.balanceMinor : bill.balanceMinor,
                          money: money,
                          kind: _showPayables ? LedgerColumnKind.payable : LedgerColumnKind.receivable,
                          emphasis: true,
                        ),
                        Text(
                          money.amount(bill.totalMinor),
                          style: Theme.of(context).textTheme.labelSmall,
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
      floatingActionButton: _showPayables && commands != null
          ? FloatingActionButton(
              tooltip: strings.newSupplierBill,
              onPressed: () async {
                final outcome = await showEntrySheet(
                  context,
                  billSpec(commands: commands, money: money, strings: strings),
                );
                if (outcome != null && context.mounted) showOutcome(context, outcome);
              },
              child: const Icon(Icons.add),
            )
          : null,
    );
  }

  Future<void> _settle(
    BillRow bill,
    BookCommands? commands,
    MoneyFormat money,
    UiStrings strings,
  ) async {
    if (commands == null) return;
    final spec = _showPayables
        ? settleBillSpec(
            commands: commands,
            money: money,
            strings: strings,
            documentId: bill.documentId,
            balanceMinor: bill.balanceMinor,
            partyName: bill.partyName,
          )
        : settleInvoiceSpec(
            commands: commands,
            money: money,
            strings: strings,
            documentId: bill.documentId,
            balanceMinor: bill.balanceMinor,
            partyName: bill.partyName,
          );
    final outcome = await showEntrySheet(context, spec);
    if (outcome != null && mounted) showOutcome(context, outcome);
  }
}
