/// Analyzer stub for the painting half of `package:flutter/material.dart`.
///
/// Signatures only, transcribed from the Flutter 3.47 SDK for the members this project
/// uses. Nothing here is ever executed — it exists so `dart analyze` can type-check the
/// widget layer in a workspace with no Flutter SDK. See tool/plugin_stubs/README.md.
///
/// The `dart:ui` types (`Color`, `Offset`, `Canvas`, …) are declared here rather than
/// imported, because without the Flutter SDK the analyzer cannot resolve `dart:ui` at
/// all. That is also a rule for the widget layer: **no file under `lib/` may import
/// `dart:ui` directly** — everything comes through `package:flutter/material.dart`,
/// which is what this file stands in for.
library;

// ── dart:ui stand-ins ────────────────────────────────────────────────────────

class Color {
  const Color(this.value);
  const Color.fromARGB(int alpha, int red, int green, int blue) : value = 0;
  final int value;
  Color withOpacity(double opacity) => this;
  static Color? lerp(Color? x, Color? y, double t) => x;
  Color withValues({double? alpha, double? red, double? green, double? blue}) => this;
  static const Color transparent = Color(0x00000000);
}

class Offset {
  const Offset(this.dx, this.dy);
  final double dx;
  final double dy;
  static const Offset zero = Offset(0, 0);
  Offset operator +(Offset other) => this;
  Offset operator -(Offset other) => this;
  Offset operator *(double factor) => this;
  double get distance => 0;
}

class Size {
  const Size(this.width, this.height);
  final double width;
  final double height;
  static const Size zero = Size(0, 0);
  static const Size infinite = Size(double.infinity, double.infinity);
  Size operator -(Size other) => this;
  bool get isEmpty => width <= 0 || height <= 0;
}

class Rect {
  const Rect.fromLTWH(double left, double top, double width, double height)
      : left = left,
        top = top,
        right = left + width,
        bottom = top + height;
  const Rect.fromLTRB(this.left, this.top, this.right, this.bottom);
  final double left;
  final double top;
  final double right;
  final double bottom;
  double get width => right - left;
  double get height => bottom - top;
  Offset get topLeft => Offset(left, top);
  Offset get bottomRight => Offset(right, bottom);
  Offset get center => Offset((left + right) / 2, (top + bottom) / 2);
  static Rect fromPoints(Offset a, Offset b) =>
      Rect.fromLTRB(a.dx, a.dy, b.dx, b.dy);
  Rect inflate(double delta) => this;
}

class Radius {
  const Radius.circular(double radius) : x = radius, y = radius;
  const Radius.elliptical(this.x, this.y);
  final double x;
  final double y;
  static const Radius zero = Radius.circular(0);
}

class RRect {
  static RRect fromRectAndRadius(Rect rect, Radius radius) =>
      const RRect._();
  static RRect fromLTRBAndCorners(
    double left,
    double top,
    double right,
    double bottom, {
    Radius topLeft = Radius.zero,
    Radius topRight = Radius.zero,
    Radius bottomRight = Radius.zero,
    Radius bottomLeft = Radius.zero,
  }) =>
      const RRect._();
  const RRect._();
}

class BorderRadius {
  const BorderRadius.all(Radius radius);
  BorderRadius.circular(double radius) : this.all(Radius.circular(radius));
  const BorderRadius.vertical({Radius top = Radius.zero, Radius bottom = Radius.zero});
  const BorderRadius.horizontal({Radius left = Radius.zero, Radius right = Radius.zero});
  static const BorderRadius zero = BorderRadius.all(Radius.zero);
}

class EdgeInsets extends EdgeInsetsGeometry {
  const EdgeInsets.all(double value) : _value = value;
  const EdgeInsets.symmetric({double horizontal = 0, double vertical = 0})
      : _value = horizontal + vertical;
  const EdgeInsets.only({
    double left = 0,
    double top = 0,
    double right = 0,
    double bottom = 0,
  }) : _value = left + top + right + bottom;
  const EdgeInsets.fromLTRB(double left, double top, double right, double bottom)
      : _value = left + top + right + bottom;
  static const EdgeInsets zero = EdgeInsets.all(0);
  final double _value;

  /// Horizontal inset. Exposed so the field is read: the widget layer mirrors padding
  /// under RTL, and a stub with a dead field is a lint, not a signal.
  double get horizontal => _value;
}

abstract class EdgeInsetsGeometry {
  const EdgeInsetsGeometry();
}

/// Direction-aware insets: `start`/`end` mirror under RTL, `left`/`right` do not. The
/// widget layer uses these for anything that has to look right in Urdu, which is
/// everything with padding.
class EdgeInsetsDirectional extends EdgeInsetsGeometry {
  const EdgeInsetsDirectional.only({
    this.start = 0,
    this.top = 0,
    this.end = 0,
    this.bottom = 0,
  });
  const EdgeInsetsDirectional.all(double value)
      : start = value,
        top = value,
        end = value,
        bottom = value;
  static const EdgeInsetsDirectional zero = EdgeInsetsDirectional.all(0);
  final double start;
  final double top;
  final double end;
  final double bottom;
}

class Alignment extends AlignmentGeometry {
  const Alignment(this.x, this.y);
  final double x;
  final double y;
  static const Alignment topLeft = Alignment(-1, -1);
  static const Alignment topCenter = Alignment(0, -1);
  static const Alignment topRight = Alignment(1, -1);
  static const Alignment centerLeft = Alignment(-1, 0);
  static const Alignment center = Alignment(0, 0);
  static const Alignment centerRight = Alignment(1, 0);
  static const Alignment bottomLeft = Alignment(-1, 1);
  static const Alignment bottomCenter = Alignment(0, 1);
  static const Alignment bottomRight = Alignment(1, 1);
}

enum TextDirection { ltr, rtl }

/// Like [Alignment], but `start`/`end` are resolved by the ambient [TextDirection].
class AlignmentDirectional extends AlignmentGeometry {
  const AlignmentDirectional(this.start, this.y);
  final double start;
  final double y;
  static const AlignmentDirectional center = AlignmentDirectional(0, 0);
  static const AlignmentDirectional centerStart = AlignmentDirectional(-1, 0);
  static const AlignmentDirectional centerEnd = AlignmentDirectional(1, 0);
  static const AlignmentDirectional topStart = AlignmentDirectional(-1, -1);
  static const AlignmentDirectional bottomEnd = AlignmentDirectional(1, 1);
}

enum TextAlign { left, right, center, start, end, justify }

enum TextOverflow { clip, fade, ellipsis, visible }

enum FontStyle { normal, italic }

class FontWeight {
  const FontWeight._(this.index);
  final int index;
  static const FontWeight w300 = FontWeight._(300);
  static const FontWeight w400 = FontWeight._(400);
  static const FontWeight w500 = FontWeight._(500);
  static const FontWeight w600 = FontWeight._(600);
  static const FontWeight w700 = FontWeight._(700);
}

class FontFeature {
  const FontFeature(this.feature);
  final String feature;
  /// Keeps digits the same width, so a column of amounts does not jitter as it scrolls.
  static const FontFeature tabularFigures = FontFeature('tnum');
}

class TextDecoration {
  const TextDecoration._();
  static const TextDecoration none = TextDecoration._();
  static const TextDecoration lineThrough = TextDecoration._();
  static const TextDecoration underline = TextDecoration._();
}

class TextScaler {
  const TextScaler.linear(this.factor);
  final double factor;
  double scale(double fontSize) => fontSize * factor;
  static const TextScaler noScaling = TextScaler.linear(1);
}

class TextStyle {
  const TextStyle({
    this.color,
    this.fontSize,
    this.fontWeight,
    this.fontStyle,
    this.height,
    this.fontFamily,
    this.fontFamilyFallback,
    this.letterSpacing,
    this.wordSpacing,
    this.decoration,
    this.fontFeatures,
    this.overflow,
    this.maxLines,
  });
  final Color? color;
  final double? fontSize;
  final FontWeight? fontWeight;
  final FontStyle? fontStyle;
  final double? height;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;
  final double? letterSpacing;
  final double? wordSpacing;
  final TextDecoration? decoration;
  final List<FontFeature>? fontFeatures;
  final TextOverflow? overflow;
  final int? maxLines;
  TextStyle copyWith({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? height,
    String? fontFamily,
    List<String>? fontFamilyFallback,
    double? letterSpacing,
    TextDecoration? decoration,
    List<FontFeature>? fontFeatures,
    TextOverflow? overflow,
    int? maxLines,
  }) =>
      this;
  TextStyle apply({String? fontFamily, List<String>? fontFamilyFallback}) => this;
  TextStyle merge(TextStyle? other) => this;
  static const TextStyle empty = TextStyle();
}

class TextSpan extends InlineSpan {
  const TextSpan({this.text, this.children, this.style});
  final String? text;
  final List<InlineSpan>? children;
  final TextStyle? style;
}

class InlineSpan {
  const InlineSpan();
}

class PlaceholderSpan extends InlineSpan {
  const PlaceholderSpan();
}

class TextPainter {
  TextPainter({
    required InlineSpan text,
    required TextDirection textDirection,
    int? maxLines,
    TextAlign? textAlign,
    TextScaler? textScaler,
    bool? ellipsis,
  });
  double get width => 0;
  double get height => 0;
  double get maxIntrinsicWidth => 0;
  void layout({double minWidth = 0, double maxWidth = double.infinity}) {}
  void paint(Canvas canvas, Offset offset) {}
}

enum PaintingStyle { fill, stroke }

enum StrokeCap { butt, round, square }

enum StrokeJoin { miter, round, bevel }

enum BlurStyle { normal, solid, inner, outer }

enum BlendMode { srcOver, dstOver, src, difference, multiply }

class Shader {
  const Shader();
}

class MaskFilter {
  const MaskFilter.blur(BlurStyle style, double sigma);
}

class LinearGradient extends Shader {
  const LinearGradient({
    required List<Color> colors,
    List<double>? stops,
    AlignmentGeometry? begin,
    AlignmentGeometry? end,
  });
}

class AlignmentGeometry {
  const AlignmentGeometry();
}

class Paint {
  Paint();
  Color color = const Color(0xFF000000);
  PaintingStyle style = PaintingStyle.fill;
  double strokeWidth = 0;
  StrokeCap strokeCap = StrokeCap.butt;
  StrokeJoin strokeJoin = StrokeJoin.miter;
  bool isAntiAlias = true;
  Shader? shader;
  MaskFilter? maskFilter;
  BlendMode blendMode = BlendMode.srcOver;
}

class Canvas {
  void drawRect(Rect rect, Paint paint) {}
  void drawRRect(RRect rrect, Paint paint) {}
  void drawCircle(Offset center, double radius, Paint paint) {}
  void drawLine(Offset p1, Offset p2, Paint paint) {}
  void drawPath(Path path, Paint paint) {}
  void drawPoints(PointMode pointMode, List<Offset> points, Paint paint) {}
  void save() {}
  void restore() {}
  void clipRect(Rect rect, {bool doAntiAlias = true}) {}
  void translate(double dx, double dy) {}
  void scale(double sx, double sy) {}
  void drawShadow(Path path, Color color, double elevation, bool transparentOccluder) {}
}

enum PointMode { points, lines, polygon }

class Path {
  Path();
  void moveTo(double x, double y) {}
  void lineTo(double x, double y) {}
  void quadraticBezierTo(double x1, double y1, double x2, double y2) {}
  void close() {}
  void addRect(Rect rect) {}
  void addRRect(RRect rrect) {}
  void reset() {}
}

// ── CustomPaint ──────────────────────────────────────────────────────────────

abstract class Listenable {
  const Listenable();
  void addListener(void Function() listener);
  void removeListener(void Function() listener);
}

abstract class CustomPainter extends Listenable {
  const CustomPainter({Listenable? repaint});
  void paint(Canvas canvas, Size size);
  bool shouldRepaint(covariant CustomPainter oldDelegate);
  bool? hitTest(Offset position) => null;
  SemanticsBuilderCallback? get semanticsBuilder => null;
  @override
  void addListener(void Function() listener) {}
  @override
  void removeListener(void Function() listener) {}
}

typedef SemanticsBuilderCallback = List<Object> Function(Size size);
