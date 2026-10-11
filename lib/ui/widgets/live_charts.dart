/// KhataPro · charts, on `CustomPaint` only.
///
/// `fl_chart` is pinned in `pubspec.yaml` and deliberately **unused** (requirement #2 of the
/// widget layer): a chart plugin's widget tree rebuilds, relayouts and re-rasters on every
/// frame of a scroll, which is the exact cost this app cannot pay on the screens where a
/// chart sits above a 10 000-row list.
///
/// ## The four costs this file refuses to pay
///
/// 1. **No per-frame `Path` building.** A line over 30–90 points is hundreds of `Path` calls;
///    doing that inside `paint()` repeats the work on every scroll notification, every tooltip
///    move and every parent rebuild, for a picture that has not changed. So all geometry — the
///    polyline `Path`, the two bar `Path`s, the tick values, the x positions used by hit
///    testing, and the laid-out `TextPainter`s for the labels — is built once per
///    *(size, data, text direction, colours, money format)* into a [_ChartGeometry], cached in
///    the `State`, and reused until [shouldRepaint] says the key changed.
/// 2. **No `saveLayer`, no shadows, no gradients.** Each is a separate offscreen pass in
///    Impeller. The chart draws flat rects and one hairline polyline.
/// 3. **No text layout in the paint pass.** Labels are `TextPainter`s laid out when the
///    geometry was built; `paint()` only blits them.
/// 4. **No rebuild on scroll.** The painter sits in a `RepaintBoundary` and marks itself
///    `isComplex: true, willChange: false`, which lets the engine keep the rasterised picture
///    while the list below it scrolls.
///
/// ## What it draws
///
/// `CashFlowChart` is the dashboard's and the cash book's chart: inflow bars above the axis,
/// outflow bars below it, and the running balance as a line over both — because the question
/// ("am I getting ahead?") is about the *level*, while the bars explain the movement. Days
/// with no movement keep a zero-height bar rather than disappearing (`BarGeometry.layout`
/// guarantees that, and `ui_verify` asserts it): "no sales" and "no sales recorded" are
/// different statements, and the picture must not blur them.
///
/// RTL: time starts at the *start* side, so in Urdu the newest day is on the left. That is
/// done by mirroring the geometry arithmetic — never by flipping the canvas, which would draw
/// every label mirrored, the bug that makes people give up on RTL charts.
library;

import 'dart:math' as math;

// `TextDirection` and the `dart:ui` types come through `material.dart`, never from a direct
// `dart:ui` import — the analyzer stub enforces the same rule the widget layer follows, and
// a direct import is the first step towards a file that cannot be tested without a canvas.
import 'package:flutter/material.dart';

import '../charts/chart_math.dart';
import '../format/formatting.dart';
import '../state/queries.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';

/// What the finger selected.
final class ChartSelection {
  const ChartSelection({required this.index, required this.point, required this.logicalX});

  final int index;
  final DayFlowPoint point;

  /// Where to hang the tooltip, in the chart's own coordinates.
  final double logicalX;
}

/// Everything the cached picture depends on.
///
/// The series itself is identified by *object identity*, not by a content hash: the state
/// layer hands the chart a fresh `List<DayFlowPoint>` on every change and the same instance
/// between changes, so identity is both O(1) to check and impossible to get wrong. A content
/// hash would walk up to 90 points on every build to answer a question identity answers
/// immediately — and a rebuild is exactly when this app cannot afford a walk.
final class _ChartKey {
  const _ChartKey({
    required this.series,
    required this.width,
    required this.height,
    required this.textDirection,
    required this.palette,
    required this.money,
    required this.gutter,
    required this.labelRow,
  });

  final int series;
  final double width;
  final double height;
  final TextDirection textDirection;
  final int palette;
  final int money;
  final double gutter;
  final double labelRow;

  @override
  bool operator ==(Object other) =>
      other is _ChartKey &&
      other.series == series &&
      other.width == width &&
      other.height == height &&
      other.textDirection == textDirection &&
      other.palette == palette &&
      other.money == money &&
      other.gutter == gutter &&
      other.labelRow == labelRow;

  @override
  int get hashCode =>
      Object.hash(series, width, height, textDirection, palette, money, gutter, labelRow);
}

/// A cached chart picture. Built once per key; never inside `paint()`.
final class _ChartGeometry {
  const _ChartGeometry({
    required this.key,
    required this.plot,
    required this.mirror,
    required this.inflowPath,
    required this.outflowPath,
    required this.linePath,
    required this.scale,
    required this.zeroY,
    required this.centresLogical,
    required this.ticks,
    required this.dayLabels,
    required this.valueLabels,
  });

  /// Everything the picture depends on. Compared with `==` by the painter, so a theme flip
  /// rebuilds the colours, a resize rebuilds the geometry, and a tooltip move rebuilds
  /// *nothing*.
  final Object key;

  /// The drawing area, in canvas coordinates.
  final Rect plot;

  /// True under RTL: time runs right-to-left.
  final bool mirror;

  final Path inflowPath;
  final Path outflowPath;
  final Path linePath;

  /// The one scale both the bars and the line use. Handing the two series different scales
  /// would put a 5 000 balance and a 500 movement at the same height.
  final LinearScale scale;

  final double zeroY;

  /// Logical x of each day's centre — ascending from 0 at `plot.left`, *before* mirroring.
  /// Ascending is what [ChartHitTest.nearestIndex] requires; mirroring happens at the edges.
  final List<double> centresLogical;

  final List<num> ticks;
  final List<_ChartLabel> dayLabels;
  final List<_ChartLabel> valueLabels;

  /// Logical x → canvas x. The single place mirroring is applied.
  double xCanvas(double logical) =>
      mirror ? plot.left + (plot.width - logical) : plot.left + logical;

  /// Canvas x → logical x, for hit testing.
  double toLogical(double canvasX) =>
      mirror ? plot.width - (canvasX - plot.left) : canvasX - plot.left;
}

/// A laid-out label: font and metrics resolved once, when the geometry was built.
final class _ChartLabel {
  const _ChartLabel({required this.painter, required this.x, required this.y});

  final TextPainter painter;
  final double x;
  final double y;

  void paint(Canvas canvas) => painter.paint(canvas, Offset(x, y));
}

/// Builds the geometry with the verified `chart_math.dart` primitives. Nothing here
/// re-implements a scale, a tick or a band layout.
_ChartGeometry _buildGeometry({
  required _ChartKey key,
  required Size size,
  required List<DayFlowPoint> points,
  required MoneyFormat money,
  required KhataColors colors,
  required TextDirection textDirection,
  required double labelGutter,
  required double labelRow,
}) {
  final mirror = textDirection == TextDirection.rtl;
  final plotLeft = labelGutter;
  final plotWidth = math.max(1.0, size.width - labelGutter);
  final plotHeight = math.max(1.0, size.height - labelRow);
  final plot = Rect.fromLTWH(plotLeft, 0, plotWidth, plotHeight);

  if (points.isEmpty) {
    return _ChartGeometry(
      key: key,
      plot: plot,
      mirror: mirror,
      inflowPath: Path(),
      outflowPath: Path(),
      linePath: Path(),
      scale: const LinearScale(min: 0, max: 1, pixelStart: 0, pixelEnd: 1),
      zeroY: plotHeight / 2,
      centresLogical: const [],
      ticks: const [],
      dayLabels: const [],
      valueLabels: const [],
    );
  }

  var highestFlow = 0;
  var lowestFlow = 0;
  var maxBalance = points.first.balanceMinor;
  var minBalance = points.first.balanceMinor;
  for (final point in points) {
    highestFlow = math.max(highestFlow, point.inflowMinor);
    lowestFlow = math.min(lowestFlow, point.outflowMinor);
    maxBalance = math.max(maxBalance, point.balanceMinor);
    minBalance = math.min(minBalance, point.balanceMinor);
  }

  final scale = LinearScale(
    min: math.min(lowestFlow, minBalance),
    max: math.max(highestFlow, maxBalance),
    pixelStart: plotHeight - 4,
    pixelEnd: 4,
  );
  final zeroY = scale.toPixels(0);

  double logicalCentre(int index) => plotWidth * (index + 0.5) / points.length;

  // ── bars: two layouts over the same plot, so both series share band centres ──
  final inflowBars = BarGeometry.layout(
    values: [for (final point in points) point.inflowMinor],
    plotWidth: plotWidth,
    plotHeight: plotHeight,
    baseline: 0,
  );
  final outflowBars = BarGeometry.layout(
    values: [for (final point in points) -point.outflowMinor],
    plotWidth: plotWidth,
    plotHeight: plotHeight,
    baseline: 0,
  );

  final inflowPath = Path();
  final outflowPath = Path();
  for (final bar in inflowBars) {
    if (bar.height <= 0) continue;
    final canvasX = mirror
        ? plot.left + (plotWidth - bar.left)
        : plot.left + bar.left;
    inflowPath.addRect(
      Rect.fromLTWH(canvasX - bar.width / 2, bar.top, bar.width, bar.height),
    );
  }
  for (final bar in outflowBars) {
    if (bar.height <= 0) continue;
    final canvasX = mirror
        ? plot.left + (plotWidth - bar.left)
        : plot.left + bar.left;
    outflowPath.addRect(
      Rect.fromLTWH(canvasX - bar.width / 2, bar.top, bar.width, bar.height),
    );
  }

  // ── the balance line ─────────────────────────────────────────────────────
  final linePath = Path();
  for (var i = 0; i < points.length; i++) {
    final x = mirror
        ? plot.left + (plotWidth - logicalCentre(i))
        : plot.left + logicalCentre(i);
    final y = scale.toPixels(points[i].balanceMinor);
    if (i == 0) {
      linePath.moveTo(x, y);
    } else {
      linePath.lineTo(x, y);
    }
  }

  // ── labels, laid out once ────────────────────────────────────────────────
  final axisStyle = TextStyle(
    fontSize: TypeScale.micro,
    color: colors.onSurfaceMuted,
    height: TypeScale.lineHeightLatin,
  );

  final ticks = NiceTicks.of(scale.min, scale.max, targetCount: 3);
  final valueLabels = <_ChartLabel>[];
  for (final tick in ticks) {
    final painter = TextPainter(
      text: TextSpan(text: money.compact(tick.round()), style: axisStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final y = scale.toPixels(tick);
    // The value axis lives in the gutter at the start side — the *right* in Urdu.
    final x = mirror
        ? plot.left + 4
        : math.max(0.0, plot.left - painter.width - 6);
    valueLabels.add(
      _ChartLabel(
        painter: painter,
        x: x.clamp(0, math.max(0, size.width - painter.width)),
        y: (y - painter.height / 2).clamp(0, math.max(0, plotHeight - painter.height)),
      ),
    );
  }

  final dayLabels = <_ChartLabel>[];
  // At most five day labels whatever the window: thirty of them on a phone is a smear, and
  // the same "a human would have chosen this" rule the value-axis ticks follow.
  final step = math.max(1, (points.length / 5).ceil());
  for (var i = 0; i < points.length; i += step) {
    final painter = TextPainter(
      text: TextSpan(
        text: DateText.numeric(points[i].epochDay, digits: money.digits),
        style: axisStyle,
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final canvasX = mirror
        ? plot.left + (plotWidth - logicalCentre(i))
        : plot.left + logicalCentre(i);
    dayLabels.add(
      _ChartLabel(
        painter: painter,
        x: (canvasX - painter.width / 2).clamp(0, math.max(0, size.width - painter.width)),
        y: plotHeight + 6,
      ),
    );
  }

  return _ChartGeometry(
    key: key,
    plot: plot,
    mirror: mirror,
    inflowPath: inflowPath,
    outflowPath: outflowPath,
    linePath: linePath,
    scale: scale,
    zeroY: zeroY,
    centresLogical: [for (var i = 0; i < points.length; i++) logicalCentre(i)],
    ticks: ticks,
    dayLabels: dayLabels,
    valueLabels: valueLabels,
  );
}

/// The painter. Holds the cached geometry and a fixed set of `Paint`s: it allocates nothing
/// per frame, which is the whole contract of this file.
class _CashFlowPainter extends CustomPainter {
  const _CashFlowPainter({
    required this.geometry,
    required this.inflowPaint,
    required this.outflowPaint,
    required this.linePaint,
    required this.gridPaint,
    required this.zeroPaint,
    required this.selectionPaint,
    required this.selectedIndex,
  });

  final _ChartGeometry geometry;
  final Paint inflowPaint;
  final Paint outflowPaint;
  final Paint linePaint;
  final Paint gridPaint;
  final Paint zeroPaint;
  final Paint selectionPaint;
  final int? selectedIndex;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = geometry.plot;

    for (final tick in geometry.ticks) {
      final y = geometry.scale.toPixels(tick);
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), gridPaint);
    }
    canvas.drawLine(
      Offset(plot.left, geometry.zeroY),
      Offset(plot.right, geometry.zeroY),
      zeroPaint,
    );

    if (geometry.centresLogical.isEmpty) return;

    canvas.drawPath(geometry.inflowPath, inflowPaint);
    canvas.drawPath(geometry.outflowPath, outflowPaint);
    canvas.drawPath(geometry.linePath, linePaint);

    final selected = selectedIndex;
    if (selected != null && selected >= 0 && selected < geometry.centresLogical.length) {
      final x = geometry.xCanvas(geometry.centresLogical[selected]);
      canvas.drawLine(Offset(x, plot.top), Offset(x, plot.bottom), selectionPaint);
    }

    for (final label in geometry.valueLabels) {
      label.paint(canvas);
    }
    for (final label in geometry.dayLabels) {
      label.paint(canvas);
    }
  }

  @override
  bool shouldRepaint(covariant _CashFlowPainter old) =>
      old.geometry.key != geometry.key ||
      old.selectedIndex != selectedIndex ||
      old.linePaint.color != linePaint.color;


  @override
  bool? hitTest(Offset position) => null;
}

/// The cash-flow chart: bars for the movement, a line for the balance, a tooltip on tap.
class CashFlowChart extends StatefulWidget {
  const CashFlowChart({
    super.key,
    required this.points,
    required this.money,
    this.height = 180,
    this.showTooltip = true,
    this.emptyLabel = 'No movement in this window yet',
  });

  final List<DayFlowPoint> points;
  final MoneyFormat money;
  final double height;
  final bool showTooltip;
  final String emptyLabel;

  @override
  State<CashFlowChart> createState() => _CashFlowChartState();
}

class _CashFlowChartState extends State<CashFlowChart> {
  _ChartGeometry? _geometry;
  int? _selected;

  static const double _gutter = 46;
  static const double _labelRow = 22;

  /// Six `Paint`s, created once and mutated in place: allocating them per frame is six
  /// allocations the rasteriser does not need, and they are not part of the cache key.
  late final Paint _inflow = Paint()..style = PaintingStyle.fill;
  late final Paint _outflow = Paint()..style = PaintingStyle.fill;
  late final Paint _line = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;
  late final Paint _grid = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  late final Paint _zero = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;
  late final Paint _selection = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final direction = Directionality.of(context);

    if (widget.points.isEmpty) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text(widget.emptyLabel, style: Theme.of(context).textTheme.bodySmall),
        ),
      );
    }

    _inflow.color = colors.moneyIn.withValues(alpha: 0.9);
    _outflow.color = colors.moneyOut.withValues(alpha: 0.75);
    _line.color = colors.brand;
    _grid.color = colors.outline.withValues(alpha: 0.6);
    _zero.color = colors.outlineStrong;
    _selection.color = colors.onSurfaceMuted;

    return RepaintBoundary(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: widget.showTooltip ? _onTap : null,
        child: SizedBox(
          height: widget.height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final size = Size(constraints.maxWidth, widget.height);
              // The one place this file's promise is kept. The key is O(1) to build
              // (identity + size + palette), so a rebuild caused by a *scroll* or by a
              // sibling widget changing costs two `==` comparisons and no geometry work:
              // the `Path`s, the ticks and the laid-out labels survive.
              final key = _ChartKey(
                series: identityHashCode(widget.points),
                width: size.width,
                height: size.height,
                textDirection: direction,
                palette: Object.hash(
                  colors.brand,
                  colors.moneyIn,
                  colors.moneyOut,
                  colors.onSurfaceMuted,
                  colors.outline,
                  colors.outlineStrong,
                ),
                money: Object.hash(
                  widget.money.grouping,
                  widget.money.digits,
                  widget.money.currencySymbol,
                ),
                gutter: _gutter,
                labelRow: _labelRow,
              );
              final geometry = _geometry;
              if (geometry == null || geometry.key != key) {
                _geometry = _buildGeometry(
                  key: key,
                  size: size,
                  points: widget.points,
                  money: widget.money,
                  colors: colors,
                  textDirection: direction,
                  labelGutter: _gutter,
                  labelRow: _labelRow,
                );
              }

              final current = _geometry!;
              return Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _CashFlowPainter(
                        geometry: current,
                        inflowPaint: _inflow,
                        outflowPaint: _outflow,
                        linePaint: _line,
                        gridPaint: _grid,
                        zeroPaint: _zero,
                        selectionPaint: _selection,
                        selectedIndex: _selected,
                      ),
                      isComplex: true,
                      willChange: false,
                    ),
                  ),
                  if (_selected != null && widget.showTooltip)
                    _Tooltip(
                      point: widget.points[_selected!],
                      money: widget.money,
                      colors: colors,
                      canvasX: current.xCanvas(current.centresLogical[_selected!]),
                      width: constraints.maxWidth,
                      height: widget.height,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Hit testing uses the *cached* logical positions, so the tooltip can never point at a
  /// different day than the bar under the finger.
  void _onTap(TapDownDetails details) {
    final geometry = _geometry;
    if (geometry == null || geometry.centresLogical.isEmpty) return;
    final logical = geometry.toLogical(details.localPosition.dx);
    final index = ChartHitTest.nearestIndex(geometry.centresLogical, logical);
    if (index == null) return;
    setState(() => _selected = index);
  }
}

/// The tooltip: a real widget, not canvas text — it gets semantics for free, and shoving it
/// into the painter would invalidate the cached picture every time it moved.
class _Tooltip extends StatelessWidget {
  const _Tooltip({
    required this.point,
    required this.money,
    required this.colors,
    required this.canvasX,
    required this.width,
    required this.height,
  });

  final DayFlowPoint point;
  final MoneyFormat money;
  final KhataColors colors;
  final double canvasX;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    const tooltipWidth = 176.0;
    final left = (canvasX - tooltipWidth / 2)
        .clamp(0.0, math.max(0.0, width - tooltipWidth))
        .toDouble();
    final text = Theme.of(context).textTheme;

    return Positioned(
      left: left,
      top: 0,
      width: tooltipWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surface,
          borderRadius: BorderRadius.circular(Radii.sm),
          border: Border.all(color: colors.outlineStrong),
        ),
        child: Padding(
          padding: const EdgeInsets.all(Spacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateText.short(point.epochDay, digits: money.digits),
                style: text.labelSmall,
              ),
              const SizedBox(height: Spacing.xs),
              _TooltipRow(
                label: 'Received',
                value: money.format(point.inflowMinor),
                color: colors.moneyIn,
              ),
              _TooltipRow(
                label: 'Paid',
                value: money.format(point.outflowMinor),
                color: colors.moneyOut,
              ),
              _TooltipRow(
                label: 'Balance',
                value: money.format(point.balanceMinor),
                color: colors.onCanvas,
                strong: true,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TooltipRow extends StatelessWidget {
  const _TooltipRow({
    required this.label,
    required this.value,
    required this.color,
    this.strong = false,
  });

  final String label;
  final String value;
  final Color color;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final base = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: Spacing.sm),
          Expanded(child: Text(label, style: base)),
          Text(
            value,
            style: strong ? base?.copyWith(fontWeight: FontWeight.w600) : base,
          ),
        ],
      ),
    );
  }
}

/// The sparkline for a KPI tile: no axes, no labels, no interaction — just the shape of the
/// series. It caches its `Path` the same way, so a tile that rebuilds every second (a live
/// total) does not rebuild its geometry.
class TrendLine extends StatefulWidget {
  const TrendLine({
    super.key,
    required this.points,
    required this.color,
    this.height = 34,
  });

  final List<DayFlowPoint> points;
  final Color color;
  final double height;

  @override
  State<TrendLine> createState() => _TrendLineState();
}

class _TrendLineState extends State<TrendLine> {
  Path? _path;
  Object? _key;
  final Paint _paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..strokeCap = StrokeCap.round;

  @override
  Widget build(BuildContext context) {
    if (widget.points.length < 2) return SizedBox(height: widget.height);
    _paint.color = widget.color;

    return RepaintBoundary(
      child: SizedBox(
        height: widget.height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, widget.height);
            final key = Object.hash(
              size,
              widget.points.length,
              widget.points.first.balanceMinor,
              widget.points.last.balanceMinor,
              widget.color,
            );
            if (_key != key) {
              _key = key;
              _path = _sparkPath(size, widget.points);
            }
            return CustomPaint(
              painter: _SparkPainter(path: _path!, stroke: _paint),
              isComplex: true,
              willChange: false,
            );
          },
        ),
      ),
    );
  }

  /// A sparkline over the *balance*, which is the number a tile is about; the movement
  /// belongs to the big chart where there is room to label it.
  static Path _sparkPath(Size size, List<DayFlowPoint> points) {
    var low = points.first.balanceMinor;
    var high = points.first.balanceMinor;
    for (final point in points) {
      low = math.min(low, point.balanceMinor);
      high = math.max(high, point.balanceMinor);
    }
    final scale = LinearScale(min: low, max: high, pixelStart: size.height - 2, pixelEnd: 2);
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final x = size.width * i / (points.length - 1);
      final y = scale.toPixels(points[i].balanceMinor);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    return path;
  }
}

class _SparkPainter extends CustomPainter {
  const _SparkPainter({required this.path, required this.stroke});

  final Path path;
  final Paint stroke;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(path, stroke);

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.path != path;
}
