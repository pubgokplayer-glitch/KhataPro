import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../routes.dart';

import '../commands/book_commands.dart';
import '../commands/entry_specs.dart';
import '../commands/reminders.dart';
import '../format/formatting.dart';
import '../format/strings.dart';
import '../state/providers.dart';
import '../lists/paged_list.dart' show LedgerRow;
import '../state/queries.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/forms.dart';
import '../widgets/ledger_view.dart';
import '../widgets/outcome_toast.dart';
import '../../data/db/dao/parties_dao.dart' show PartyKind;
import '../widgets/reminder_sheet.dart';

/// One party's ledger — the screen a reminder link opens.
///
/// ## What this screen is not allowed to do
///
/// It does not compute a balance. `LedgerBalanceHeader` reads `v_party_balances` (the control
/// account's roll-up) and `LedgerList` reads `v_party_ledger`; if the two ever disagree, the
/// list says so instead of printing numbers that add up on screen and not in the books. That
/// is the whole reason `LedgerState.integrityNote` exists.
///
/// ## The reminder button
///
/// `[party] ? icon : nothing`: a reminder needs a phone number and money owed, and an action
/// that cannot work is worse than no action. It opens the share sheet rather than sending
/// anything itself — see `reminders.dart` for why there is no messaging plugin in this app.
class PartyLedgerScreen extends ConsumerStatefulWidget {
  const PartyLedgerScreen({
    super.key,
    required this.partyId,
    this.action = LinkAction.open,
  });

  final String partyId;

  /// What the link that opened this screen asked for. `khatapro://party/<id>?action=receive`
  /// is what the *Receive* button in a notification builds, and it is the only action there is
  /// (see `routes.dart` for why money out has no such form). Stateful, rather than a
  /// `StatelessWidget` that reads the uri, because the form must open **once** and only after
  /// the party row has loaded — the amount it pre-fills comes from that row.
  final LinkAction action;

  @override
  ConsumerState<PartyLedgerScreen> createState() => _PartyLedgerScreenState();
}

class _PartyLedgerScreenState extends ConsumerState<PartyLedgerScreen> {
  /// One shot, exactly like the bill book's `_deepLinkHandled`: an unguarded "if the action is
  /// receive, open the form" reopens the sheet on every rebuild.
  bool _actionHandled = false;

  @override
  Widget build(BuildContext context) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final commands = ref.watch(bookCommandsProvider);
    final party = ref.watch(partyProvider(widget.partyId)).value;
    final kind = (party?.kind ?? PartyKind.customer) == PartyKind.supplier
        ? LedgerColumnKind.payable
        : LedgerColumnKind.receivable;

    // The other half of a reminder link. The party row has to be in hand first (the form
    // pre-fills the amount owed from it), so this runs on the frame after that row lands —
    // once, guarded, and only for an action that exists.
    if (!_actionHandled &&
        widget.action != LinkAction.open &&
        party != null &&
        commands != null) {
      _actionHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final form = formFor(
          action: widget.action,
          forms: EntryForms(commands: commands, money: money, strings: strings),
          partyId: widget.partyId,
          partyName: party.name,
        );
        if (form == null) return;
        showEntrySheet(context, form).then((outcome) {
          if (outcome != null && mounted) showOutcome(context, outcome);
        });
      });
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(party?.nameUr ?? party?.name ?? strings.parties),
        actions: [
          if (isDialablePhone(party?.phone)) ...[
            IconButton(
              tooltip: strings.sendReminder,
              onPressed: () => _remind(context, ref, party, money, strings),
              icon: const Icon(Icons.phone),
            ),
          ],
          if (commands != null && kind == LedgerColumnKind.receivable)
            IconButton(
              tooltip: strings.newInvoice,
              onPressed: () async {
                final outcome = await showEntrySheet(
                  context,
                  invoiceSpec(
                    commands: commands,
                    money: money,
                    strings: strings,
                    partyId: widget.partyId,
                    partyName: party?.name,
                  ),
                );
                if (outcome != null && context.mounted) showOutcome(context, outcome);
              },
              icon: const Icon(Icons.edit_note),
            ),
        ],
      ),
      body: Column(
        children: [
          LedgerBalanceHeader(partyId: widget.partyId, kind: kind),
          Expanded(
            child: LedgerList(
              partyId: widget.partyId,
              kind: kind,
              onOpenEntry: (position) => showEntryDetail(context, position.row),
            ),
          ),
        ],
      ),
      floatingActionButton: commands == null
          ? null
          : FloatingActionButton(
              tooltip: kind == LedgerColumnKind.payable ? strings.paySupplier : strings.receivePayment,
              onPressed: () async {
                final outcome = await showEntrySheet(
                  context,
                  kind == LedgerColumnKind.payable
                      // A payment to a supplier without naming a bill: the same allocation
                      // machinery, on the payable side. The bill book's settle action is the
                      // one that names the document.
                      ? expenseSpec(
                          commands: commands,
                          money: money,
                          strings: strings,
                          initialAmountMinor: party?.netMinor.abs(),
                        )
                      : receiptSpec(
                          commands: commands,
                          money: money,
                          strings: strings,
                          partyId: widget.partyId,
                          partyName: party?.name,
                          initialAmountMinor: party?.netMinor.abs(),
                        ),
                );
                if (outcome != null && context.mounted) showOutcome(context, outcome);
              },
              child: const Icon(Icons.payments),
            ),
    );
  }

  Future<void> _remind(
    BuildContext context,
    WidgetRef ref,
    PartyBalance? party,
    MoneyFormat money,
    UiStrings strings,
  ) async {
    // Lateness comes from the bill book, where `days_overdue` is a real column
    // (`v_document_outstanding`). A party's own roll-up has no such field, and inventing one
    // here would mean guessing from `last_activity_date` and calling a good customer late.
    final od = ref.read(billsProvider(PartyKind.customer)).value?.fold<int>(0, (worst, bill) {
      if (bill.partyId != widget.partyId) return worst;
      return bill.daysOverdue > worst ? bill.daysOverdue : worst;
    });
    final body = buildReminder(
      partyName: party?.name ?? '',
      balanceMinor: party?.netMinor.abs() ?? 0,
      money: money,
      link: partyLinkFor(widget.partyId),
      language: ref.read(displayPrefsProvider).language,
      daysOverdue: od,

    );
    await showReminderSheet(
      context,
      title: strings.sendReminder,
      body: body,
      phone: party?.phone,
    );
  }
}

/// Tapping an entry shows what the books actually recorded for it: the two sides, the
/// accounts, the amount, and the entry number. This is the "prove it to me" screen, and it is
/// read-only on purpose — an entry that has been posted is corrected by a reversal, never by
/// editing it in place (`docs/DATA_LAYER.md`).
Future<void> showEntryDetail(BuildContext context, LedgerRow line) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    backgroundColor: KhataTheme.colorsOf(context).surface,
    builder: (context) => _EntryDetailSheet(line: line),
  );
}

class _EntryDetailSheet extends ConsumerWidget {
  const _EntryDetailSheet({required this.line});

  final LedgerRow line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final text = Theme.of(context).textTheme;
    final colors = KhataTheme.colorsOf(context);
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.lg, Spacing.lg, Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(line.entryNo, style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted)),
            const SizedBox(height: Spacing.xs),
            Text(
              line.memo ?? line.accountName ?? '',
              style: text.titleMedium,
            ),
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Expanded(child: Text(strings.date, style: text.labelSmall)),
                Text(DateText.short(line.entryDate, digits: money.digits), style: text.bodyMedium),
              ],
            ),
            const SizedBox(height: Spacing.sm),
            Row(
              children: [
                Expanded(child: Text(strings.account, style: text.labelSmall)),
                Text(line.accountName ?? '', style: text.bodyMedium),
              ],
            ),
            if (line.docNo != null) ...[
              const SizedBox(height: Spacing.sm),
              Row(
                children: [
                  Expanded(child: Text(strings.billNo, style: text.labelSmall)),
                  Text(line.docNo!, style: text.bodyMedium),
                ],
              ),
            ],
            const SizedBox(height: Spacing.md),
            Row(
              children: [
                Expanded(child: Text(strings.amount, style: text.labelSmall)),
                MoneyLabel(amountMinor: line.amountMinor, money: money),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
