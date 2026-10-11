/// KhataPro · windowed lists, and the running balance a ledger lives or dies by.
///
/// A shop three years old has ~100 000 journal lines across its ledgers. Two things
/// must be true for that to feel instant on a mid-range phone:
///
///  1. **The widget tree only ever holds what fits on screen.** `ListView.builder` gives
///     that for free *if* the item count is honest and building an item is cheap. So the
///     count comes from a real number (`v_party_balances.line_count`, `COUNT(*)` of a
///     keyed range), and the item is built from data that is already in memory.
///  2. **The data for a row is in memory before the row is built.** [PagedListController]
///     keeps a bounded window of resident items around the viewport, loads ahead of the
///     finger rather than behind it, and hands `null` for anything it does not have yet
///     — which the UI renders as a skeleton row, never as a wrong number or a jump in
///     scroll position.
///
/// ## The running balance, and why the naive version is wrong
///
/// A party ledger shows `balance` next to every line. The obvious implementation —
/// `SUM(amount) OVER (PARTITION BY party ORDER BY date)` — is correct in the database
/// and unusable in the app: with `LIMIT 50 OFFSET 95000`, SQLite still evaluates the
/// window over all 100 000 rows, so each page costs a full scan and scrolling to the
/// bottom of a busy party takes seconds per flick.
///
/// [LedgerPager] instead walks **backwards from a known anchor**: it fetches the newest
/// page first and computes each row's balance by subtracting, so a page costs O(page).
/// The anchor is the party's current balance, which the UI already has from
/// `v_party_balances` because it is displayed in the header.
///
/// The catch is that a backwards walk is only as good as its anchor — if a row is
/// missing, every balance above it is quietly wrong. So the pager *checks itself*: at
/// the end of the walk it must arrive at 0 (a party's ledger nets to zero, because the
/// opening entry is posted into it), and if it does not, [LedgerPager.integrityNote]
/// says so instead of printing plausible numbers. A silently wrong balance is the one
/// bug this app must not have.
library;

import 'dart:async';

// ── generic paging ───────────────────────────────────────────────────────────

/// A slice of a longer list, with the absolute index it starts at.
final class PageSlice<T> {
  const PageSlice({
    required this.items,
    required this.startIndex,
    required this.hasMore,
  });

  final List<T> items;
  final int startIndex;

  /// Whether anything exists beyond this slice. The controller needs this to know when
  /// to stop prefetching — and to draw the end of the list rather than spinning forever.
  final bool hasMore;

  int get endIndex => startIndex + items.length;
}

/// Where a page comes from. The UI layer knows nothing else about the database: this
/// interface is the seam that lets `tool/ui_verify.dart` scroll through 100 000 fake
/// rows without a phone, a database, or a frame.
abstract interface class PageLoader<T> {
  /// Loads up to [limit] items starting at absolute [startIndex].
  Future<PageSlice<T>> load(int startIndex, int limit);
}

class PageLoadFailure implements Exception {
  PageLoadFailure(this.message);

  final String message;

  @override
  String toString() => 'PageLoadFailure: $message';
}

/// A bounded window over a long list.
///
/// One instance per open ledger. It is not a `ChangeNotifier` and has no Flutter import
/// on purpose: the widget layer listens to the Riverpod provider that wraps it, and the
/// windowing arithmetic is testable on its own.
final class PagedListController<T> {
  PagedListController({
    required this.loader,
    this.pageSize = 60,
    this.maxResidentItems = 480,
    this.prefetchPages = 1,
  })  : assert(pageSize > 0),
        assert(maxResidentItems >= pageSize);

  final PageLoader<T> loader;
  final int pageSize;

  /// How many items may be resident at once. Eight pages of 60 by default: enough that
  /// a fast flick never outruns the loader, small enough that the window is a few
  /// hundred objects rather than a 100 000-row list in memory.
  final int maxResidentItems;

  /// Pages kept ahead of (and behind) the viewport.
  final int prefetchPages;

  final _pages = <int, List<T>>{};
  final _inFlight = <int>{};

  /// Pages whose load threw, by page number.
  ///
  /// A map rather than a single "last error" field, because a single field is wrong in a
  /// way that is easy to miss: three pages load at once, one fails, and the *last*
  /// successful response clears the flag — so a gap in the ledger renders as a skeleton
  /// row forever with nothing on screen to explain it. (The harness caught exactly that.)
  final _failed = <int, Object>{};

  int _highestLoadedPage = -1;
  bool _hasMore = true;
  int? _exactTotal;
  int _viewportFirst = 0;
  int _viewportLast = 0;
  int _generation = 0;

  /// How many page loads have been issued, ever. Exposed because "the scroll was smooth"
  /// is a claim that deserves a number behind it, and the harness asserts it stays
  /// proportional to the distance scrolled rather than to the list length.
  int get pageLoads => _pageLoads;
  int _pageLoads = 0;

  int get residentItemCount {
    var total = 0;
    for (final page in _pages.values) {
      total += page.length;
    }
    return total;
  }

  List<int> get residentPages => _pages.keys.toList()..sort();

  bool get isLoading => _inFlight.isNotEmpty;
  bool get hasMore => _hasMore;

  /// The first outstanding failure, or null when every requested page has loaded.
  Object? get lastError => _failed.isEmpty ? null : _failed.values.first;

  bool get hasFailures => _failed.isNotEmpty;

  /// The pages that failed, so a UI can offer "retry" for exactly what is missing.
  List<int> get failedPages => _failed.keys.toList()..sort();

  /// The generation counter bumps on every refresh. A UI that cached a row's identity
  /// can compare generations to know whether a background sync replaced the data under
  /// it without rebuilding the whole list.
  int get generation => _generation;

  /// The item at an absolute index, or `null` if its page is not resident.
  ///
  /// Side effect, deliberately: asking for an item outside the window schedules the load.
  /// `ListView.builder` asks for what is about to be shown, so this is the earliest
  /// honest moment to start fetching — earlier would fetch rows the user never looks at.
  T? itemAt(int index) {
    if (index < 0) return null;
    _viewportFirst = index;
    if (index > _viewportLast) _viewportLast = index;
    final page = index ~/ pageSize;
    final resident = _pages[page];
    if (resident == null) {
      unawaited(_loadPage(page));
      return null;
    }
    final offset = index % pageSize;
    return offset < resident.length ? resident[offset] : null;
  }

  /// Cards the window for a viewport showing `[firstIndex, lastIndex]`, loading the
  /// pages just outside it and evicting the ones it has left behind.
  ///
  /// Call from a `ScrollController` listener (throttled to page boundaries) rather than
  /// from `itemAt`, so a scroll that jumps — a scrollbar drag, a search result — gets
  /// its window right in one pass instead of one page per rebuild.
  void prefetch(int firstIndex, int lastIndex) {
    _viewportFirst = firstIndex < 0 ? 0 : firstIndex;
    _viewportLast = lastIndex < 0 ? 0 : lastIndex;
    final firstPage = _viewportFirst ~/ pageSize;
    final lastPage = _viewportLast ~/ pageSize;
    for (var page = firstPage - prefetchPages; page <= lastPage + prefetchPages; page++) {
      if (page < 0) continue;
      if (_pages.containsKey(page) || _inFlight.contains(page)) continue;
      if (_exactTotal != null && page * pageSize >= _exactTotal!) continue;
      unawaited(_loadPage(page));
    }
    _evict();
  }

  /// Retries every page that failed. The UI shows this as an inline "could not load
  /// these rows — retry" affordance rather than silently leaving holes.
  Future<void> retryFailed() async {
    for (final page in failedPages) {
      await _loadPage(page, force: true);
    }
  }

  /// The total number of items known to exist so far. The UI uses it as the
  /// `ListView.builder` count: `residentPages` may extend past it, but `itemCount` must
  /// not promise rows the loader cannot produce.
  int? estimateItemCount() {
    if (_exactTotal != null) return _exactTotal;
    if (!_hasMore && _pages.containsKey(_highestLoadedPage)) {
      return _highestLoadedPage * pageSize + _pages[_highestLoadedPage]!.length;
    }
    return null;
  }

  /// Forces a reload of the resident window, keeping the anchor index.
  ///
  /// This is what a background sync calls: after a CRDT merge the rows on screen are
  /// stale, but the user's position is not something to throw away. Only pages that are
  /// actually resident are re-fetched, so the cost is proportional to what is visible.
  Future<void> refresh({int anchorIndex = 0}) async {
    final pages = _pages.keys.toList();
    _generation += 1;
    _pages.clear();
    _failed.clear();
    _highestLoadedPage = -1;
    _hasMore = true;
    _exactTotal = null;
    final centre = anchorIndex ~/ pageSize;
    pages.sort((a, b) => (a - centre).abs().compareTo((b - centre).abs()));
    for (final page in pages.take((maxResidentItems ~/ pageSize) + 1)) {
      await _loadPage(page, force: true);
    }
    prefetch(anchorIndex, anchorIndex + pageSize - 1);
  }

  Future<void> _loadPage(int page, {bool force = false}) async {
    if (!force && (_pages.containsKey(page) || _inFlight.contains(page))) return;
    if (!force && _exactTotal != null && page * pageSize >= _exactTotal!) return;
    _inFlight.add(page);
    _pageLoads += 1;
    final generation = _generation;
    try {
      final slice = await loader.load(page * pageSize, pageSize);
      // A response from before a refresh describes a list that no longer exists.
      if (generation != _generation) return;
      _failed.remove(page);
      if (slice.items.isNotEmpty) {
        // An *empty* page past the end is not proof of anything — a loader asked for
        // offset 180 of a 130-item list returns nothing and says `hasMore: false`, and
        // treating that page as the highest would report a 180-item list. The end is
        // recorded from the loader's own answer instead.
        _pages[page] = slice.items;
        if (page > _highestLoadedPage) _highestLoadedPage = page;
      }
      if (!slice.hasMore) {
        _hasMore = false;
        final exact = page * pageSize + slice.items.length;
        if (_exactTotal == null || exact < _exactTotal!) _exactTotal = exact;
      }
    } catch (error) {
      if (generation != _generation) return;
      _failed[page] = error;
    } finally {
      _inFlight.remove(page);
      // Eviction runs here, after each page lands, and not only at the end of
      // [prefetch]: loads are asynchronous, so a prefetch that evicts immediately
      // evicts before the pages it just requested are resident, and the window grows
      // without bound over a long scroll. (Also caught by the harness: 30 000 resident
      // items after 400 flick gestures.)
      _evict();
    }
  }

  /// Drops pages that are far from the viewport, keeping the resident set bounded.
  ///
  /// Eviction takes the *furthest* pages first, not the oldest: a user who flicks back
  /// and forth between two places in a ledger keeps both, and one who scrolls steadily
  /// keeps the leading edge.
  void _evict() {
    if (_pages.length <= 1) return;
    final centrePage = ((_viewportFirst + _viewportLast) ~/ 2) ~/ pageSize;
    var resident = residentItemCount;
    // A page being read right now is never a victim, however far the viewport has moved
    // since it was requested.
    while (resident > maxResidentItems) {
      int? victim;
      var furthest = -1;
      for (final page in _pages.keys) {
        if (_inFlight.contains(page)) continue;
        final distance = (page - centrePage).abs();
        if (distance > furthest) {
          furthest = distance;
          victim = page;
        }
      }
      if (victim == null || furthest <= prefetchPages) break;
      resident -= _pages.remove(victim)!.length;
    }
  }

  /// True when the loader reported the end of the list, or a resident page is short —
  /// the two ways a caller learns the true item count without a `COUNT(*)` over
  /// 100 000 rows on every rebuild.
  bool get reachedEnd => !_hasMore;
}

// ── the ledger ───────────────────────────────────────────────────────────────

/// One posted journal line as a ledger row holds it.
final class LedgerRow {
  const LedgerRow({
    required this.lineId,
    required this.entryId,
    required this.entryNo,
    required this.entryDate,
    required this.amountMinor,
    this.accountName,
    this.memo,
    this.docNo,
  });

  final String lineId;
  final String entryId;
  final String entryNo;
  final int entryDate;

  /// Signed, in the party's orientation: positive = the party owes more (debit),
  /// negative = the business owes (credit). This is exactly `journal_lines.amount_minor`
  /// for a party sub-ledger line.
  final int amountMinor;

  final String? accountName;
  final String? memo;
  final String? docNo;
}

/// A keyset cursor: strictly older than this row. Keyset, not `OFFSET`, because
/// `OFFSET 95000` makes SQLite walk 95 000 rows to discard them, and because a row
/// inserted while the user scrolls would shift every subsequent page by one.
final class LedgerCursor {
  const LedgerCursor({required this.entryDate, required this.lineId});

  final int entryDate;
  final String lineId;

  @override
  String toString() => 'LedgerCursor($entryDate, $lineId)';
}

final class LedgerSlice {
  const LedgerSlice({required this.rows, required this.hasMore});

  final List<LedgerRow> rows;
  final bool hasMore;
}

/// Where ledger rows come from, newest first.
abstract interface class LedgerSource {
  /// Up to [limit] rows strictly older than [before], or the newest rows when it is
  /// null. Must order by `(entry_date DESC, line_id DESC)` — the pager relies on that
  /// order for the walk, and on the tie-break by id so two entries on one day cannot
  /// shuffle between pages.
  Future<LedgerSlice> page({LedgerCursor? before, required int limit});
}

/// A row with its balance, as the list renders it.
final class LedgerPosition {
  const LedgerPosition({
    required this.row,
    required this.balanceBeforeMinor,
    required this.balanceAfterMinor,
  });

  final LedgerRow row;
  final int balanceBeforeMinor;
  final int balanceAfterMinor;

  int get amountMinor => row.amountMinor;
}

/// What a list cell is: either a day header or a row. Materialised by [LedgerLayout] so
/// `ListView.builder` can index into a flat list — headers are part of the item count,
/// which keeps `itemCount` honest (the alternative, injecting headers in `build`, breaks
/// index arithmetic and scrollbar geometry).
sealed class LedgerCell {
  const LedgerCell();
}

final class DayHeaderCell extends LedgerCell {
  const DayHeaderCell({required this.epochDay, required this.dayNetMinor, required this.count});

  final int epochDay;
  final int dayNetMinor;
  final int count;
}

final class LedgerRowCell extends LedgerCell {
  const LedgerRowCell(this.position);

  final LedgerPosition position;
}

abstract final class LedgerLayout {
  /// Flattens positions into cells, inserting one header per day.
  ///
  /// The day's net is the sum of that day's amounts, computed here so the header is a
  /// true subtotal of what is visible rather than a second query.
  static List<LedgerCell> cells(List<LedgerPosition> positions) {
    final cells = <LedgerCell>[];
    int? currentDay;
    var dayNet = 0;
    var dayCount = 0;

    void flush() {
      final day = currentDay;
      if (day != null) {
        cells.insert(
          cells.length - dayCount,
          DayHeaderCell(epochDay: day, dayNetMinor: dayNet, count: dayCount),
        );
      }
    }

    for (final position in positions) {
      if (currentDay != position.row.entryDate) {
        flush();
        currentDay = position.row.entryDate;
        dayNet = 0;
        dayCount = 0;
      }
      dayNet += position.amountMinor;
      dayCount += 1;
      cells.add(LedgerRowCell(position));
    }
    flush();
    return cells;
  }
}

/// Walks a ledger backwards from its current balance.
///
/// See the library comment for why the walk goes backwards, and [integrityNote] for what
/// happens when it does not add up.
final class LedgerPager {
  LedgerPager({
    required this.source,
    required this.closingBalanceMinor,
    this.pageSize = 80,
  });

  final LedgerSource source;

  /// The balance the newest row is *after* — the party's balance right now, which the
  /// screen header shows anyway. Everything else is derived from this one number.
  ///
  /// Mutable, because a background sync changes it while the user is reading: see
  /// [setClosingBalance]. It is *not* settable from outside the class directly, so the
  /// only way to move the anchor is the path that also reloads.
  int closingBalanceMinor;

  final int pageSize;

  /// Moves the anchor and reloads from it.
  ///
  /// Called when the party's balance changes underneath the screen (a sync landed, or an
  /// entry was posted on the other device). Keeping the anchor stale would make every
  /// balance in the list wrong by the delta — the one class of bug this pager exists to
  /// make impossible — so the reload is not optional and [closingBalanceMinor] has no
  /// public setter.
  Future<void> setClosingBalance(int newClosingBalanceMinor) async {
    if (newClosingBalanceMinor == closingBalanceMinor) return;
    closingBalanceMinor = newClosingBalanceMinor;
    await refresh();
  }

  final List<LedgerPosition> _positions = [];
  LedgerCursor? _cursor;
  bool _hasMore = true;
  int _generation = 0;

  List<LedgerPosition> get positions => List.unmodifiable(_positions);
  bool get hasMore => _hasMore;
  bool get isEmpty => _positions.isEmpty;
  int get generation => _generation;

  /// The balance at the very start of what has been loaded — the opening balance of the
  /// range, once the walk is complete.
  int? get openingBalanceMinor =>
      _positions.isEmpty ? null : _positions.last.balanceBeforeMinor;

  /// Loads the next (older) page. Safe to call repeatedly; returns immediately when the
  /// walk is finished.
  Future<void> loadOlder() async {
    if (!_hasMore) return;
    final generation = _generation;
    final slice = await source.page(before: _cursor, limit: pageSize);
    if (generation != _generation) return;

    var balance = _positions.isEmpty
        ? closingBalanceMinor
        : _positions.last.balanceBeforeMinor;

    for (final row in slice.rows) {
      final before = balance - row.amountMinor;
      _positions.add(
        LedgerPosition(row: row, balanceBeforeMinor: before, balanceAfterMinor: balance),
      );
      balance = before;
    }

    final last = slice.rows.isEmpty ? null : slice.rows.last;
    if (last != null) {
      _cursor = LedgerCursor(entryDate: last.entryDate, lineId: last.lineId);
    }
    _hasMore = slice.hasMore;
  }

  /// Reloads from the anchor. Called after a sync merge: the cursor is meaningless once
  /// rows have arrived, and the anchor itself may have changed.
  Future<void> refresh({int? newClosingBalanceMinor}) async {
    closingBalanceMinor = newClosingBalanceMinor ?? closingBalanceMinor;
    _generation += 1;
    _positions.clear();
    _cursor = null;
    _hasMore = true;
    await loadOlder();
  }

  /// Non-null when the walk did not land where the books say it should.
  ///
  /// A party's sub-ledger nets to zero once every row is loaded, because the opening
  /// balance was itself posted as an entry. If the walk ends somewhere else, then either
  /// a page is missing (a bug here, or in the keyset query) or the balance the header is
  /// showing was computed from a different set of rows (a data problem worth surfacing).
  /// Either way the numbers on screen are not trustworthy, and it is better to say so
  /// than to show a plausible total.
  String? get integrityNote {
    if (_hasMore || _positions.isEmpty) return null; // the walk is not finished
    final opening = _positions.last.balanceBeforeMinor;
    if (opening == 0) return null;
    return 'This ledger does not balance to zero: the walk ends at '
        '${_formatMinor(opening)}. The rows on screen may be incomplete — '
        'run a full audit before trusting these opening figures.';
  }

  static String _formatMinor(int minorUnits) {
    final sign = minorUnits < 0 ? '-' : '';
    final magnitude = minorUnits.abs();
    return '$sign${magnitude ~/ 100}.${(magnitude % 100).toString().padLeft(2, '0')}';
  }
}
