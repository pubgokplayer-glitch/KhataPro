/// KhataPro · the small pieces every screen is built out of.
///
/// These exist so the eight screens are *composition* and not layout: a shopkeeper's home
/// screen is six numbers, one chart and a list of who owes money, and if each screen drew its
/// own tile the app would have eight slightly different greys in it.
///
/// Three rules the tiles follow, all of them from `docs/UI.md` §4:
///
/// * **Height is fixed, never intrinsic.** [KpiTile] is a `SizedBox` with a known height, so a
///   longer label replaces nothing and re-lays out nothing. The grid of tiles on the dashboard
///   therefore costs one layout pass, not six.
/// * **The number is the only thing that gets the big type.** Label, value, caption in that
///   order of size — which is what makes the screen readable at arm's length in a shop.
/// * **Colour comes from [ledgerTone] or from `KhataColors`; never from a hex literal here.**
library;

import 'package:flutter/material.dart';

import '../format/formatting.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'money_label.dart';

/// One number the owner watches, with a label and an optional caption.
///
/// [tone] is passed in rather than derived: only the caller knows whether a figure is good
/// news (a receipt) or bad (a payment out), and guessing from the sign is how a dashboard
/// ends up painting a customer's growing debt in a reassuring green.
class KpiTile extends StatelessWidget {
  const KpiTile({
    super.key,
    required this.label,
    required this.value,
    this.caption,
    this.tone,
    this.icon,
    this.onTap,
    this.height = 92,
  });

  final String label;

  /// Already formatted — `MoneyText`'s output or a plain string. The tile does not format,
  /// because a tile showing "3" and a tile showing "Rs 3" are both legitimate.
  final Widget value;

  final String? caption;
  final Color? tone;
  final IconData? icon;
  final VoidCallback? onTap;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    final accent = tone ?? colors.onCanvas;

    final body = Container(
      height: height,
      padding: const EdgeInsetsDirectional.fromSTEB(Spacing.md, Spacing.sm, Spacing.md, Spacing.sm),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: colors.onSurfaceMuted),
                const SizedBox(width: Spacing.xs),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted),
                ),
              ),
            ],
          ),
          value,
          if (caption != null)
            Text(
              caption!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.labelSmall?.copyWith(color: accent == colors.onCanvas ? colors.onSurfaceMuted : accent),
            )
          else
            const SizedBox(height: 1),
        ],
      ),
    );

    if (onTap == null) return body;
    return GestureDetector(behavior: HitTestBehavior.opaque, onTap: onTap, child: body);
  }
}

/// A money tile, which is what five of the six dashboard tiles are.
class MoneyKpiTile extends StatelessWidget {
  const MoneyKpiTile({
    super.key,
    required this.label,
    required this.amountMinor,
    required this.money,
    this.caption,
    this.tone,
    this.icon,
    this.onTap,
    this.compactValue = false,
  });

  final String label;
  final int amountMinor;
  final MoneyFormat money;
  final String? caption;
  final Color? tone;
  final IconData? icon;
  final VoidCallback? onTap;

  /// `Rs 1.2Cr` instead of `Rs 1,23,45,678.00`. For the tiles whose value can run to eight
  /// digits, where the full form would either shrink the type or wrap the tile.
  final bool compactValue;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    final value = compactValue
        ? money.compact(amountMinor)
        : money.format(amountMinor);

    return KpiTile(
      label: label,
      tone: tone,
      icon: icon,
      onTap: onTap,
      value: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: text.titleMedium?.copyWith(
          color: tone ?? colors.onCanvas,
          fontWeight: FontWeight.w700,
          fontFeatures: KhataType.tabular,
        ),
      ),
      caption: caption,
    );
  }
}

/// "Parties", "Bills", "Today" — a heading with an optional action on the trailing edge.
///
/// The action is a `TextButton`, deliberately: on this app's surfaces the *list* is the
/// primary affordance, and a coloured button in a section header competes with the row taps
/// that matter.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.actionLabel,
    this.onAction,
    this.trailing,
    this.padding = const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.lg, Spacing.lg, Spacing.sm),
  });

  final String title;
  final String? actionLabel;
  final VoidCallback? onAction;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (trailing != null) trailing!,
          if (actionLabel != null && onAction != null)
            TextButton(
              onPressed: onAction,
              child: Text(actionLabel!, style: text.labelMedium?.copyWith(color: colors.brand)),
            ),
        ],
      ),
    );
  }
}

/// A small filled pill: a bill's state, an aging bucket, "low stock".
///
/// The tone is a parameter for the same reason it is on [KpiTile] — and because the aging
/// buckets are the one place the app must *not* be cheerful: a 90-day overdue bill in the
/// brand colour is a bill the shopkeeper will not chase.
class TonePill extends StatelessWidget {
  const TonePill({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
  });

  final String label;
  final Color tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(Spacing.sm, 3, Spacing.sm, 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: tone.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: tone),
            const SizedBox(width: Spacing.xs),
          ],
          Text(
            label,
            maxLines: 1,
            style: TextStyle(
              color: tone,
              fontSize: TypeScale.micro,
              fontWeight: FontWeight.w600,
              fontFeatures: KhataType.tabular,
            ),
          ),
        ],
      ),
    );
  }
}

/// A fixed-height row used by the parties, bills, stock and staff lists.
///
/// One row type for four screens: [title] is what the user is looking for (a name, a bill
/// number, an item), [subtitle] is what disambiguates it, [trailing] is the number. The
/// height is fixed at [Spacing.listRowHeight] because every one of those lists is a
/// `VirtualList` whose `itemExtentBuilder` promised it.
class ListRowTile extends StatelessWidget {
  const ListRowTile({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.badges,
    this.leading,
    this.onTap,
    this.onLongPress,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final List<Widget>? badges;
  final Widget? leading;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;

    final row = SizedBox(
      height: Spacing.listRowHeight,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, 0),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: Spacing.md)],
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted),
                    ),
                ],
              ),
            ),
            if (badges != null) ...[
              for (final badge in badges!) ...[badge, const SizedBox(width: Spacing.xs)],
            ],
            if (trailing != null) ...[
              const SizedBox(width: Spacing.sm),
              trailing!,
            ],
          ],
        ),
      ),
    );

    if (onTap == null && onLongPress == null) return row;
    return InkWell(onTap: onTap, onLongPress: onLongPress, child: row);
  }
}

/// The divider the lists use: an inset hairline, so the eye follows the title column and not
/// the full-width rule.
class ListHairline extends StatelessWidget {
  const ListHairline({super.key, this.indent = Spacing.lg});

  final double indent;

  @override
  Widget build(BuildContext context) {
    return Divider(height: 1, thickness: 1, indent: indent, color: KhataTheme.colorsOf(context).outline);
  }
}
