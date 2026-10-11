/// KhataPro · the states that are not data: loading, empty, failed, and "these numbers are
/// not trustworthy".
///
/// A ledger app has one failure mode that is worse than a crash: showing a *plausible*
/// number that is wrong. So the four states below are deliberate and distinct, and none of
/// them is a spinner over a half-built screen:
///
///  * **loading** — skeleton rows at the real row height, so the list does not jump when
///    data arrives. No shimmer animation: it repaints a full-width gradient every frame on
///    the one screen the user is waiting on, and it makes a fast load feel slower.
///  * **empty** — a sentence that says *what to do*, not "no data". "No entries yet" on a
///    party's ledger means "you have not traded with them", which is worth saying.
///  * **failed** — the error text with a retry that re-runs the same query. A failed page in
///    the middle of a long list is recoverable in place ([LoadMoreFooter]); a failed first
///    page is not ([ErrorState]).
///  * **integrity** — [IntegrityBanner], shown when the ledger walk did not reach zero. The
///    balances on screen are then derived from an anchor that does not hold, and the banner
///    says that in words instead of rendering numbers that look fine.
library;

import 'package:flutter/material.dart';

import '../../core/errors/khata_exception.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';

/// Placeholder rows at [Spacing.listRowHeight], so the transition to real data is a
/// repaint rather than a re-layout of the whole viewport.
class SkeletonRows extends StatelessWidget {
  const SkeletonRows({
    super.key,
    this.count = 8,
    this.rowHeight = Spacing.listRowHeight,
    this.inset = Spacing.lg,
  });

  final int count;
  final double rowHeight;
  final double inset;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return ListView.builder(
      // Not a real list: it is never scrolled far enough to matter, and `NeverScrollable`
      // would fight the pull-to-refresh the parent may own.
      physics: const ScrollPhysics(),
      itemCount: count,
      itemBuilder: (context, index) => SizedBox(
        height: rowHeight,
        child: Padding(
          padding: EdgeInsetsDirectional.only(start: inset, end: inset),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Container(
              height: 12,
              // Two bars of unequal length read as text without pretending to be it.
              width: index.isEven ? 160 : 96,
              decoration: BoxDecoration(
                color: colors.surfaceVariant,
                borderRadius: BorderRadius.circular(Radii.sm),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Nothing to show, and why.
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.title,
    required this.message,
    this.icon,
    this.actionLabel,
    this.onAction,
  });

  final String title;
  final String message;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 40, color: colors.onSurfaceMuted),
              const SizedBox(height: Spacing.lg),
            ],
            Text(title, style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: Spacing.sm),
            Text(
              message,
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceMuted),
            ),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: Spacing.xl),
              SizedBox(
                height: Spacing.minTouchTarget,
                child: FilledButton(
                  onPressed: onAction,
                  child: Text(actionLabel!),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A first load (or a reload) that failed. Retry runs the same query again — the state
/// layer's `refresh()` — rather than rebuilding the widget tree and hoping.
class ErrorState extends StatelessWidget {
  const ErrorState({
    super.key,
    required this.error,
    this.onRetry,
    this.title = 'Could not load this',
  });

  final Object error;
  final Future<void> Function()? onRetry;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 40, color: colors.critical),
            const SizedBox(height: Spacing.lg),
            Text(title, style: text.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: Spacing.sm),
            // `KhataException.message` is already a sentence for a human; anything else is
            // shown verbatim too, because a swallowed error is a bug report that never
            // reaches anyone.
            Text(
              error is KhataException ? (error as KhataException).message : '$error',
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(color: colors.onSurfaceMuted),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: Spacing.xl),
              SizedBox(
                height: Spacing.minTouchTarget,
                child: OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The bottom of a paged list: still loading, nothing more, or the page that failed.
///
/// It is a *row in the list*, not an overlay, so it scrolls into view exactly when the user
/// needs the information — and so a failed page can be retried without losing the scroll
/// position, which is the whole point of not replacing the list with an error screen.
class LoadMoreFooter extends StatelessWidget {
  const LoadMoreFooter({
    super.key,
    this.isLoading = false,
    this.hasMore = true,
    this.error,
    this.onRetry,
    this.endLabel = 'That is the beginning of this book.',
    this.count,
  });

  final bool isLoading;
  final bool hasMore;
  final Object? error;
  final Future<void> Function()? onRetry;

  /// Shown when the list is exhausted. "That is the beginning" is deliberately literal: the
  /// ledger loads newest-first, so the bottom of the list is the *start* of the book.
  final String endLabel;

  /// The number of entries walked, once known. A count is the cheapest way to make a long
  /// list feel finite.
  final int? count;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;

    if (error != null) {
      return Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 16, color: colors.critical),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                'Older entries could not be loaded.',
                style: text.bodySmall?.copyWith(color: colors.onCanvas),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (isLoading) {
      return const Padding(
        padding: EdgeInsets.all(Spacing.lg),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (hasMore) {
      // Neither loading nor finished: the prefetch has not fired yet. An empty box keeps
      // the extent stable so a page arriving does not move the scroll position.
      return const SizedBox(height: Spacing.listRowHeight);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.xl,
      ),
      child: Center(
        child: Text(
          count == null ? endLabel : '$endLabel ($count entries)',
          style: text.labelSmall,
        ),
      ),
    );
  }
}

/// "These numbers are not trustworthy."
///
/// Shown when a ledger walk from the closing balance does not land on zero. Per the verified
/// layer, that means the opening balance of the oldest loaded row disagrees with the sum of
/// what is loaded — the anchor moved under the walk (a sync landed mid-read) or a row is
/// missing. Either way the fix is to reload, so the banner carries the action.
class IntegrityBanner extends StatelessWidget {
  const IntegrityBanner({
    super.key,
    required this.note,
    this.onReload,
  });

  final String note;
  final Future<void> Function()? onReload;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: colors.critical, width: 1.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning, size: 20, color: colors.critical),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'The balances below may be wrong',
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: Spacing.xs),
                // The verified layer's own words: it knows which walk failed and by how
                // much, and paraphrasing it here would lose that.
                Text(note, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (onReload != null)
            TextButton(onPressed: onReload, child: const Text('Reload')),
        ],
      ),
    );
  }
}

/// A quiet banner for states that need attention but are not wrong: sync is behind, a backup
/// is unverified, the device has never paired. Distinct from [IntegrityBanner] on purpose —
/// an app that cries wolf about its books teaches the user to ignore the one banner that
/// matters.
class AttentionBanner extends StatelessWidget {
  const AttentionBanner({
    super.key,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return Container(
      margin: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.xs,
      ),
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(Radii.sm),
      ),
      child: Row(
        children: [
          Icon(Icons.sync, size: 16, color: colors.warning),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(message, style: Theme.of(context).textTheme.bodySmall),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(onPressed: onAction, child: Text(actionLabel!)),
        ],
      ),
    );
  }
}
