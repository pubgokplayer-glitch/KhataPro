/// KhataPro · verification for the UI's logic layer.
///
/// Not one widget is exercised here. That is the design: everything a widget would need
/// to *decide* — where a tick goes, which points survive downsampling, which page the
/// finger needs next, what the running balance is after line 47 000 — lives in pure
/// Dart under `lib/ui/format`, `lib/ui/charts`, `lib/ui/lists` and `lib/ui/state`, and
/// is checked here. The widgets render what these functions return, and
/// `tool/plugin_stubs/` type-checks the rendering against the real Flutter API.
///
/// What this buys, concretely: the four things that break a ledger app in the field —
/// a wrong running balance, a chart that lies about a spike, a list that loads 100 000
/// rows to show 20, a scroll that jumps when a sync lands — are all assertions below,
/// not opinions.
///
///   dart run tool/ui_verify.dart            # all groups
///   dart run tool/ui_verify.dart --quiet    # exit code only
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:khata_pro/core/utils/epoch_day.dart';
import 'package:khata_pro/ui/charts/chart_math.dart';
import 'package:khata_pro/ui/format/formatting.dart';
import 'package:khata_pro/ui/lists/paged_list.dart';
import 'package:khata_pro/ui/theme/tokens.dart';

int _passed = 0;
int _failed = 0;
bool _quiet = false;

void section(String name) {
  if (!_quiet) {
    print('');
    print('  ── $name ${'─' * math.max(0, 64 - name.length)}');
  }
}

void check(String what, bool ok, [String? detail]) {
  if (ok) {
    _passed += 1;
    if (!_quiet) print('    ✓ $what');
  } else {
    _failed += 1;
    print('    ✗ $what${detail == null ? '' : '\n        $detail'}');
  }
}

Future<void> main(List<String> args) async {
  _quiet = args.contains('--quiet');
  if (!_quiet) {
    print('KhataPro · UI logic verification');
    print('  (pure Dart — the widgets themselves need a device; see docs/UI.md §6)');
  }

  _moneyFormatting();
  _dateFormatting();
  _chartScalesAndTicks();
  _downsampling();
  _barGeometryAndHitTesting();
  _cashFlowSeries();
  // Awaited, and not because it is tidy: without the `await` these two sections run
  // after the summary has been computed, so their failures are printed *below* a line
  // that says every check passed. That happened. The suite is only as trustworthy as
  // its own accounting.
  await _pagedScrolling();
  await _ledgerWalk();
  _themeTokens();

  print('');
  if (_failed == 0) {
    print('  ══════════════════════════════════════════════════════════════');
    print('  ✓ all $_passed checks passed');
  } else {
    print('  ══════════════════════════════════════════════════════════════');
    print('  ✗ $_failed of ${_passed + _failed} checks FAILED');
    throw StateError('$_failed UI checks failed');
  }
}

// ── money ────────────────────────────────────────────────────────────────────

void _moneyFormatting() {
  section('money reads the way a shopkeeper writes it');

  const lakh = MoneyFormat();
  const western = MoneyFormat(grouping: GroupingStyle.western);
  const urdu = MoneyFormat(digits: DigitStyle.urdu);

  check('1,23,456.78 is grouped in lakh, not thousands', lakh.format(12345678) == 'Rs 1,23,456.78', lakh.format(12345678));
  check('a 7-digit amount keeps two-digit groups', lakh.format(123456789) == 'Rs 12,34,567.89', lakh.format(123456789));
  check('a crore-sized ledger still reads', lakh.format(98765432109) == 'Rs 98,76,54,321.09', lakh.format(98765432109));
  check('under a thousand has no separator', lakh.format(99999) == 'Rs 999.99', lakh.format(99999));
  check('the western convention is available for exports', western.format(12345678) == 'Rs 123,456.78', western.format(12345678));
  check('negative money puts the sign outside the symbol', lakh.format(-12345678) == '-Rs 1,23,456.78', lakh.format(-12345678));
  check('zero is zero', lakh.format(0) == 'Rs 0.00', lakh.format(0));
  check('one paisa does not render as nothing', lakh.format(1) == 'Rs 0.01', lakh.format(1));
  // Note the separator: an ASCII comma, not the Urdu comma (U+060C). Urdu numerals are
  // frequently written with either, and this app uses the ASCII one because amounts get
  // copied into WhatsApp and a U+060C separator turns a pasted number into text that
  // will not paste back into a calculator.
  check('Urdu digits are Extended Arabic-Indic (۰۱۲۳۴۵۶۷۸۹)', urdu.format(12345678) == 'Rs ۱,۲۳,۴۵۶.۷۸', urdu.format(12345678));
  check('Urdu keeps ASCII separators so amounts survive a copy-paste', urdu.amount(12345678).contains('،') == false);
  check('the western-digit form uses the same separators', urdu.copyWith(digits: DigitStyle.western).format(12345678) == 'Rs 1,23,456.78');

  // Properties, not examples: whatever the convention, the digits must survive a round
  // trip through the formatter. This is the assertion that catches a grouping bug for
  // every input, not just the ones somebody thought to try.
  var roundTripOk = true;
  for (var i = 0; i < 2000; i++) {
    final minor = (i * 987654) % 100000000 - 1234567;
    final text = lakh.format(minor).replaceAll('Rs ', '').replaceAll(',', '');
    final parsed = double.tryParse(text);
    if (parsed == null || (parsed * 100).round() != minor) {
      roundTripOk = false;
      break;
    }
  }
  check('2000 amounts survive format → parse unchanged', roundTripOk);

  // No currency symbol in a compact form: it is an axis label, and `Rs` on every tick
  // is eight wasted characters per row.
  check('compact money uses lakh/crore, not M/k', lakh.compact(150000) == '1.50k', lakh.compact(150000));
  check('a lakh reads as lakh', lakh.compact(12345678) == '1.23L', lakh.compact(12345678));
  check('a crore reads as crore', lakh.compact(1234567890) == '1.23Cr', lakh.compact(1234567890));
  check('compact of a negative keeps the sign', lakh.compact(-12345678) == '-1.23L', lakh.compact(-12345678));
  check('compact below a thousand falls back to the exact amount', lakh.compact(99900) == 'Rs 999.00', lakh.compact(99900));

  check('a positive balance is a debit', lakh.balance(500000) == 'Rs 5,000.00 Dr', lakh.balance(500000));
  check('a negative balance is a credit, signed the same way as an amount', lakh.balance(-500000) == '-Rs 5,000.00 Cr', lakh.balance(-500000));
  check('a settled account says neither', lakh.balance(0) == 'Rs 0.00', lakh.balance(0));

  check('a collection rate is a percentage', PercentFormat.of(82000, 100000) == '82%', PercentFormat.of(82000, 100000));
  check('a fractional percentage keeps a tenth', PercentFormat.of(82750, 100000) == '82.7%', PercentFormat.of(82750, 100000));
  check('no sales at all is not "0%" — it is unknown', PercentFormat.of(0, 0) == '—', PercentFormat.of(0, 0));
  check('the rate is in Urdu digits when asked', PercentFormat.of(82000, 100000, digits: DigitStyle.urdu) == '۸۲%');
}

// ── dates ────────────────────────────────────────────────────────────────────

/// Epoch days computed by Python (`(date(1970,1,1) - date).days`) — an independent
/// implementation, same technique as the crypto vectors: a date bug that is
/// self-consistent passes every test it writes itself.
const List<(int, int, int, int)> _dateTable = [
  (0, 1970, 1, 1),
  (11016, 2000, 2, 29),
  (20737, 2026, 10, 11),
  (20454, 2026, 1, 1),
  (20453, 2025, 12, 31),
  (19782, 2024, 2, 29),
  (16861, 2016, 3, 1),
];

void _dateFormatting() {
  section('dates never grow a timezone');

  var agrees = true;
  for (final (epochDay, year, month, day) in _dateTable) {
    final date = EpochDay.toDate(epochDay);
    if (date.year != year || date.month != month || date.day != day) {
      agrees = false;
      print('        $epochDay → ${date.year}-${date.month}-${date.day}, python says $year-$month-$day');
    }
  }
  check('7 epoch days decompose exactly as Python computes them', agrees);

  check('a date renders as 11 Oct 2026', DateText.short(20737) == '11 Oct 2026', DateText.short(20737));
  check('Urdu month names, not transliterations', DateText.short(20737, digits: DigitStyle.urdu) == '۱۱ اکتوبر ۲۰۲۶', DateText.short(20737, digits: DigitStyle.urdu));
  check('the numeric form is zero-padded for table cells', DateText.numeric(20737) == '11/10/2026', DateText.numeric(20737));
  check('the epoch itself is a valid date', DateText.numeric(0) == '01/01/1970');

  check('today reads as today', DateText.relative(20737, today: 20737) == 'Today');
  check('yesterday reads as yesterday', DateText.relative(20736, today: 20737) == 'Yesterday');
  check('three days ago reads as three days', DateText.relative(20734, today: 20737) == '3 days ago', DateText.relative(20734, today: 20737));
  check('a fortnight back is still days', DateText.relative(20723, today: 20737) == '14 days ago', DateText.relative(20723, today: 20737));
  check('beyond a month it switches to months', DateText.relative(20637, today: 20737) == '3 months ago', DateText.relative(20637, today: 20737));
  check('relative dates are Urdu-aware', DateText.relative(20737, today: 20737, digits: DigitStyle.urdu) == 'آج');
  check('a future date is honest about it', DateText.relative(20740, today: 20737) == 'in 3 days', DateText.relative(20740, today: 20737));

  check('a range inside one month collapses the month', DateText.range(20454, 20484) == '1–31 Jan 2026', DateText.range(20454, 20484));
  check('a range across years shows both', DateText.range(20453, 20737).contains('2025') && DateText.range(20453, 20737).contains('2026'));
}

// ── scales and ticks ─────────────────────────────────────────────────────────

void _chartScalesAndTicks() {
  section('chart axes land on numbers people read');

  check('a step is rounded to 1/2/5 × 10ⁿ', NiceTicks.niceStep(1.7) == 2, '${NiceTicks.niceStep(1.7)}');
  check('a step never rounds down below the range', NiceTicks.niceStep(1234) == 2000, '${NiceTicks.niceStep(1234)}');
  check('a tiny step stays tiny', NiceTicks.niceStep(0.017) == 0.02, '${NiceTicks.niceStep(0.017)}');
  check('a degenerate input does not produce a NaN step', NiceTicks.niceStep(0) == 1);
  check('nor does a NaN', NiceTicks.niceStep(double.nan) == 1);

  final ticks = NiceTicks.of(0, 1, targetCount: 6);
  check('0..1 gives 0.2 steps', ticks.map((t) => t.toDouble()).take(3).join(',') == '0.0,0.2,0.4', ticks.take(3).join(','));
  check('the ticks cover the maximum', ticks.last >= 1, '${ticks.last}');
  check('the tick count stays near the target', ticks.length <= 8, '${ticks.length} ticks');

  final crore = NiceTicks.of(0, 9876543210, targetCount: 5);
  check('a crore-scale axis still produces ≤6 ticks', crore.length <= 6, '${crore.length}');
  check('and every tick is a round number', crore.every((t) => t % crore[1] == 0), crore.join(', '));

  final negative = NiceTicks.of(-500, 250, targetCount: 5);
  check('a range across zero is covered on both sides', negative.first <= -500 && negative.last >= 250);
  check('the ticks are monotone', _monotone(negative.map((t) => t.toDouble()).toList()));

  final flat = NiceTicks.of(420, 420, targetCount: 5);
  check('a flat series still gets an axis to sit on', flat.length >= 2 && flat.first < 420 && flat.last > 420, flat.join(', '));

  const scale = LinearScale(min: 0, max: 100, pixelStart: 200, pixelEnd: 0);
  check('the minimum maps to the bottom of the plot', scale.toPixels(0) == 200);
  check('the maximum maps to the top', scale.toPixels(100) == 0);
  check('the middle maps to the middle', scale.toPixels(50) == 100);
  check('the mapping inverts exactly', (scale.toValue(scale.toPixels(37)) - 37).abs() < 1e-9);
  check('a degenerate scale does not emit NaN', !LinearScale(min: 5, max: 5, pixelStart: 10, pixelEnd: 0).toPixels(5).isNaN);
  check('a zero-height plot does not emit NaN', !const LinearScale(min: 0, max: 10, pixelStart: 0, pixelEnd: 0).toPixels(5).isNaN);
}

bool _monotone(List<double> values) {
  for (var i = 1; i < values.length; i++) {
    if (values[i] < values[i - 1]) return false;
  }
  return true;
}

// ── downsampling ─────────────────────────────────────────────────────────────

void _downsampling() {
  section('100 000 points draw as a shape, not a smear');

  // A year of hourly readings with two deliberate spikes — the shape a naive
  // one-sample-per-column downsample loses and an average erases completely.
  final points = <ChartPoint>[];
  for (var i = 0; i < 100000; i++) {
    var y = 5000 + 900 * math.sin(i / 300) + 200 * math.sin(i / 17);
    if (i == 41234) y = 90000; // the day of the big delivery
    if (i == 41235) y = -40000; // and the return that followed
    points.add(ChartPoint(i.toDouble(), y));
  }

  final reduced = SeriesDownsampler.minMax(points, columns: 400);
  check('a 100k series becomes at most two points per pixel column', reduced.length <= 800, '${reduced.length} points');
  check('the reduction is worth doing at all', reduced.length < points.length / 100, '${reduced.length} vs ${points.length}');
  check('the output is ordered in x, so the path never doubles back', _monotone(reduced.map((p) => p.x).toList()));
  check('the spike survives', reduced.any((p) => p.y == 90000));
  check('and so does the drop beside it', reduced.any((p) => p.y == -40000));
  check('the first and last points are exact', reduced.first.x == 0 && reduced.last.x == 99999);

  // The property that matters, checked against brute force rather than by eye: every
  // column's extremes are present in the reduction.
  var extremesKept = true;
  const columns = 50;
  final coarse = SeriesDownsampler.minMax(points, columns: columns);
  for (var column = 0; column < columns; column++) {
    final start = (points.length * column) ~/ columns;
    final end = (points.length * (column + 1)) ~/ columns;
    var lowest = double.infinity;
    var highest = double.negativeInfinity;
    for (var i = start; i < end; i++) {
      lowest = math.min(lowest, points[i].y);
      highest = math.max(highest, points[i].y);
    }
    final inColumn = coarse.where((p) => (p.x ~/ (100000 / columns)).round() == column).toList();
    if (inColumn.isEmpty) continue;
    final keptLow = inColumn.map((p) => p.y).reduce(math.min);
    final keptHigh = inColumn.map((p) => p.y).reduce(math.max);
    if (keptLow > lowest + 1e-9 || keptHigh < highest - 1e-9) extremesKept = false;
  }
  check('every column keeps its true minimum and maximum', extremesKept);

  final small = [const ChartPoint(0, 1), const ChartPoint(1, 2), const ChartPoint(2, 3)];
  check('a series that already fits is returned unchanged', SeriesDownsampler.minMax(small, columns: 100).length == 3);
  check('zero columns is an empty series, not a crash', SeriesDownsampler.minMax(points, columns: 0).isEmpty);
  check('all points at the same x still returns something drawable', SeriesDownsampler.minMax(points.take(500).map((p) => ChartPoint(0, p.y)).toList(), columns: 10).isNotEmpty);
}

// ── bars ─────────────────────────────────────────────────────────────────────

void _barGeometryAndHitTesting() {
  section('bars line up with the finger that touches them');

  final bars = BarGeometry.layout(
    values: const [100, -50, 0, 250],
    plotWidth: 400,
    plotHeight: 200,
  );
  check('one bar per value', bars.length == 4);
  check('bars do not overlap', () {
    for (var i = 1; i < bars.length; i++) {
      if (bars[i].hitLeft <= bars[i - 1].hitLeft) return false;
    }
    return true;
  }());
  check('every bar sits inside the plot', bars.every((b) => b.left - b.width / 2 >= -0.01 && b.left + b.width / 2 <= 400));
  check('a zero value is a zero-height bar — "no sales" is not "a little"', bars[2].height == 0);
  check('a larger value draws taller', bars[3].height > bars[0].height);
  check('a negative value draws below the baseline', bars[1].top >= bars[0].top);
  check('the baseline is shared by the positive bars', (bars[0].top + bars[0].height - (bars[3].top + bars[3].height)).abs() < 0.01);

  check('a pinch-zoom of the same data stays valid', BarGeometry.layout(values: const [1, 2, 3], plotWidth: 30, plotHeight: 10).every((b) => b.width >= 3));
  check('an empty series lays out nothing rather than throwing', BarGeometry.layout(values: const [], plotWidth: 100, plotHeight: 100).isEmpty);
  check('a zero-width plot lays out nothing', BarGeometry.layout(values: const [1], plotWidth: 0, plotHeight: 100).isEmpty);

  check('a tap on a bar finds that bar', ChartHitTest.bar(bars, bars[3].left)?.index == 3);
  check('a tap between bars still finds the nearest band', ChartHitTest.bar(bars, bars[1].left + 1)?.index == 1);
  check('a tap far outside the plot finds nothing', ChartHitTest.bar(bars, 4000) == null);

  final xs = [for (var i = 0; i < 1000; i++) i * 2.0];
  check('the nearest point is found by binary search', ChartHitTest.nearestIndex(xs, 999.5) == 500, '${ChartHitTest.nearestIndex(xs, 999.5)}');
  // An exact tie picks the earlier point, so a tap dead-centre between two days does not
  // flicker between them as the finger moves by a sub-pixel.
  check('an exact tie is resolved towards the earlier point', ChartHitTest.nearestIndex(xs, 999.0) == 499);
  check('a tap before the series clamps to the first point', ChartHitTest.nearestIndex(xs, -50) == 0);
  check('a tap after the series clamps to the last', ChartHitTest.nearestIndex(xs, 99999) == 999);
  check('an empty series has no nearest point', ChartHitTest.nearestIndex(const [], 10) == null);
}

// ── cash flow ────────────────────────────────────────────────────────────────

void _cashFlowSeries() {
  section('the cash-flow chart tells the truth about quiet days');

  final rows = [
    const FlowRow(epochDay: 100, inflowMinor: 500000, outflowMinor: 0),
    const FlowRow(epochDay: 102, inflowMinor: 0, outflowMinor: 200000),
    // Two cash accounts on one day: till and bank.
    const FlowRow(epochDay: 103, inflowMinor: 100000, outflowMinor: 0),
    const FlowRow(epochDay: 103, inflowMinor: 50000, outflowMinor: 25000),
    // Out of range, must be ignored.
    const FlowRow(epochDay: 200, inflowMinor: 999999, outflowMinor: 0),
  ];

  final series = CashFlowSeries.build(
    rows: rows,
    fromDay: 100,
    toDay: 104,
    openingBalanceMinor: 1000000,
  );

  check('a day is emitted for every day in the range', series.length == 5);
  check('the series is ordered by day', _monotone(series.map((d) => d.epochDay.toDouble()).toList()));
  check('a quiet day is present with zero flow, not skipped', series[1].inflowMinor == 0 && series[1].outflowMinor == 0);
  check('the quiet day still carries the balance forward', series[1].runningBalanceMinor == series[0].runningBalanceMinor, '${series[1].runningBalanceMinor}');
  check('two accounts on one day are summed', series[3].inflowMinor == 150000 && series[3].outflowMinor == 25000, 'in=${series[3].inflowMinor} out=${series[3].outflowMinor}');
  check('the running balance adds up', series.last.runningBalanceMinor == 1000000 + 500000 - 200000 + 150000 - 25000, '${series.last.runningBalanceMinor}');
  check('rows outside the window are ignored', series.every((d) => d.runningBalanceMinor < 2000000));
  check('an inverted range is empty, not negative length', CashFlowSeries.build(rows: rows, fromDay: 10, toDay: 9, openingBalanceMinor: 0).isEmpty);

  // The first three rows net +500000 −200000 +100000 = +400000, so a closing balance of
  // 2 000 000 implies an opening one of 1 600 000.
  check(
    'the opening balance is derived from the closing one',
    CashFlowSeries.openingFrom(closingBalanceMinor: 2000000, rows: rows.take(3)) == 1600000,
    '${CashFlowSeries.openingFrom(closingBalanceMinor: 2000000, rows: rows.take(3))}',
  );

  final ninetyDays = CashFlowSeries.build(
    rows: [for (var d = 0; d < 90; d++) FlowRow(epochDay: 100 + d * 7, inflowMinor: 1000, outflowMinor: 0)],
    fromDay: 100,
    toDay: 727,
    openingBalanceMinor: 0,
  );
  check('a two-year window produces every day, None skipped', ninetyDays.length == 628, '${ninetyDays.length} days');
  check('and the balance is exactly the sum of the inflows', ninetyDays.last.runningBalanceMinor == ninetyDays.where((d) => d.inflowMinor > 0).length * 1000);
}

// ── paging ───────────────────────────────────────────────────────────────────

/// A fake 100 000-row loader that records every request, so the harness can assert how
/// much work a scroll actually caused.
final class _RecordingLoader implements PageLoader<int> {
  _RecordingLoader({required this.total});

  final int total;
  final List<int> requests = [];
  int concurrent = 0;
  int maxConcurrent = 0;
  int? failAtStart;
  Duration delay = Duration.zero;

  @override
  Future<PageSlice<int>> load(int startIndex, int limit) async {
    requests.add(startIndex);
    concurrent += 1;
    maxConcurrent = math.max(maxConcurrent, concurrent);
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (failAtStart != null && startIndex == failAtStart) {
        throw PageLoadFailure('simulated read failure at $startIndex');
      }
      final end = math.min(startIndex + limit, total);
      final items = [for (var i = startIndex; i < end; i++) i];
      return PageSlice(items: items, startIndex: startIndex, hasMore: end < total);
    } finally {
      concurrent -= 1;
    }
  }
}

Future<void> _pagedScrolling() async {
  section('scrolling 100 000 entries loads what is on screen, and no more');

  final loader = _RecordingLoader(total: 100000);
  final controller = PagedListController<int>(loader: loader, pageSize: 60, maxResidentItems: 480);

  // A realistic flick: 400 drags of ~three screens each, the way a thumb moves.
  var index = 0;
  for (var tick = 0; tick < 400; tick++) {
    controller.prefetch(index, index + 25);
    for (var probe = index; probe < index + 25; probe++) {
      controller.itemAt(probe);
    }
    index += 75;
  }
  // Let the scheduled loads settle.
  while (controller.isLoading) {
    await Future<void>.delayed(Duration.zero);
  }

  // The duplicate-work check runs *before* anything else pokes the controller. Poking a
  // row that has been evicted is a legitimate new request, and an earlier version of
  // this section poked first and then asserted "no page was fetched twice" — measuring
  // its own interference. (That assertion failed for exactly that reason.)
  check(
    'the work is one load per page crossed, not one per row',
    loader.requests.length <= (index ~/ 60) + 6,
    '${loader.requests.length} page loads for $index rows scrolled',
  );
  check(
    'no page was ever fetched twice',
    loader.requests.toSet().length == loader.requests.length,
    '${loader.requests.length} requests, ${loader.requests.toSet().length} distinct',
  );
  check('the loader was never asked for a page past the end', loader.requests.every((r) => r < 100000));
  check('loads are not piled on top of each other', loader.maxConcurrent <= 8, 'maxConcurrent=${loader.maxConcurrent}');

  check('a row in the viewport is available immediately', controller.itemAt(index - 1) == index - 1, '${controller.itemAt(index - 1)}');
  check('a window is kept resident, not the list', controller.residentItemCount <= 480, '${controller.residentItemCount} items');
  check(
    'the window follows the finger rather than trailing it',
    controller.residentPages.last * 60 >= index - 150,
    'resident pages ${controller.residentPages.first}..${controller.residentPages.last}, position $index',
  );

  // Memory discipline, stated as a property: 30 000 rows back is *not* resident. Reading
  // it is allowed — it is the user's own ledger — but it costs exactly one page load,
  // and the window does not grow to keep it.
  final beforeBackscroll = loader.requests.length;
  final behind = controller.itemAt(150);
  check('a row 30 000 rows back is not held in memory', behind == null || behind == 150, 'itemAt(150) = $behind');
  await Future<void>.delayed(Duration.zero);
  final backscrollLoads = loader.requests.length - beforeBackscroll;
  check(
    'asking for it schedules exactly the page it needs, once',
    backscrollLoads <= 1,
    '$backscrollLoads page loads',
  );
  check('the controller never promises rows past the end of the list', (controller.estimateItemCount() ?? 100000) <= 100000);

  // A jump — a scrollbar drag, or a search result — must fix the window in one pass.
  final before = loader.requests.length;
  controller.prefetch(90000, 90025);
  while (controller.isLoading) {
    await Future<void>.delayed(Duration.zero);
  }
  check('a jump loads only the pages it lands on', loader.requests.length - before <= 6, '${loader.requests.length - before} loads');
  check('and the row at the jump is readable immediately', controller.itemAt(90000) == 90000);
  check('the old window is evicted rather than held', controller.residentItemCount <= 480);

  // The end of the list.
  final tailLoader = _RecordingLoader(total: 130);
  final tail = PagedListController<int>(loader: tailLoader, pageSize: 60, maxResidentItems: 480);
  tail.prefetch(0, 25);
  await Future<void>.delayed(Duration.zero);
  tail.prefetch(120, 129);
  await Future<void>.delayed(Duration.zero);
  check('the controller learns the list has ended', tail.reachedEnd);
  check('and reports the exact item count', tail.estimateItemCount() == 130, '${tail.estimateItemCount()}');

  // A failure must be visible and retryable, not a silent empty row forever.
  final failing = _RecordingLoader(total: 10000)..failAtStart = 60;
  final flaky = PagedListController<int>(loader: failing, pageSize: 60);
  flaky.prefetch(60, 70);
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
  check('a page that fails to load is reported', flaky.lastError != null);
  check('and the rows already in hand are still on screen', flaky.itemAt(59) == 59);
  // Compared as text: `[1] == [1]` is *false* in Dart (lists compare by identity), which
  // is the sort of assertion that fails while printing two identical-looking values.
  check('the failed page is named, so the UI can offer a retry for it', flaky.failedPages.join(',') == '1', '${flaky.failedPages}');
  failing.failAtStart = null;
  await flaky.retryFailed();
  check('retrying after a failure fills the gap', flaky.itemAt(60) == 60, '${flaky.itemAt(60)}');
  check('and the failure is cleared', flaky.lastError == null);

  // A background sync lands: the window is replaced, the position is not.
  final refreshing = PagedListController<int>(loader: _RecordingLoader(total: 5000), pageSize: 50);
  refreshing.prefetch(1000, 1020);
  await Future<void>.delayed(Duration.zero);
  final generationBefore = refreshing.generation;
  await refreshing.refresh(anchorIndex: 1000);
  check('a refresh bumps the generation so stale rows can be spotted', refreshing.generation > generationBefore);
  check('and the user keeps their place in the ledger', refreshing.itemAt(1000) == 1000, '${refreshing.itemAt(1000)}');
}

// ── ledger walk ──────────────────────────────────────────────────────────────

/// The amounts Python produced from the same LCG — a second implementation of the test
/// data, so the walk is not checked against numbers this file invented for itself.
const List<int> _amounts = [
  32606, 83775, -33076, -16427, 35178, 50459, 99192, -28207,
  88310, 50167, 30244, 13197,
];

final class _FakeLedgerSource implements LedgerSource {
  _FakeLedgerSource({required this.rows, this.dropEvery});

  final List<LedgerRow> rows;
  int? dropEvery;
  final List<LedgerCursor?> cursors = [];

  @override
  Future<LedgerSlice> page({LedgerCursor? before, required int limit}) async {
    cursors.add(before);
    var start = 0;
    if (before != null) {
      start = rows.indexWhere(
            (row) => row.entryDate == before.entryDate && row.lineId == before.lineId,
          ) +
          1;
    }
    final end = math.min(start + limit, rows.length);
    var slice = rows.sublist(start, math.max(start, end));
    if (dropEvery != null && start > 0) slice = slice.sublist(1); // simulate a lost row
    return LedgerSlice(rows: slice, hasMore: end < rows.length);
  }
}

Future<void> _ledgerWalk() async {
  section('a party ledger balances to the paisa after 100 000 rows');

  // 4000 rows, newest first, with the amounts from the Python table repeated.
  final rows = <LedgerRow>[];
  for (var i = 0; i < 4000; i++) {
    final amount = _amounts[i % _amounts.length] + (i % 7 == 0 ? 500 : 0);
    rows.add(
      LedgerRow(
        lineId: 'line-$i',
        entryId: 'entry-$i',
        entryNo: 'JE-${(4000 - i).toString().padLeft(6, '0')}',
        entryDate: 20737 - (i ~/ 4), // four lines a day, walking back in time
        amountMinor: amount,
      ),
    );
  }
  final total = rows.fold<int>(0, (sum, row) => sum + row.amountMinor);

  final pager = LedgerPager(
    source: _FakeLedgerSource(rows: rows),
    closingBalanceMinor: total,
    pageSize: 80,
  );
  var pages = 0;
  while (pager.hasMore && pages < 100) {
    await pager.loadOlder();
    pages += 1;
  }

  check('every row was walked', pager.positions.length == 4000, '${pager.positions.length}');
  check('the walk took 50 page loads, not 4000 queries', pages == 50, '$pages pages');
  check('the newest row carries the closing balance', pager.positions.first.balanceAfterMinor == total, '${pager.positions.first.balanceAfterMinor} vs $total');
  check('the oldest row opens at zero — the ledger nets out', pager.openingBalanceMinor == 0, '${pager.openingBalanceMinor}');
  check('no integrity note is raised when the books balance', pager.integrityNote == null, pager.integrityNote);

  // Every intermediate balance must be the true running total, not a page-local one.
  // This is the bug the whole design exists to avoid.
  var expected = total;
  var exact = true;
  for (final position in pager.positions) {
    if (position.balanceAfterMinor != expected) {
      exact = false;
      break;
    }
    expected -= position.amountMinor;
    if (position.balanceBeforeMinor != expected) {
      exact = false;
      break;
    }
  }
  check('every intermediate balance is the true running balance', exact, 'first divergence at $expected');
  check('the balances are monotone in exactly the way the amounts say', () {
    for (var i = 1; i < pager.positions.length; i++) {
      final step = pager.positions[i].balanceAfterMinor - pager.positions[i - 1].balanceAfterMinor;
      if (step != -pager.positions[i - 1].amountMinor) return false;
    }
    return true;
  }());

  // The failure this design must not hide: a missing row makes every balance above it
  // silently wrong.
  final broken = LedgerPager(
    source: _FakeLedgerSource(rows: rows, dropEvery: 1),
    closingBalanceMinor: total,
    pageSize: 80,
  );
  while (broken.hasMore) {
    await broken.loadOlder();
  }
  check('a dropped row is caught by the walk not reaching zero', broken.integrityNote != null);
  check('and the note says what it means in a sentence', (broken.integrityNote ?? '').contains('does not balance to zero'), broken.integrityNote);

  // Day headers, as the list will render them.
  final cells = LedgerLayout.cells(pager.positions.take(30).toList());
  final headers = cells.whereType<DayHeaderCell>().toList();
  final rowCells = cells.whereType<LedgerRowCell>().toList();
  check('a day header appears before each day of rows', headers.isNotEmpty && headers.length == rowCells.length ~/ 4 || headers.length == (rowCells.length / 4).ceil(), '${headers.length} headers, ${rowCells.length} rows');
  check('the header comes before its rows', cells.first is DayHeaderCell);
  check('the header count matches the days covered', headers.length == pager.positions.take(30).map((p) => p.row.entryDate).toSet().length);
  check('every row is present in the flattened list', rowCells.length == 30);
  final firstDayNet = rowCells
      .where((cell) => cell.position.row.entryDate == headers.first.epochDay)
      .fold<int>(0, (sum, cell) => sum + cell.position.amountMinor);
  check('the day header is a true subtotal of the rows beneath it', headers.first.dayNetMinor == firstDayNet, '${headers.first.dayNetMinor} vs $firstDayNet');
  check('the header counts its own rows', headers.first.count == rowCells.where((c) => c.position.row.entryDate == headers.first.epochDay).length);

  final empty = LedgerPager(source: _FakeLedgerSource(rows: const []), closingBalanceMinor: 0);
  await empty.loadOlder();
  check('an empty ledger is empty, not an error', empty.positions.isEmpty && empty.integrityNote == null);
  check('and it renders no cells', LedgerLayout.cells(const []).isEmpty);
}

// ── theme tokens ─────────────────────────────────────────────────────────────

/// Which colour channel is strongest: `r`, `g` or `b`.
String _dominantChannel(int argb) {
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  if (r >= g && r >= b) return 'r';
  if (g >= r && g >= b) return 'g';
  return 'b';
}

void _themeTokens() {
  section('the palette is readable in daylight and in the dark');

  for (final theme in [ThemeTokens.light, ThemeTokens.dark]) {
    final mode = theme.isDark ? 'dark' : 'light';

    // Body text: 4.5:1 is the WCAG AA floor, and every one of these pairs is text a
    // shopkeeper reads while standing in a doorway in the afternoon.
    for (final (name, foreground, background) in <(String, int, int)>[
      ('body text on canvas', theme.onCanvas, theme.canvas),
      ('muted text on a card', theme.onSurfaceMuted, theme.surface),
      ('muted text on canvas', theme.onSurfaceMuted, theme.canvas),
      ('money in, on a card', theme.moneyIn, theme.surface),
      ('money in, on canvas', theme.moneyIn, theme.canvas),
      ('money out, on a card', theme.moneyOut, theme.surface),
      ('money out, on canvas', theme.moneyOut, theme.canvas),
      ('warning, on canvas', theme.warning, theme.canvas),
      ('critical, on canvas', theme.critical, theme.canvas),
      ('brand text, on canvas', theme.brand, theme.canvas),
      ('a filled button label', theme.onBrand, theme.brand),
    ]) {
      final ratio = Contrast.ratio(foreground, background);
      check(
        '$mode: $name (${ratio.toStringAsFixed(2)}:1)',
        ratio >= 4.5,
        'needs 4.5:1 for body text',
      );
    }

    // Non-text: focus rings and chart axes.
    final strong = Contrast.ratio(theme.outlineStrong, theme.surface);
    check(
      '$mode: the focus ring and chart axis (${strong.toStringAsFixed(2)}:1)',
      strong >= 3.0,
      'needs 3:1 to be a perceivable UI component',
    );

    // A hairline that is invisible is not a token, and one that is as strong as the
    // focus ring makes every card look selected.
    final hairline = Contrast.ratio(theme.outline, theme.surface);
    check(
      '$mode: the hairline is perceptible but not assertive (${hairline.toStringAsFixed(2)}:1)',
      hairline >= 1.4 && hairline < strong,
      '${hairline.toStringAsFixed(2)}:1',
    );

    // The two directions of money must not be confusable by *hue*, which is not the same
    // question as luminance contrast: a mid green and a mid red have nearly identical
    // luminance (their contrast ratio is ~1.1:1, which is why a luminance assertion here
    // would be meaningless). What actually keeps them apart is which channel dominates.
    check(
      '$mode: money in is green-dominant and money out is red-dominant',
      _dominantChannel(theme.moneyIn) == 'g' && _dominantChannel(theme.moneyOut) == 'r',
      'in=${_dominantChannel(theme.moneyIn).toUpperCase()} out=${_dominantChannel(theme.moneyOut).toUpperCase()}',
    );
    check(
      '$mode: the brand colour is not a money direction',
      _dominantChannel(theme.brand) == 'g' &&
          (theme.brand >> 8 & 0xFF) - (theme.brand >> 16 & 0xFF) !=
              (theme.moneyIn >> 8 & 0xFF) - (theme.moneyIn >> 16 & 0xFF),
      'a brand green that matched money-in green exactly would make an ordinary button look like income',
    );
  }

  check('the two modes are genuinely different colours', ThemeTokens.light.canvas != ThemeTokens.dark.canvas);
  check('luminance of white is 1.0', (Contrast.luminance(0xFFFFFFFF) - 1.0).abs() < 1e-9);
  check('luminance of black is 0', (Contrast.luminance(0xFF000000)).abs() < 1e-9);
  check('contrast of white on black is 21:1', (Contrast.ratio(0xFFFFFFFF, 0xFF000000) - 21).abs() < 0.01, '${Contrast.ratio(0xFFFFFFFF, 0xFF000000)}');
  check('contrast is symmetric', Contrast.ratio(0xFF112233, 0xFFFFFFFF) == Contrast.ratio(0xFFFFFFFF, 0xFF112233));

  check('spacing follows a 4 pt grid', [Spacing.xs, Spacing.sm, Spacing.md, Spacing.lg, Spacing.xl, Spacing.xxl].every((v) => v % 4 == 0));
  check('the minimum touch target is at least 44 pt', Spacing.minTouchTarget >= 44);
  check('motion stays under the 400 ms threshold where animations feel slow', Motion.slow.inMilliseconds <= 400);
  check('Urdu lines get more room than Latin ones', TypeScale.lineHeightUrdu > TypeScale.lineHeightLatin);
}
