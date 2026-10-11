import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../apps/deep_links.dart';
import '../format/strings.dart';
import '../state/providers.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/forms.dart';
import '../widgets/ledger_view.dart';
import '../widgets/money_label.dart';
import '../widgets/outcome_toast.dart';
import '../widgets/skeletons.dart';
import '../widgets/virtual_list.dart';
import '../../data/db/dao/parties_dao.dart' show PartyKind;
import 'package:go_router/go_router.dart';

/// The party list: who owes me, who I owe.
///
/// ## Why the search box is state and the list is not
///
/// The filter is a `String` in this widget's state and the rows come from `partiesProvider`;
/// typing re-runs `where` over a list that is *already in memory* (a shop with 400 customers
/// holds 400 rows in about 40 KB) and never touches the database. A `LIKE` query per keystroke
/// would hit SQLCipher's cipher layer 10 times a second for a result the app already has.
///
/// The provider itself is a `StreamProvider`: a party added on another phone through the LAN
/// sync, or by the picker in another tab, appears here without this screen doing anything.
class PartyListScreen extends ConsumerStatefulWidget {
  const PartyListScreen({super.key, this.kind = 0});

  /// 0 = customers, 1 = suppliers, 2 = everyone. Mapped rather than passed as a `PartyKind` so
  /// the route table can carry it as a query parameter.
  final int kind;

  @override
  ConsumerState<PartyListScreen> createState() => _PartyListScreenState();
}

class _PartyListScreenState extends ConsumerState<PartyListScreen> {
  final TextEditingController _query = TextEditingController();
  String _needle = '';

  int get _partyKind {
    switch (widget.kind) {
      case 1:
        return PartyKind.supplier;
      case 2:
        return PartyKind.both;
      default:
        return PartyKind.customer;
    }
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);
    final parties = ref.watch(partiesProvider(_partyKind));

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.kind == 1 ? strings.suppliers : strings.customers),
        actions: [
          IconButton(
            tooltip: strings.addParty,
            onPressed: () async {
              final outcome = await showAddPartySheet(context, kind: _partyKind);
              if (outcome != null && context.mounted) showOutcome(context, outcome);
            },
            icon: const Icon(Icons.person_add),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, Spacing.sm),
            child: TextField(
              controller: _query,
              style: text.bodyMedium,
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
              // Deliberately not `SkeletonRows(8)`: the row height here is the list's own
              // constant, so the skeleton matches the real thing pixel for pixel and the
              // screen does not visibly reflow when the data lands.
              loading: () => const SkeletonRows(count: 8, rowHeight: Spacing.listRowHeight),
              error: (error, _) => ErrorState(
                error: error,
                title: strings.parties,
                onRetry: () async => ref.invalidate(partiesProvider(_partyKind)),
              ),
              data: (rows) {
                final visible = _needle.isEmpty
                    ? rows
                    : rows
                        .where((p) =>
                            p.name.toLowerCase().contains(_needle) ||
                            (p.nameUr ?? '').contains(_query.text.trim()) ||
                            (p.phone ?? '').contains(_needle))
                        .toList();

                if (visible.isEmpty) {
                  return EmptyState(
                    icon: Icons.person_add,
                    title: rows.isEmpty ? strings.noPartiesYet : strings.noMatch,
                    message: rows.isEmpty ? strings.addPartyHint : strings.tryAnotherName,
                    actionLabel: rows.isEmpty ? strings.addParty : null,
                    onAction: rows.isEmpty
                        ? () async {
                            final outcome = await showAddPartySheet(context, kind: _partyKind);
                            if (outcome != null && context.mounted) showOutcome(context, outcome);
                          }
                        : null,
                  );
                }

                return VirtualList(
                  itemCount: visible.length,
                  itemExtent: Spacing.listRowHeight,
                  padding: const EdgeInsetsDirectional.only(bottom: 96),
                  keyOf: (index) => ValueKey(visible[index].partyId),
                  rowBuilder: (context, index) {
                    final party = visible[index];
                    return ListRowTile(
                      title: party.nameUr ?? party.name,
                      subtitle: party.phone,
                      onTap: () => context.go(KhataRoutes.partyLedger(party.partyId)),
                      trailing: MoneyLabel(
                        amountMinor: party.netMinor,
                        money: money,
                        kind: _partyKind == PartyKind.supplier
                            ? LedgerColumnKind.payable
                            : LedgerColumnKind.receivable,
                        emphasis: party.netMinor != 0,
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final outcome = await showAddPartySheet(context, kind: _partyKind);
          if (outcome != null && context.mounted) showOutcome(context, outcome);
        },
        tooltip: strings.addParty,
        child: const Icon(Icons.add),
      ),
    );
  }
}
