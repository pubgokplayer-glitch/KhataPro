/// KhataPro · the one list widget the long screens are built on.
///
/// The requirement is a shopkeeper scrolling a 10 000-entry cash book with zero jank at a
/// constant 60–120 fps. That is an engineering question with four answers, and this file is
/// all four:
///
/// 1. **`ListView.builder` with `itemExtentBuilder`.** With a per-index extent the viewport
///    can compute *any* row's position arithmetically — no measuring, no layout pass over
///    off-screen children, and the scrollbar thumb is exact rather than estimated. A
///    variable-extent ledger without this measures every child to find the scroll limit,
///    which is where the frame budget goes on a 10 000-row list.
/// 2. **No second `RepaintBoundary`.** `ListView.builder` already wraps every child in one
///    (`addRepaintBoundaries` defaults to true). Wrapping rows again — a common cargo-cult
///    "optimisation" — allocates a second layer per row and makes repaints *slower*.
///    `addAutomaticKeepAlives: false` for the same reason: keeping 10 000 rows alive buys
///    nothing in a list whose rows are cheap to build, and costs the memory the frame
///    budget is competing for.
/// 3. **Prefetch driven by the scroll notification, not by a post-frame callback.** Rows are
///    loaded from SQLite by keyset pages; the fetch is triggered when the viewport comes
///    within [loadMoreThreshold] pixels of the end, so the next page is usually already in
///    hand before the user reaches it. It fires **once per page**, not once per frame:
///    `_requested` is re-armed only when the state layer says there is more to fetch.
/// 4. **Stable keys + `findChildIndexCallback`.** A row that was on screen and left it is
///    rebuilt by index unless the list can map its key back to a position. During an insert
///    (a sync landing at the top of the ledger) that is the difference between "the list
///    shifts and keeps your place" and "the list jumps".
///
/// What this file deliberately does *not* do: build any row contents (that is
/// `ledger_view.dart` and the screens), hold any provider (the screens pass closures, so
/// rebuilds stay scoped — directive #4), or animate anything (a scroll is already an
/// animation; adding one costs frames).
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Builds the widget for one index. Same shape as `IndexedWidgetBuilder`, named for the
/// list's contract: what you return must be safe to rebuild at any time.
typedef VirtualRowBuilder = Widget Function(BuildContext context, int index);

/// A windowed list.
///
/// [itemCount] is the number of *cells*, not rows: the ledger's day headers are cells too
/// (see `LedgerLayout.cells`), which is what keeps `itemCount`, the scrollbar and the index
/// arithmetic in agreement.
class VirtualList extends StatefulWidget {
  const VirtualList({
    super.key,
    required this.itemCount,
    required this.rowBuilder,
    this.itemExtent,
    this.itemExtentBuilder,
    this.controller,
    this.onLoadMore,
    this.canLoadMore = false,
    this.loadMoreThreshold = 1200,
    this.onVisibleRange,
    this.keyOf,
    this.indexOfKey,
    this.padding,
    this.cacheExtent = 400,
    this.showScrollbar = true,
    this.physics,
    this.reverse = false,
  }) : assert(
          itemExtent == null || itemExtentBuilder == null,
          'give the list either a uniform itemExtent or an itemExtentBuilder, not both',
        );

  final int itemCount;
  final VirtualRowBuilder rowBuilder;

  /// Height of every row. Use this when the list is uniform — it is the cheapest path,
  /// because it needs no callback at all per index.
  final double? itemExtent;

  /// Height of row `index` in this layout. Constant-time arithmetically; see the class
  /// comment for why a ledger's headers and rows need it.
  final ItemExtentBuilder? itemExtentBuilder;

  final ScrollController? controller;

  /// Called when the viewport is within [loadMoreThreshold] px of the end and
  /// [canLoadMore] is true. Fires once per arming; re-armed when [canLoadMore] flips or
  /// [itemCount] changes.
  final Future<void> Function()? onLoadMore;

  /// The state layer's answer to "is there another page?". Passed in rather than derived,
  /// because only the pager knows (a list can be longer than the loaded pages).
  final bool canLoadMore;

  /// How close to the end to start the next page. 1200 px is ~21 ledger rows — comfortably
  /// a page ahead of a fast flick, and small enough that a user who stops mid-list has not
  /// paid for pages they will never look at.
  final double loadMoreThreshold;

  /// Reports the visible window `(first, last)` after a scroll settles. The cash book uses
  /// it to keep its chart's window in step with what is on screen.
  final void Function(int first, int last)? onVisibleRange;

  /// The key of cell `index`, for keyed rows. Stable keys are what let the framework keep
  /// a row's element when the list changes above it.
  final Key? Function(int index)? keyOf;

  /// Answers "which index is this key at now?" after an insert.
  ///
  /// Deliberately **not** derived from [keyOf] by scanning: the framework calls this once
  /// per key that disappeared from the built range, and a scan would be O(itemCount) each
  /// time — 10 000 rows × a few dozen keys, paid on the frame a sync lands, which is the
  /// one frame that must not stutter. The caller already holds the cells list, so it can
  /// answer from a map it built for the same state; when it does not supply one, the list
  /// simply omits `findChildIndexCallback` and the framework's index-based default runs.
  final int? Function(Key key)? indexOfKey;

  final EdgeInsetsGeometry? padding;

  /// Rows kept alive outside the viewport. 400 px ≈ seven ledger rows: enough that a
  /// fling reveals built widgets, small enough that it is not a memory story on a 2 GB
  /// phone.
  final double? cacheExtent;

  final bool showScrollbar;
  final ScrollPhysics? physics;
  final bool reverse;

  @override
  State<VirtualList> createState() => _VirtualListState();
}

class _VirtualListState extends State<VirtualList> {
  ScrollController? _owned;
  /// True while a load has been asked for and the state layer has not answered yet.
  bool _requested = false;
  int _lastFirst = -1;
  int _lastLast = -1;

  /// The list owns a controller when the caller did not supply one, so the scroll offset
  /// can be preserved across a rebuild without every screen having to remember to manage it.
  ScrollController get _controller => widget.controller ?? (_owned ??= ScrollController());

  @override
  void didUpdateWidget(covariant VirtualList oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Re-arm the prefetch when the state layer says another page became available, or when
    // the list grew for any other reason (a sync insert). Without this the list would stop
    // loading after the first page and look "finished".
    if (widget.canLoadMore && (!oldWidget.canLoadMore || widget.itemCount != oldWidget.itemCount)) {
      _requested = false;
    }
    if (widget.canLoadMore && !_requested) {
      // A page can arrive without a scroll event (the content was shorter than the
      // viewport). One notification-silent check keeps the list filling.
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeLoad());
    }
  }

  @override
  void dispose() {
    _owned?.dispose();
    super.dispose();
  }

  bool _maybeLoad() {
    if (_requested || !widget.canLoadMore || widget.onLoadMore == null) return false;
    if (!mounted) return false;
    _requested = true;
    // The callback is responsible for its own errors: a failed page must surface in the
    // list (see `skeletons.dart`'s failure footer), not as an unhandled async error.
    widget.onLoadMore!();
    return true;
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is! ScrollUpdateNotification) return false;
    final metrics = notification.metrics;
    final extentAfter = metrics.maxScrollExtent - metrics.pixels;
    if (extentAfter <= widget.loadMoreThreshold) _maybeLoad();

    final onVisibleRange = widget.onVisibleRange;
    if (onVisibleRange != null) {
      final first = _cellAt(metrics.pixels);
      final last = _cellAt(metrics.pixels + metrics.viewportDimension);
      if (first != _lastFirst || last != _lastLast) {
        _lastFirst = first;
        _lastLast = last;
        onVisibleRange(first, last);
      }
    }
    return false;
  }

  /// Which cell sits at [dy] of scroll extent. Uses the same extent function the viewport
  /// does, so the visible-range report cannot disagree with what is drawn.
  int _cellAt(double dy) {
    final uniform = widget.itemExtent;
    if (uniform != null) {
      return (dy / uniform).floor().clamp(0, widget.itemCount == 0 ? 0 : widget.itemCount - 1);
    }
    final builder = widget.itemExtentBuilder;
    if (builder == null) return 0;
    final dimensions = SliverLayoutDimensions(
      scrollOffset: dy,
      precedingScrollExtent: null,
      crossAxisExtent: 0,
      viewportMainAxisExtent: 0,
    );
    var offset = 0.0;
    for (var index = 0; index < widget.itemCount; index++) {
      final extent = builder(index, dimensions) ?? 0;
      if (offset + extent > dy) return index;
      offset += extent;
    }
    return widget.itemCount == 0 ? 0 : widget.itemCount - 1;
  }

  @override
  Widget build(BuildContext context) {
    final keyOf = widget.keyOf;
    final list = ListView.builder(
      controller: _controller,
      reverse: widget.reverse,
      // Vertical lists are not mirrored by RTL, but their padding is: `EdgeInsetsDirectional`
      // means the same widget looks right in Urdu without a second code path.
      padding: widget.padding,
      physics: widget.physics,
      itemCount: widget.itemCount,
      itemExtent: widget.itemExtent,
      itemExtentBuilder: widget.itemExtentBuilder,
      addAutomaticKeepAlives: false,
      cacheExtent: widget.cacheExtent,
      findChildIndexCallback:
          widget.indexOfKey == null ? null : (key) => widget.indexOfKey!(key),
      itemBuilder: (context, index) => KeyedSubtree(
        key: keyOf?.call(index),
        child: widget.rowBuilder(context, index),
      ),
    );

    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: widget.showScrollbar
          ? Scrollbar(
              controller: _controller,
              // A thumb that only appears while scrolling: a permanently visible one on a
              // 10 000-row list is a 4-px overlay repainting over every row it crosses.
              thickness: 3,
              radius: const Radius.circular(Radii.pill),
              child: list,
            )
          : list,
    );
  }
}

/// The extent function for a list of one header per day plus uniform rows.
///
/// Kept here (rather than in the ledger widget) because the *screens* need it too: the
/// index of a cell must be computable from a day boundary when the cash book jumps to a
/// date, and both callers must use the same arithmetic or the jump lands a row off.
abstract final class CellExtents {
  /// A ledger cell is either a day header or a row, and the two have fixed, verified heights
  /// ([Spacing.dayHeaderHeight] = 34, [Spacing.listRowHeight] = 56).
  ///
  /// The set is built once per cells list, not once per index: a `contains` on a `Set<int>`
  /// is O(1), which is what keeps the extent function constant-time as Flutter asks for
  /// every visible index plus the cached ones.
  static ItemExtentBuilder ofHeaderIndices(Iterable<int> headerIndices) {
    final headers = headerIndices is Set<int> ? headerIndices : headerIndices.toSet();
    return (index, dimensions) =>
        headers.contains(index) ? Spacing.dayHeaderHeight : Spacing.listRowHeight;
  }

  /// The indices of the day headers in a flat ledger cell list.
  static List<int> headerIndicesOf(List<LedgerCellShape> cells) {
    final indices = <int>[];
    for (var i = 0; i < cells.length; i++) {
      if (cells[i].isDayHeader) indices.add(i);
    }
    return indices;
  }
}

/// The one property the extent function needs to know about a cell, as an interface the
/// verified `LedgerCell` already satisfies by being a sealed hierarchy — declared here so
/// this file does not have to import the ledger types (and so the cash book, which has its
/// own cell shape, can use the same extents).
abstract interface class LedgerCellShape {
  bool get isDayHeader;
}
