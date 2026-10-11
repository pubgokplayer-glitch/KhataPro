/// KhataPro · the one place a rupee amount becomes a coloured string.
///
/// Three files could each have decided how a number looks — the ledger rows, the dashboard
/// tiles, the bill book — and then three files would disagree, which is how an app starts to
/// feel untrustworthy about money. So there is exactly one:
///
/// * [ledgerTone] decides the colour, from the amount's sign **and** the column it is in,
/// * [MoneyLabel] renders the amount with its `Dr`/`Cr` suffix, tabular figures and the
///   `KhataColors` tone, right-aligned so a column of them scans vertically,
/// * [MoneyText] is the same for a total that is not a ledger row (a tile, a header).
///
/// ## The colour rule, restated where the code lives
///
/// | ledger | `+` | `−` |
/// | --- | --- | --- |
/// | receivable (customer owes you) | credit sale — **default ink** | receipt — **`moneyIn`** |
/// | payable (you owe supplier) | bill received — **default ink** | payment made — **`moneyOut`** |
/// | cash / bank | cash in — **`moneyIn`** | cash out — **`moneyOut`** |
///
/// The `Dr`/`Cr` suffix is derived from the same signed amount (`BalanceSide.of`), so colour
/// and suffix can never contradict each other: an amount whose sign is positive prints `Dr`
/// and takes the tone that sign earns in its column. Colour is never the only signal — the
/// suffix is always there, and the sign is in the digits.
library;

import 'package:flutter/material.dart';

import '../format/formatting.dart';
import '../theme/theme.dart';

/// Which column a row belongs to — the input to [ledgerTone].
enum LedgerColumnKind {
  /// Party sub-ledger under the receivable control: customers who owe the business.
  receivable,

  /// Party sub-ledger under the payable control: suppliers the business owes.
  payable,

  /// A cash, bank or wallet account: the amounts are literal cash movements.
  cash,
}

/// The one colour decision for a ledger row. See the library comment for the table and the
/// reasoning; this function exists so the party ledger, the cash book and any future report
/// cannot each invent their own answer.
Color ledgerTone(int amountMinor, LedgerColumnKind kind, KhataColors colors) {
  switch (kind) {
    case LedgerColumnKind.cash:
      if (amountMinor > 0) return colors.moneyIn;
      if (amountMinor < 0) return colors.moneyOut;
      return colors.onCanvas;
    case LedgerColumnKind.receivable:
      // Only the receipt is coloured: it is the event the shopkeeper is looking for.
      return amountMinor < 0 ? colors.moneyIn : colors.onCanvas;
    case LedgerColumnKind.payable:
      return amountMinor < 0 ? colors.moneyOut : colors.onCanvas;
  }
}

/// A signed amount in the app's money format, with the accounting suffix beside it.
///
/// The suffix is `Dr`/`Cr` — printed from the row's own sign, never passed in — because a
/// shopkeeper who has learned the ledger from paper reads the suffix first and the digits
/// second. `showSide: false` exists for the one case where the side would be misleading: a
/// **balance** row, where the side is already the column heading.
class MoneyLabel extends StatelessWidget {
  const MoneyLabel({
    super.key,
    required this.amountMinor,
    required this.money,
    this.kind = LedgerColumnKind.receivable,
    this.showSide = true,
    this.size,
    this.weight = FontWeight.w500,
    this.emphasis = false,
  });

  final int amountMinor;
  final MoneyFormat money;
  final LedgerColumnKind kind;

  /// Print the `Dr`/`Cr` suffix. Off for totals and balances, where the heading says it.
  final bool showSide;

  /// Overrides the type scale. Used by the dashboard's tiles, which are larger than a row.
  final double? size;
  final FontWeight weight;

  /// A little darker and bolder: used for the balance carried into a day header.
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final scale = Theme.of(context).textTheme;
    final base = size == null ? scale.bodyMedium : null;
    // The suffix comes from the same signed value the digits do, so the two cannot disagree.
    final label = money.signed(amountMinor);
    final side = showSide ? BalanceSide.of(amountMinor).label : '';

    return Text(
      side.isEmpty ? label : '$label $side',
      textAlign: TextAlign.right,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: (base ?? const TextStyle()).copyWith(
        color: ledgerTone(amountMinor, kind, colors),
        fontSize: size,
        fontWeight: emphasis ? FontWeight.w600 : weight,
        fontFeatures: KhataType.tabular,
      ),
    );
  }
}

/// An unsigned amount — a total, a price, a tile's number.
class MoneyText extends StatelessWidget {
  const MoneyText({
    super.key,
    required this.amountMinor,
    required this.money,
    this.color,
    this.size,
    this.weight = FontWeight.w600,
    this.absolute = false,
  });

  final int amountMinor;
  final MoneyFormat money;
  final Color? color;
  final double? size;
  final FontWeight weight;

  /// Print the magnitude with no sign at all. Used for "this month's sales", where a minus
  /// would suggest a refund rather than a total, and for the same figure in two languages.
  final bool absolute;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return Text(
      absolute ? money.amount(amountMinor) : money.format(amountMinor),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color ?? colors.onCanvas,
        fontSize: size,
        fontWeight: weight,
        fontFeatures: KhataType.tabular,
      ),
    );
  }
}
