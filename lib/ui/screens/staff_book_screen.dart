import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apps/deep_links.dart';
import '../commands/book_commands.dart';
import '../commands/entry_specs.dart';
import '../format/strings.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/forms.dart';
import '../widgets/ledger_view.dart';
import '../widgets/money_label.dart';
import '../widgets/outcome_toast.dart';
import '../widgets/skeletons.dart';
import '../widgets/virtual_list.dart';
import 'package:go_router/go_router.dart';

/// The staff book: salaries paid, advances outstanding.
///
/// An employee is a party with a sub-ledger like any other — an advance is a receivable (the
/// shop is owed the work), a salary paid is money out, and both land in the same double-entry
/// books as everything else. That is why this screen has no separate store of "staff debts":
/// it is `staffProvider`, which reads the same balances the party list reads, filtered to the
/// people who work here.
///
/// The advance is posted as an expense with the `salaries` role, which is the honest
/// simplification: the app tracks what was paid and when, which is what the arguments at the
/// counter are about. Formal payroll (withholding, EOBI, gratuity) is a different product.
class StaffBookScreen extends ConsumerWidget {
  const StaffBookScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final commands = ref.watch(bookCommandsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.staffBook),
        actions: [
          if (commands != null)
            IconButton(
              tooltip: strings.paySalary,
              onPressed: () async {
                final outcome = await showEntrySheet(
                  context,
                  expenseSpec(commands: commands, money: money, strings: strings),
                );
                if (outcome != null && context.mounted) showOutcome(context, outcome);
              },
              icon: const Icon(Icons.payments),
            ),
        ],
      ),
      body: ref.watch(staffProvider).when(
            loading: () => const SkeletonRows(count: 6, rowHeight: Spacing.listRowHeight),
            error: (error, _) => ErrorState(error: error, title: strings.staffBook),
            data: (people) {
              if (people.isEmpty) {
                return EmptyState(
                  icon: Icons.groups,
                  title: strings.noStaffYet,
                  message: strings.addStaffHint,
                  actionLabel: strings.addParty,
                  onAction: () => context.go('${KhataRoutes.parties}?kind=2'),
                );
              }
              return VirtualList(
                itemCount: people.length,
                itemExtent: Spacing.listRowHeight,
                padding: const EdgeInsetsDirectional.only(bottom: 96),
                keyOf: (index) => ValueKey('staff-${people[index].partyId}'),
                rowBuilder: (context, index) {
                  final person = people[index];
                  return ListRowTile(
                    title: person.nameUr ?? person.name,
                    subtitle: person.phone,
                    onTap: () => context.go(KhataRoutes.partyLedger(person.partyId)),
                    trailing: MoneyLabel(
                      amountMinor: person.netMinor,
                      money: money,
                      kind: person.netMinor >= 0 ? LedgerColumnKind.receivable : LedgerColumnKind.payable,
                    ),
                  );
                },
              );
            },
          ),
    );
  }
}
