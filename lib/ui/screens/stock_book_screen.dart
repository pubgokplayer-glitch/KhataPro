import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../format/formatting.dart';
import '../format/strings.dart';
import '../state/providers.dart';
import '../state/queries.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/ledger_view.dart';
import '../widgets/money_label.dart';
import '../widgets/skeletons.dart';
import '../widgets/virtual_list.dart';

/// The stock book: what is on the shelf, what it is worth, and what has run out.
///
/// ## Quantities are integers, and so is the display
///
/// `quantity_milli` is an integer count of thousandths (`docs/DATA_LAYER.md`: no floats in the
/// money or the goods). The screen formats it with integer arithmetic in [formatQuantity] —
/// `(q - q % 1000) ~/ 1000` plus a three-digit fraction — because a `double` that renders
/// `11.999999999` where the books say 12 kg is the kind of thing a shopkeeper notices.
///
/// ## Why the low-stock filter is a query and not a `.where`
///
/// `stockProvider(lowOnly)` passes the flag into SQL. Filtering in Dart would page, decrypt and
/// deserialize every item in the shop to show the six that need reordering.
class StockBookScreen extends ConsumerStatefulWidget {
  const StockBookScreen({super.key});

  @override
  ConsumerState<StockBookScreen> createState() => _StockBookScreenState();
}

class _StockBookScreenState extends ConsumerState<StockBookScreen> {
  bool _lowOnly = false;

  @override
  Widget build(BuildContext context) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);

    return Scaffold(
      appBar: AppBar(title: Text(strings.stockBook)),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, 0),
            child: Row(
              children: [
                Expanded(child: Text(strings.lowStockOnly, style: Theme.of(context).textTheme.bodyMedium)),
                Switch(value: _lowOnly, onChanged: (value) => setState(() => _lowOnly = value)),
              ],
            ),
          ),
          Expanded(
            child: ref.watch(stockProvider(_lowOnly)).when(
                  loading: () => const SkeletonRows(count: 10, rowHeight: Spacing.listRowHeight),
                  error: (error, _) => ErrorState(error: error, title: strings.stockBook),
                  data: (items) {
                    if (items.isEmpty) {
                      return EmptyState(
                        icon: Icons.inventory_2,
                        title: strings.nothingInStock,
                        message: strings.stockComesFromBills,
                      );
                    }
                    return VirtualList(
                      itemCount: items.length,
                      itemExtent: Spacing.listRowHeight,
                      padding: const EdgeInsetsDirectional.only(bottom: 96),
                      keyOf: (index) => ValueKey(items[index].itemId),
                      rowBuilder: (context, index) {
                        final item = items[index];
                        final low = item.isStocked &&
                            item.quantityMilli <= item.reorderLevelMilli &&
                            item.reorderLevelMilli > 0;
                        return ListRowTile(
                          title: item.nameUr ?? item.name,
                          subtitle: item.sku ?? item.unit,
                          badges: [
                            if (low)
                              TonePill(
                                label: strings.lowStock,
                                tone: KhataTheme.colorsOf(context).critical,
                              ),
                          ],
                          onTap: () => showStockMoves(context, item),
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                formatQuantity(item.quantityMilli, unit: item.unit),
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                      fontFeatures: KhataType.tabular,
                                      fontWeight: FontWeight.w600,
                                    ),
                              ),
                              Text(money.amount(item.valueMinor), style: Theme.of(context).textTheme.labelSmall),
                            ],
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

/// `1234` milli + unit `kg` → `1.234 kg`, with no trailing zeros: `12.000 kg` reads as a
/// precision the shop does not have. Integer arithmetic only.
String formatQuantity(int milli, {String? unit}) {
  final whole = milli ~/ 1000;
  final fraction = (milli % 1000).abs();
  var text = '$whole';
  if (fraction != 0) {
    var digits = fraction.toString().padLeft(3, '0');
    while (digits.endsWith('0')) {
      digits = digits.substring(0, digits.length - 1);
    }
    text = '$whole.$digits';
  }
  return unit == null ? text : '$text $unit';
}

/// Where did it go: the movement history for one item, newest first.
Future<void> showStockMoves(BuildContext context, StockRow item) {
  return showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: KhataTheme.colorsOf(context).surface,
    builder: (context) => _StockMovesSheet(item: item),
  );
}

class _StockMovesSheet extends ConsumerWidget {
  const _StockMovesSheet({required this.item});

  final StockRow item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final money = ref.watch(moneyFormatProvider);

    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        children: [
          SectionHeader(title: '${strings.movements} · ${item.nameUr ?? item.name}'),
          Expanded(
            child: ref.watch(stockMovesProvider(item.itemId)).when(
                  loading: () => const SkeletonRows(count: 6, rowHeight: Spacing.listRowHeight),
                  error: (error, _) => ErrorState(error: error, title: strings.movements),
                  data: (moves) {
                    if (moves.isEmpty) {
                      return EmptyState(icon: Icons.sync, title: strings.noMovements, message: strings.noMovementsHint);
                    }
                    return VirtualList(
                      itemCount: moves.length,
                      itemExtent: Spacing.listRowHeight,
                      padding: EdgeInsetsDirectional.zero,
                      keyOf: (index) => ValueKey(moves[index].moveId),
                      rowBuilder: (context, index) {
                        final move = moves[index];
                        return ListRowTile(
                          title: DateText.short(move.moveDate, digits: money.digits),
                          subtitle: move.note ?? move.itemName,
                          trailing: MoneyText(
                            amountMinor: move.direction > 0 ? move.valueMinor : -move.valueMinor,
                            money: money,
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
