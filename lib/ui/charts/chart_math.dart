/// KhataPro · the arithmetic behind the charts.
///
/// There is no chart package in this project, and that is a requirement rather than a
/// preference: a 52 MB ledger with three years of daily movements is not something a
/// general-purpose chart widget will hold at 120 fps, and the ones that try bring a
/// dependency tree, a theme system and a `saveLayer` with them. What a chart actually
/// needs is small — a scale, some ticks, a downsample, and a hit test — and all four
/// are arithmetic, which means all four can be *verified* instead of eyeballed.
///
/// `CustomPainter` subclasses in `lib/ui/widgets/live_charts.dart` are deliberately
/// thin: they call into this file and draw the result. Every decision about where a
/// pixel goes is here, where `tool/ui_verify.dart` can check it.
///
/// The interesting part is [SeriesDownsampler]. A three-year cash-flow series is
/// ~1100 points and needs no help. A stock-movement or audit series over a full
/// lifetime can be 100 000 points, and drawing those one-per-pixel is both pointless
/// (the screen has 400 pixels of plot width) and slow. The min/max bucket downsampler
/// keeps the *shape* — both extremes of every column survive, so a single bad day is
/// never smoothed away — while fixing the cost at two points per pixel.
library;

import 'dart:math' as math;

// ── scales ───────────────────────────────────────────────────────────────────

/// A linear mapping between value space and pixel space.
///
/// One-directional in practice (values → pixels for drawing, pixels → values for the
/// hit test), and it refuses the degenerate case explicitly: a zero-height plot area
/// with a non-zero value range would silently divide by zero and paint `NaN`, which
/// Flutter turns into nothing at all, with no error anywhere.
final class LinearScale {
  const LinearScale({
    required this.min,
    required this.max,
    required this.pixelStart,
    required this.pixelEnd,
  });

  final num min;
  final num max;

  /// Pixels for [min] and [max] respectively. `pixelEnd` may be *below* `pixelStart` —
  /// canvas y grows downward, and a chart's low value is at the bottom of the screen.
  final double pixelStart;
  final double pixelEnd;

  double get span => (max - min).toDouble();
  double get pixelSpan => pixelEnd - pixelStart;
  bool get isDegenerate => span == 0 || pixelSpan == 0;

  double toPixels(num value) {
    if (span == 0) return pixelEnd; // a flat series is a line in the middle
    return pixelStart + ((value - min) / span) * pixelSpan;
  }

  double toValue(double pixel) {
    if (pixelSpan == 0) return min.toDouble();
    return min + ((pixel - pixelStart) / pixelSpan) * span;
  }

  /// A scale grown so it contains [value]. Used when a series' own extremes are not
  /// enough: a bar chart that must include zero, for instance.
  LinearScale withValue(num value) => LinearScale(
        min: math.min(min, value),
        max: math.max(max, value),
        pixelStart: pixelStart,
        pixelEnd: pixelEnd,
      );
}

/// "Nice" axis ticks: 1, 2, 5 × 10ⁿ.
///
/// The alternative — dividing the range into five equal parts — produces labels like
/// `1,247.00`, `2,494.00`, …, which nobody reads. Rounding to a step a human would
/// have chosen is what makes an axis legible, and it costs one loop.
abstract final class NiceTicks {
  /// The tick values covering `[min, max]`, at most [targetCount] of them.
  static List<num> of(num min, num max, {int targetCount = 5}) {
    if (min > max) return of(max, min, targetCount: targetCount);
    if (min == max) {
      // A flat series still needs an axis: put the value in the middle of a small
      // window so the line has somewhere to be.
      final pad = min == 0 ? 1 : (min.abs() * 0.1);
      return of(min - pad, max + pad, targetCount: targetCount);
    }
    final step = niceStep((max - min) / math.max(1, targetCount - 1));
    final start = (min / step).floor() * step;
    final ticks = <num>[];
    // A guard against a pathological step (a denormal range, a NaN input) producing an
    // unbounded loop. Past 64 ticks the axis is unreadable anyway.
    for (var i = 0; i < 64; i++) {
      final value = start + step * i;
      if (value > max + step * 1e-9) break;
      ticks.add(value);
    }
    if (ticks.isEmpty || ticks.last < max) ticks.add(start + step * ticks.length);
    return ticks;
  }

  /// The smallest 1/2/5×10ⁿ step at or above [raw].
  static num niceStep(num raw) {
    if (raw <= 0 || raw.isNaN || raw.isInfinite) return 1;
    final magnitude = math.pow(10, (math.log(raw) / math.ln10).floor()).toDouble();
    final normalised = raw / magnitude;
    final nice = normalised <= 1
        ? 1
        : normalised <= 2
            ? 2
            : normalised <= 5
                ? 5
                : 10;
    return nice * magnitude;
  }
}

// ── series ───────────────────────────────────────────────────────────────────

/// One point of a series, in *value* space. The painter owns the pixel mapping, so a
/// downsampled series stays resolution-independent (and rotation-proof).
final class ChartPoint {
  const ChartPoint(this.x, this.y);

  final double x;
  final double y;

  @override
  String toString() => 'ChartPoint($x, $y)';
}

/// Reduces a series to at most `2 × columns` points by keeping, for each column of the
/// plot, the minimum and the maximum it contains.
///
/// Why both extremes, and why in x order: dropping to one sample per column (or worse,
/// averaging) erases exactly the spikes a shopkeeper looks for — the day of the big
/// delivery, the week the fridge packed in. An average is a lie about a single day.
/// The output stays monotone in x, because a path that doubles back draws a scribble.
abstract final class SeriesDownsampler {
  static List<ChartPoint> minMax(List<ChartPoint> points, {required int columns}) {
    if (columns < 1) return const [];
    if (points.length <= columns * 2) return List.of(points);

    final result = <ChartPoint>[];
    final first = points.first.x;
    final last = points.last.x;
    final width = last - first;
    if (width <= 0) return List.of(points);

    var index = 0;
    for (var column = 0; column < columns; column++) {
      final columnEnd = first + (width * (column + 1)) / columns;

      ChartPoint? low;
      ChartPoint? high;
      while (index < points.length) {
        final point = points[index];
        // The last column owns everything to the end, so floating-point rounding can
        // never drop the final point of the series.
        if (column != columns - 1 && point.x >= columnEnd) break;
        if (low == null || point.y < low.y) low = point;
        if (high == null || point.y > high.y) high = point;
        index += 1;
      }
      // An empty column (a series clustered at one end of the range) contributes
      // nothing rather than a duplicated point, which would bend the line.
      if (low == null || high == null) continue;
      // Same column, both extremes, in x order: the line draws a vertical stroke
      // through the spike, which is the honest depiction of one extreme day.
      if (low.x <= high.x) {
        result
          ..add(low)
          ..add(high);
      } else {
        result
          ..add(high)
          ..add(low);
      }
    }
    // A single trailing point preserves the series' end exactly.
    if (result.isEmpty || result.last.x != points.last.x) result.add(points.last);
    return result;
  }
}

// ── bars ─────────────────────────────────────────────────────────────────────

/// One bar, in pixels: a rectangle and the value it represents, so the painter and the
/// tooltip agree by construction rather than by both re-doing the arithmetic.
final class BarRect {
  const BarRect({
    required this.index,
    required this.left,
    required this.width,
    required this.top,
    required this.height,
    required this.value,
  });

  final int index;
  final double left;
  final double width;

  /// The smaller y (top edge on screen, since canvas y grows downward).
  final double top;
  final double height;
  final num value;

  /// The band a thumb should hit, which is wider than the bar itself: a 3-pixel bar is
  /// not a target.
  double get hitLeft => left - width / 2;
  double get hitWidth => width * 2;

  @override
  String toString() => 'BarRect($index, ${left.toStringAsFixed(1)}+${width.toStringAsFixed(1)} @ ${top.toStringAsFixed(1)} h${height.toStringAsFixed(1)})';
}

abstract final class BarGeometry {
  /// Lays out [values] across a plot of [plotWidth] × [plotHeight], with the baseline
  /// at zero (or at [baseline] when the caller wants a non-zero one).
  ///
  /// Bars are centred in their band and never overlap: the gap is a fraction of the
  /// band, so the layout survives both "three bars across the phone" and "thirty bars
  /// across a tablet" without special cases.
  static List<BarRect> layout({
    required List<num> values,
    required double plotWidth,
    required double plotHeight,
    num baseline = 0,
    double gapRatio = 0.3,
    double minBarWidth = 3,
  }) {
    if (values.isEmpty || plotWidth <= 0 || plotHeight <= 0) return const [];

    var lowest = baseline.toDouble();
    var highest = baseline.toDouble();
    for (final value in values) {
      lowest = math.min(lowest, value.toDouble());
      highest = math.max(highest, value.toDouble());
    }
    final scale = LinearScale(
      min: lowest,
      max: highest,
      pixelStart: plotHeight,
      pixelEnd: 0,
    );

    final band = plotWidth / values.length;
    final gap = band * gapRatio;
    final width = math.max(minBarWidth, band - gap);
    final zeroLine = scale.toPixels(baseline);

    return [
      for (var i = 0; i < values.length; i++)
        () {
          final value = values[i];
          final y = scale.toPixels(value);
          final top = math.min(y, zeroLine);
          final height = (y - zeroLine).abs();
          return BarRect(
            index: i,
            left: band * i + (band - width) / 2 + width / 2,
            width: width,
            top: top,
            // A zero value keeps a 0-height rect rather than a 1-pixel stub: the
            // difference between "no sales" and "a rupee of sales" is the entire
            // reason the shopkeeper is looking at the chart.
            height: height,
            value: value,
          );
        }(),
    ];
  }
}

// ── hit testing ──────────────────────────────────────────────────────────────

/// Turns a finger position into an index. Kept here, not in the painter, because it is
/// the part that has to agree with the layout — and the part that is wrong in a way
/// nobody notices until a tooltip points at the wrong day.
abstract final class ChartHitTest {
  /// The index of the nearest point, for a line chart. [xs] must be sorted; binary
  /// search makes a 100 000-point series as cheap to inspect as a 5-point one.
  static int? nearestIndex(List<double> xs, double x) {
    if (xs.isEmpty) return null;
    var low = 0;
    var high = xs.length - 1;
    if (x <= xs[low]) return low;
    if (x >= xs[high]) return high;
    while (high - low > 1) {
      final mid = (low + high) ~/ 2;
      if (xs[mid] <= x) {
        low = mid;
      } else {
        high = mid;
      }
    }
    return (x - xs[low]) <= (xs[high] - x) ? low : high;
  }

  /// The bar under a finger, honouring each bar's (wider) hit band.
  static BarRect? bar(List<BarRect> bars, double x) {
    if (bars.isEmpty) return null;
    // Bars are uniform in this app, so the index is arithmetic; the scan is the
    // fallback that keeps the function correct if a caller hand-builds the list.
    final first = bars.first;
    final band = bars.length == 1 ? first.hitWidth : (bars[1].left - first.left);
    if (band > 0) {
      final index = ((x - first.left) / band).round();
      if (index >= 0 && index < bars.length && x >= bars[index].hitLeft && x <= bars[index].hitLeft + bars[index].hitWidth) {
        return bars[index];
      }
    }
    for (final bar in bars) {
      if (x >= bar.hitLeft && x <= bar.hitLeft + bar.hitWidth) return bar;
    }
    return null;
  }
}

// ── cash flow ────────────────────────────────────────────────────────────────

/// One day of movement, as the Cash Book and the dashboard chart need it.
final class DayFlow {
  const DayFlow({
    required this.epochDay,
    required this.inflowMinor,
    required this.outflowMinor,
    required this.runningBalanceMinor,
  });

  final int epochDay;
  final int inflowMinor;
  final int outflowMinor;

  /// The balance *at the end of* this day, carried forward across days with no
  /// movement. A chart of daily net amounts and a chart of the balance are different
  /// stories: the first shows the spikes, the second shows whether the business is
  /// getting anywhere. Both come from this type.
  final int runningBalanceMinor;

  int get netMinor => inflowMinor - outflowMinor;

  @override
  String toString() => 'DayFlow($epochDay, in=$inflowMinor, out=$outflowMinor, bal=$runningBalanceMinor)';
}

/// A day's raw movement, straight from `v_daily_cashflow`.
final class FlowRow {
  const FlowRow({
    required this.epochDay,
    required this.inflowMinor,
    required this.outflowMinor,
  });

  final int epochDay;
  final int inflowMinor;
  final int outflowMinor;
}

abstract final class CashFlowSeries {
  /// Builds a dense, gap-free, ordered series over `[fromDay, toDay]`.
  ///
  /// Three properties matter and all three are asserted in `tool/ui_verify.dart`:
  ///
  ///  * **Gaps are filled with zero flow**, because a chart that silently omits empty
  ///    days draws Friday and Monday adjacent and implies continuous trading;
  ///  * **the running balance carries forward** across those days — the business does
  ///    not stop owning its cash because nobody wrote anything down;
  ///  * **input order does not matter**. `v_daily_cashflow` groups by day and the
  ///    planner is not contractually obliged to return those groups in order, so the
  ///    builder sorts and merges rather than trusting the query.
  static List<DayFlow> build({
    required Iterable<FlowRow> rows,
    required int fromDay,
    required int toDay,
    required int openingBalanceMinor,
  }) {
    if (toDay < fromDay) return const [];

    final byDay = <int, List<int>>{};
    for (final row in rows) {
      if (row.epochDay < fromDay || row.epochDay > toDay) continue;
      final existing = byDay[row.epochDay];
      if (existing == null) {
        byDay[row.epochDay] = [row.inflowMinor, row.outflowMinor];
      } else {
        // Two cash accounts on one day (till + bank) arrive as two rows.
        existing[0] += row.inflowMinor;
        existing[1] += row.outflowMinor;
      }
    }

    final series = <DayFlow>[];
    var balance = openingBalanceMinor;
    for (var day = fromDay; day <= toDay; day++) {
      final movement = byDay[day];
      final inflow = movement?[0] ?? 0;
      final outflow = movement?[1] ?? 0;
      balance += inflow - outflow;
      series.add(
        DayFlow(
          epochDay: day,
          inflowMinor: inflow,
          outflowMinor: outflow,
          runningBalanceMinor: balance,
        ),
      );
    }
    return series;
  }

  /// The opening balance implied by a known closing balance and the movement inside a
  /// window: the dashboard knows the balance now, and the chart needs where the window
  /// started.
  static int openingFrom({required int closingBalanceMinor, required Iterable<FlowRow> rows}) {
    var net = 0;
    for (final row in rows) {
      net += row.inflowMinor - row.outflowMinor;
    }
    return closingBalanceMinor - net;
  }
}
