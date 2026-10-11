/// KhataPro · the money form: the one sheet every write in the app goes through.
///
/// There are six writes a shopkeeper makes — a sale, a credit sale (invoice), an expense, a
/// receipt, a supplier bill, an opening balance — and they differ in three booleans, not in
/// their shape. So there is one sheet: amount, date, party (when the write needs one), source
/// account (when the money moves), note. Every screen opens *this*, with a spec that says
/// which fields apply and what to do on save.
///
/// ## Why the amount is validated here and not in the database
///
/// `OrderBook` refuses a zero or negative amount with `FIN-1` and the gate rolls it back — from
/// the books' point of view that is the correct last line of defence, and it stays. But the
/// *form* is where the user is standing: an empty field is not a mistake the ledger should
/// have to describe in an invariant code, and a disabled save button is better feedback than a
/// refusal toast. So [parseAmountMinor] runs on every keystroke, and the save button simply
/// does not enable until the number is real. Both layers exist on purpose; neither is a
/// duplicate of the other.
///
/// ## Balance-affecting writes are not confirmed here
///
/// A settlement against a bill must not exceed the bill's balance, but this sheet does not
/// know the balance — and a copy of a balance in a widget is a copy that goes stale between
/// the tap and the save. The books refuse it (`trg_alloc_guard`), and the refusal is shown in
/// the sheet's own error line rather than as a toast that vanishes: the user is *in* the form
/// and can fix the number without losing what they typed.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/epoch_day.dart';
import '../../data/db/dao/parties_dao.dart' show PartyKind;
import '../commands/book_commands.dart';
import '../commands/entry_models.dart';
import '../format/formatting.dart';
import '../format/money_input.dart';
import '../format/strings.dart';
import '../state/providers.dart';
import '../state/queries.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
export '../commands/entry_models.dart' show EntrySheetSpec, EntrySheetValues;

import 'cards.dart';
import 'money_label.dart';
import 'virtual_list.dart';

/// Opens the sheet and returns its outcome, or `null` if the user cancelled.
///
/// Returns rather than shows: the caller decides how to announce the result (`showOutcome`),
/// which keeps this widget free of `ScaffoldMessenger` and testable in a bare widget tree.
Future<CommandOutcome?> showEntrySheet(BuildContext context, EntrySheetSpec spec) {
  return showModalBottomSheet<CommandOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: KhataTheme.colorsOf(context).surface,
    builder: (context) => EntrySheet(spec: spec),
  );
}

/// The sheet itself. Public so a test can drive it without the modal route.
class EntrySheet extends ConsumerStatefulWidget {
  const EntrySheet({super.key, required this.spec});

  final EntrySheetSpec spec;

  @override
  ConsumerState<EntrySheet> createState() => _EntrySheetState();
}

class _EntrySheetState extends ConsumerState<EntrySheet> {
  late final TextEditingController _amount = TextEditingController(
    text: widget.spec.initialAmountMinor == null
        ? ''
        : amountForEditing(widget.spec.initialAmountMinor!),
  );
  late final TextEditingController _memo = TextEditingController(text: widget.spec.initialMemo);
  late int _date = widget.spec.initialDate ?? EpochDay.today();
  PartyBalance? _party;
  bool _toBank = false;
  bool _busy = false;
  CommandOutcome? _refusal;

  @override
  void dispose() {
    _amount.dispose();
    _memo.dispose();
    super.dispose();
  }

  int? get _amountMinor => parseAmountMinor(_amount.text, grouping: ref.read(displayPrefsProvider).grouping);

  bool get _canSave {
    if (_busy || _amountMinor == null) return false;
    if (widget.spec.needsParty && _party == null && widget.spec.lockedPartyId == null) {
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    final amount = _amountMinor;
    if (amount == null) return;
    setState(() {
      _busy = true;
      _refusal = null;
    });

    final outcome = await widget.spec.onSave(EntrySheetValues(
      amountMinor: amount,
      entryDate: _date,
      toBank: _toBank,
      partyId: _party?.partyId ?? widget.spec.lockedPartyId,
      memo: _memo.text.trim().isEmpty ? null : _memo.text.trim(),
    ));
    if (!mounted) return;

    if (outcome.ok) {
      Navigator.of(context).pop(outcome);
      return;
    }
    // A refusal is the one thing that must not close the form: the user is here to fix it.
    setState(() {
      _busy = false;
      _refusal = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.lg, Spacing.lg, Spacing.sm),
              child: Row(
                children: [
                  Expanded(
                    child: Text(widget.spec.title, style: text.titleMedium),
                  ),
                  IconButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    icon: Icon(Icons.close, color: colors.onSurfaceMuted),
                  ),
                ],
              ),
            ),

            if (widget.spec.hint != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                child: Text(
                  widget.spec.hint!,
                  style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted),
                ),
              ),

            // The amount, big. It is the field the user came for.
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.md),
              child: Row(
                children: [
                  Text(
                    money.currencySymbol,
                    style: text.headlineSmall?.copyWith(color: colors.onSurfaceMuted),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _amount,
                      autofocus: widget.spec.initialAmountMinor == null,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.next,
                      style: text.headlineSmall?.copyWith(fontFeatures: KhataType.tabular),
                      decoration: InputDecoration(
                        hintText: widget.spec.amountLabel ?? strings.amount,
                        border: InputBorder.none,
                        errorText: _amount.text.isEmpty || _amountMinor != null
                            ? null
                            : strings.enterAValidAmount,
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _canSave ? _save() : null,
                    ),
                  ),
                ],
              ),
            ),

            if (widget.spec.needsParty)
              _PartyRow(
                label: strings.party,
                name: widget.spec.lockedPartyName ?? _party?.name,
                lockedPartyId: widget.spec.lockedPartyId,
                kind: widget.spec.partyKind,
                onPick: (party) => setState(() => _party = party),
                balanceMinor: _party?.netMinor,
                money: money,
              ),

            _DateRow(
              date: _date,
              money: money,
              strings: strings,
              onChanged: (value) => setState(() => _date = value),
            ),

            if (widget.spec.allowBank)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(strings.viaBank, style: text.bodyMedium),
                    ),
                    Switch(
                      value: _toBank,
                      onChanged: _busy ? null : (value) => setState(() => _toBank = value),
                    ),
                  ],
                ),
              ),

            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.sm),
              child: TextField(
                controller: _memo,
                textInputAction: TextInputAction.done,
                maxLines: 2,
                style: text.bodyMedium,
                decoration: InputDecoration(hintText: strings.memo, border: InputBorder.none),
              ),
            ),

            if (_refusal != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                child: Container(
                  padding: const EdgeInsets.all(Spacing.md),
                  decoration: BoxDecoration(
                    color: colors.critical.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(Radii.sm),
                    border: Border.all(color: colors.critical.withValues(alpha: 0.45)),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning_amber, size: 16, color: colors.critical),
                      const SizedBox(width: Spacing.sm),
                      Expanded(
                        child: Text(
                          _refusal!.message,
                          style: text.labelMedium?.copyWith(color: colors.critical),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

            if (_canSave && _amountMinor != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: MoneyLabel(
                    amountMinor: _amountMinor!,
                    money: money,
                    size: TypeScale.caption,
                  ),
                ),
              ),

            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.lg),
              child: FilledButton(
                onPressed: _canSave ? _save : null,
                child: Text(_busy ? strings.saving : widget.spec.saveLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The party row: either a locked fact, or a tap target that opens the picker.
class _PartyRow extends StatelessWidget {
  const _PartyRow({
    required this.label,
    required this.kind,
    required this.onPick,
    required this.money,
    this.balanceMinor,
    this.name,
    this.lockedPartyId,
  });

  final String label;
  final int kind;

  /// The chosen party, as the object — so the row can show the *name* and the balance the
  /// user is about to change. Storing only the id and printing it was the first draft's bug.
  final ValueChanged<PartyBalance> onPick;

  final MoneyFormat money;
  final int? balanceMinor;
  final String? name;
  final String? lockedPartyId;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    final locked = lockedPartyId != null;

    if (locked) {
      return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.sm),
        child: Row(
          children: [
            Text('$label: ', style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted)),
            Expanded(
              child: Text(
                name ?? lockedPartyId ?? '',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.sm),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () async {
          final picked = await showPartyPicker(context, kind: kind);
          if (picked != null) onPick(picked);
        },
        child: Row(
          children: [
            Expanded(
              child: Text(
                name == null ? '$label…' : name!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.bodyMedium,
              ),
            ),
            if (balanceMinor != null)
              MoneyLabel(
                amountMinor: balanceMinor!,
                money: money,
                kind: kind == PartyKind.supplier
                    ? LedgerColumnKind.payable
                    : LedgerColumnKind.receivable,
                size: TypeScale.caption,
              ),
            Icon(Icons.chevron_right, size: 18, color: colors.onSurfaceMuted),
          ],
        ),
      ),
    );
  }
}

/// The party picker, as a modal list. Watches `partiesProvider` so a party added in another
/// tab is offerable here without reopening the sheet — the list is a live query, not a copy.
Future<PartyBalance?> showPartyPicker(BuildContext context, {required int kind}) {
  return showModalBottomSheet<PartyBalance>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: KhataTheme.colorsOf(context).surface,
    builder: (context) => _PartyPickerSheet(kind: kind),
  );
}

class _PartyPickerSheet extends ConsumerStatefulWidget {
  const _PartyPickerSheet({required this.kind});

  final int kind;

  @override
  ConsumerState<_PartyPickerSheet> createState() => _PartyPickerSheetState();
}

class _PartyPickerSheetState extends ConsumerState<_PartyPickerSheet> {
  late final TextEditingController _query = TextEditingController();
  String _needle = '';

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final parties = ref.watch(partiesProvider(widget.kind));

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.lg, Spacing.lg, Spacing.sm),
            child: TextField(
              controller: _query,
              autofocus: true,
              style: Theme.of(context).textTheme.bodyMedium,
              decoration: InputDecoration(
                hintText: strings.searchParty,
                prefixIcon: Icon(Icons.search, size: 18, color: colors.onSurfaceMuted),
                border: InputBorder.none,
              ),
              onChanged: (value) => setState(() => _needle = value.trim().toLowerCase()),
            ),
          ),
          Expanded(
            child: parties.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, _) => Center(
                child: Text(
                  strings.couldNotLoad(error),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              data: (rows) {
                final visible = _needle.isEmpty
                    ? rows
                    : rows
                        .where((p) =>
                            p.name.toLowerCase().contains(_needle) ||
                            (p.phone ?? '').contains(_needle))
                        .toList();

                if (visible.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(Spacing.xl),
                      child: Text(
                        rows.isEmpty ? strings.noPartiesYet : strings.noMatch,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colors.onSurfaceMuted),
                      ),
                    ),
                  );
                }

                return VirtualList(
                  itemCount: visible.length,
                  itemExtent: Spacing.listRowHeight,
                  padding: EdgeInsetsDirectional.zero,
                  keyOf: (index) => ValueKey(visible[index].partyId),
                  rowBuilder: (context, index) {
                    final party = visible[index];
                    return InkWell(
                      onTap: () => Navigator.of(context).pop(party),
                      child: Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, 0),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    party.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(context).textTheme.bodyMedium,
                                  ),
                                  if (party.phone != null)
                                    Text(
                                      party.phone!,
                                      style: Theme.of(context).textTheme.labelSmall,
                                    ),
                                ],
                              ),
                            ),
                            MoneyLabel(
                              amountMinor: party.netMinor,
                              money: money,
                              kind: widget.kind == PartyKind.supplier
                                  ? LedgerColumnKind.payable
                                  : LedgerColumnKind.receivable,
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// The date row: today, yesterday, or a typed date.
///
/// Deliberately not a Material calendar picker. A month grid in Urdu needs Nastaliq month
/// names and an RTL-correct grid, which is a screen of its own — and the two dates a
/// shopkeeper actually needs are *today* and *yesterday*, with everything else being a bill
/// from last week that they will type. The typed form accepts `2026-10-11` and
/// `11/10/2026`, and [EpochDay.tryParse] decides.
class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.date,
    required this.money,
    required this.strings,
    required this.onChanged,
  });

  final int date;
  final MoneyFormat money;
  final UiStrings strings;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    final today = EpochDay.today();

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.sm),
      child: Row(
        children: [
          Text('${strings.date}: ', style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted)),
          _DateChip(label: strings.today, selected: date == today, onTap: () => onChanged(today)),
          const SizedBox(width: Spacing.xs),
          _DateChip(
            label: strings.yesterday,
            selected: date == today - 1,
            onTap: () => onChanged(today - 1),
          ),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              DateText.short(date, digits: money.digits),
              textAlign: TextAlign.right,
              style: text.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _DateChip extends StatelessWidget {
  const _DateChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.sm, 4, Spacing.sm, 4),
        decoration: BoxDecoration(
          color: selected ? colors.brand.withValues(alpha: 0.14) : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: selected ? colors.brand : colors.outline),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: TypeScale.micro,
            color: selected ? colors.brand : colors.onSurfaceMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Adding a party is three fields and one command. Kept as a sheet rather than a screen: the
/// user is almost always mid-sale when a new customer appears, and a full screen would lose
/// their place.
Future<CommandOutcome?> showAddPartySheet(BuildContext context, {required int kind}) {
  return showModalBottomSheet<CommandOutcome>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: KhataTheme.colorsOf(context).surface,
    builder: (context) => _AddPartySheet(kind: kind),
  );
}

class _AddPartySheet extends ConsumerStatefulWidget {
  const _AddPartySheet({required this.kind});

  final int kind;

  @override
  ConsumerState<_AddPartySheet> createState() => _AddPartySheetState();
}

class _AddPartySheetState extends ConsumerState<_AddPartySheet> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _nameUr = TextEditingController();
  final TextEditingController _phone = TextEditingController();
  int? _partyKind;
  bool _busy = false;
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    _nameUr.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final commands = ref.read(bookCommandsProvider);
    final name = _name.text.trim();
    if (commands == null || name.isEmpty) {
      setState(() => _problem = 'Enter a name');
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });

    final outcome = await commands.addParty(
      name: name,
      money: ref.read(moneyFormatProvider),
      nameUr: _nameUr.text.trim().isEmpty ? null : _nameUr.text.trim(),
      phone: _phone.text.trim().isEmpty ? null : _phone.text.trim(),
      kind: _partyKind ?? widget.kind,
    );
    if (!mounted) return;
    if (outcome.ok) {
      Navigator.of(context).pop(outcome);
      return;
    }
    setState(() {
      _busy = false;
      _problem = outcome.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final colors = KhataTheme.colorsOf(context);

    Widget field(TextEditingController controller, String label, {bool urdu = false}) => Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.xs, Spacing.lg, Spacing.xs),
          child: TextField(
            controller: controller,
            style: urdu ? KhataType.urdu(text.bodyLarge!) : text.bodyLarge,
            decoration: InputDecoration(labelText: label),
          ),
        );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SectionHeader(title: strings.addParty),
          field(_name, strings.name),
          field(_nameUr, strings.nameUrdu, urdu: true),
          field(_phone, strings.phone),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.sm),
            child: Row(
              children: [
                _KindChip(
                  label: strings.customer,
                  selected: (_partyKind ?? widget.kind) == PartyKind.customer,
                  onTap: () => setState(() => _partyKind = PartyKind.customer),
                ),
                const SizedBox(width: Spacing.sm),
                _KindChip(
                  label: strings.supplier,
                  selected: (_partyKind ?? widget.kind) == PartyKind.supplier,
                  onTap: () => setState(() => _partyKind = PartyKind.supplier),
                ),
                const SizedBox(width: Spacing.sm),
                _KindChip(
                  label: strings.both,
                  selected: (_partyKind ?? widget.kind) == PartyKind.both,
                  onTap: () => setState(() => _partyKind = PartyKind.both),
                ),
              ],
            ),
          ),
          if (_problem != null)
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
              child: Text(
                _problem!,
                style: text.labelMedium?.copyWith(color: colors.critical),
              ),
            ),
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.lg),
            child: FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? strings.saving : strings.save),
            ),
          ),
        ],
      ),
    );
  }
}

class _KindChip extends StatelessWidget {
  const _KindChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.md, 6, Spacing.md, 6),
        decoration: BoxDecoration(
          color: selected ? colors.brand.withValues(alpha: 0.14) : colors.surfaceVariant,
          borderRadius: BorderRadius.circular(Radii.pill),
          border: Border.all(color: selected ? colors.brand : colors.outline),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: TypeScale.caption,
            color: selected ? colors.brand : colors.onSurfaceMuted,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
