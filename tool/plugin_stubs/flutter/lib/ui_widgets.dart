/// Analyzer stub for `package:flutter/material.dart` (widget half).
///
/// Signatures only, transcribed from the Flutter 3.47 SDK for the members this project
/// uses. Nothing here is ever executed — it exists so `dart analyze` can type-check the
/// widget layer in a workspace with no Flutter SDK. See tool/plugin_stubs/README.md.
library;

import 'painting.dart';

export 'painting.dart';

// ── framework ────────────────────────────────────────────────────────────────

class Key {
  const Key(this.value);
  const Key.value(this.value);
  final Object? value;
}

class ValueKey<T> extends Key {
  const ValueKey(T value) : super(value);
}

class GlobalKey<T extends State> extends Key {
  GlobalKey() : super('global');
}

class Element {
  const Element();
  T? findAncestorStateOfType<T extends State>() => null;
  BuildContext? get context => null;
}

class BuildContext {
  const BuildContext();
  T? dependOnInheritedWidgetOfExactType<T>() => null;
  T? findAncestorStateOfType<T extends State>() => null;
  void visitChildElements(void Function(Element element) visitor) {}
}

class Widget {
  const Widget({this.key});
  final Key? key;
}

class StatelessWidget extends Widget {
  const StatelessWidget({super.key});
  Widget build(BuildContext context) => throw UnimplementedError('stub');
}

class StatefulWidget extends Widget {
  const StatefulWidget({super.key});
  State createState() => throw UnimplementedError('stub');
}

abstract class State<T extends StatefulWidget> {
  T get widget => throw UnimplementedError('stub');
  BuildContext get context => const BuildContext();
  bool get mounted => false;
  Widget build(BuildContext context) => throw UnimplementedError('stub');
  void initState() {}
  void didUpdateWidget(covariant T oldWidget) {}
  void didChangeDependencies() {}
  void dispose() {}
  void setState(VoidCallback fn) {}
}

typedef VoidCallback = void Function();
typedef ValueChanged<T> = void Function(T value);
typedef ValueGetter<T> = T Function();
typedef AsyncCallback = Future<void> Function();
typedef WidgetBuilder = Widget Function(BuildContext context);
typedef IndexedWidgetBuilder = Widget Function(BuildContext context, int index);
typedef NullableIndexedWidgetBuilder = Widget? Function(BuildContext context, int index);
typedef ChildIndexGetter = int? Function(Key key);

class InheritedWidget extends Widget {
  const InheritedWidget({super.key, required this.child});
  final Widget child;
  bool updateShouldNotify(covariant InheritedWidget oldWidget) => false;
}

class InheritedNotifier<T extends Listenable> extends InheritedWidget {
  const InheritedNotifier({super.key, this.notifier, required super.child});
  final T? notifier;
}

class SizedBox extends Widget {
  const SizedBox({super.key, this.width, this.height, this.child});
  final double? width;
  final double? height;
  final Widget? child;
}

class Container extends Widget {
  const Container({
    super.key,
    this.child,
    this.color,
    this.decoration,
    this.padding,
    this.margin,
    this.width,
    this.height,
    this.alignment,
    this.constraints,
  });
  final Widget? child;
  final Color? color;
  final Decoration? decoration;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double? width;
  final double? height;
  final AlignmentGeometry? alignment;
  final BoxConstraints? constraints;
}

class Padding extends Widget {
  const Padding({super.key, required this.padding, this.child});
  final EdgeInsetsGeometry padding;
  final Widget? child;
}

class Center extends Widget {
  const Center({super.key, this.child});
  final Widget? child;
}

class Align extends Widget {
  const Align({super.key, this.alignment = Alignment.center, this.child});
  final AlignmentGeometry alignment;
  final Widget? child;
}

class DecoratedBox extends Widget {
  const DecoratedBox({super.key, required this.decoration, this.position, this.child});
  final Decoration decoration;
  final Object? position;
  final Widget? child;
}

class ConstrainedBox extends Widget {
  const ConstrainedBox({super.key, required this.constraints, this.child});
  final BoxConstraints constraints;
  final Widget? child;
}

class ColoredBox extends Widget {
  const ColoredBox({super.key, required this.color, this.child});
  final Color color;
  final Widget? child;
}

class Row extends Widget {
  const Row({
    super.key,
    this.mainAxisAlignment = MainAxisAlignment.start,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.children = const [],
    this.mainAxisSize = MainAxisSize.max,
    this.textDirection,
  });
  final MainAxisAlignment mainAxisAlignment;
  final CrossAxisAlignment crossAxisAlignment;
  final List<Widget> children;
  final MainAxisSize mainAxisSize;
  final TextDirection? textDirection;
}

class Column extends Widget {
  const Column({
    super.key,
    this.mainAxisAlignment = MainAxisAlignment.start,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.children = const [],
    this.mainAxisSize = MainAxisSize.max,
  });
  final MainAxisAlignment mainAxisAlignment;
  final CrossAxisAlignment crossAxisAlignment;
  final List<Widget> children;
  final MainAxisSize mainAxisSize;
}

enum MainAxisAlignment { start, end, center, spaceBetween, spaceAround, spaceEvenly }

enum CrossAxisAlignment { start, end, center, stretch, baseline }

enum MainAxisSize { min, max }

class Spacer extends Widget {
  const Spacer({super.key, this.flex = 1});
  final int flex;
}

class Expanded extends Widget {
  const Expanded({super.key, this.flex = 1, this.child});
  final int flex;
  final Widget? child;
}

class Flexible extends Widget {
  const Flexible({super.key, this.flex = 1, this.child, this.fit = FlexFit.loose});
  final int flex;
  final Widget? child;
  final FlexFit fit;
}

enum FlexFit { tight, loose }

class Stack extends Widget {
  const Stack({super.key, this.children = const [], this.alignment = Alignment.topLeft});
  final List<Widget> children;
  final AlignmentGeometry alignment;
}

class Positioned extends Widget {
  const Positioned({
    super.key,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.width,
    this.height,
    this.child,
  });
  final double? left;
  final double? top;
  final double? right;
  final double? bottom;
  final double? width;
  final double? height;
  final Widget? child;
}

class LayoutBuilder extends Widget {
  const LayoutBuilder({super.key, required this.builder});
  final Widget Function(BuildContext context, BoxConstraints constraints) builder;
}

typedef AsyncWidgetBuilder<T> = Widget Function(BuildContext context, AsyncSnapshot<T> snapshot);

enum ConnectionState { none, waiting, active, done }

class AsyncSnapshot<T> {
  const AsyncSnapshot._(this.connectionState, this.data, this.error, this.stackTrace);
  final ConnectionState connectionState;
  final T? data;
  final Object? error;
  final StackTrace? stackTrace;
  bool get hasData => data != null;
  bool get hasError => error != null;
}

/// `FutureBuilder`, with the state the app actually reads: `data`, `error`, `hasData`.
class FutureBuilder<T> extends Widget {
  const FutureBuilder({
    super.key,
    this.future,
    required this.builder,
    this.initialData,
  });
  final Future<T>? future;
  final AsyncWidgetBuilder<T> builder;
  final T? initialData;
}

class Builder extends Widget {
  const Builder({super.key, required this.builder});
  final WidgetBuilder builder;
}

// ── geometry & constraints ───────────────────────────────────────────────────

class BoxConstraints {
  const BoxConstraints({
    this.minWidth = 0,
    this.maxWidth = double.infinity,
    this.minHeight = 0,
    this.maxHeight = double.infinity,
  });
  const BoxConstraints.tightFor({double? width, double? height})
      : minWidth = 0,
        maxWidth = double.infinity,
        minHeight = 0,
        maxHeight = double.infinity;
  final double minWidth;
  final double maxWidth;
  final double minHeight;
  final double maxHeight;
  bool get hasBoundedHeight => maxHeight.isFinite;
  bool get hasBoundedWidth => maxWidth.isFinite;
  BoxConstraints loosen() => this;
  BoxConstraints enforce(BoxConstraints other) => this;
}

// ── painting & decoration ────────────────────────────────────────────────────

abstract class Decoration {
  const Decoration();
}

class BoxDecoration extends Decoration {
  const BoxDecoration({
    this.color,
    this.borderRadius,
    this.border,
    this.boxShadow,
    this.gradient,
  });
  final Color? color;
  final BorderRadius? borderRadius;
  final Border? border;
  final List<BoxShadow>? boxShadow;
  final Gradient? gradient;
}

class BoxShadow {
  const BoxShadow({
    Color color = const Color(0xFF000000),
    Offset offset = Offset.zero,
    double blurRadius = 0,
    double spreadRadius = 0,
  });
}

class Gradient {
  const Gradient();
}

class Border {
  const Border({this.top, this.bottom, this.left, this.right})
      : color = const Color(0xFF000000),
        width = 1;
  const Border.all({
    this.color = const Color(0xFF000000),
    this.width = 1,
  })  : top = null,
        bottom = null,
        left = null,
        right = null;
  final BorderSide? top;
  final BorderSide? bottom;
  final BorderSide? left;
  final BorderSide? right;
  final Color color;
  final double width;
}

class BorderSide {
  const BorderSide({this.color = const Color(0xFF000000), this.width = 1});
  final Color color;
  final double width;
}

class BoxPainter {
  const BoxPainter();
}

// ── text ─────────────────────────────────────────────────────────────────────

class Text extends Widget {
  const Text(
    this.data, {
    super.key,
    this.style,
    this.textAlign,
    this.overflow,
    this.maxLines,
    this.textDirection,
    this.semanticsLabel,
    this.softWrap,
  });
  final String data;
  final TextStyle? style;
  final TextAlign? textAlign;
  final TextOverflow? overflow;
  final int? maxLines;
  final TextDirection? textDirection;
  final String? semanticsLabel;
  final bool? softWrap;
}

class RichText extends Widget {
  const RichText({super.key, required this.text, this.textAlign, this.textScaler});
  final Object text;
  final TextAlign? textAlign;
  final TextScaler? textScaler;
}

class DefaultTextStyle extends StatelessWidget {
  const DefaultTextStyle({super.key, required this.style, required this.child});
  final Object? style;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}

class Directionality extends InheritedWidget {
  const Directionality({super.key, required this.textDirection, required super.child});
  final TextDirection textDirection;
}

class Icon extends StatelessWidget {
  const Icon(this.icon, {super.key, this.size, this.color});
  final Object? icon;
  final double? size;
  final Color? color;
  @override
  Widget build(BuildContext context) => throw UnimplementedError('stub');
}

class IconData {
  const IconData(this.codePoint, {this.fontFamily, this.matchTextDirection = false});
  final int codePoint;
  final String? fontFamily;
  final bool matchTextDirection;
}

abstract final class Icons {
  static const IconData add = IconData(0xe000);
  static const IconData close = IconData(0xe001);
  static const IconData arrow_forward = IconData(0xe002);
  static const IconData arrow_back = IconData(0xe003);
  static const IconData search = IconData(0xe004);
  static const IconData fingerprint = IconData(0xe005);
  static const IconData sync = IconData(0xe006);
  static const IconData warning = IconData(0xe007);
  static const IconData error_outline = IconData(0xe008);
}

// ── gesture ──────────────────────────────────────────────────────────────────

class GestureDetector extends StatelessWidget {
  const GestureDetector({
    super.key,
    this.child,
    this.onTap,
    this.onLongPress,
    this.behavior,
  });
  final Widget? child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final HitTestBehavior? behavior;
  @override
  Widget build(BuildContext context) => child ?? const SizedBox();
}

enum HitTestBehavior { deferToChild, opaque, translucent }

class InkWell extends StatelessWidget {
  const InkWell({
    super.key,
    this.child,
    this.onTap,
    this.onLongPress,
    this.borderRadius,
    this.splashColor,
    this.highlightColor,
  });
  final Widget? child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final BorderRadius? borderRadius;
  final Color? splashColor;
  final Color? highlightColor;
  @override
  Widget build(BuildContext context) => child ?? const SizedBox();
}

// ── scrolling ────────────────────────────────────────────────────────────────

class ScrollController extends Listenable {
  ScrollController({
    this.initialScrollOffset = 0,
    this.keepScrollOffset = true,
    this.debugLabel,
  });
  final double initialScrollOffset;
  final bool keepScrollOffset;
  final String? debugLabel;
  void dispose() {}
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  bool get hasClients => false;
  double get offset => 0;
  ScrollPosition? get position => null;
  void jumpTo(double value) {}
  void animateTo(double value, {Duration? duration, Curve? curve}) {}
}

abstract class ScrollPosition extends Listenable {
  bool get hasContentDimensions => false;
  bool get hasPixels => false;
  double get pixels => 0;
  double get maxScrollExtent => 0;
  double get viewportDimension => 0;
  void jumpTo(double value) {}
  void correctPixels(double value) {}
  Future<void> animateTo(double to, {required Duration duration, required Curve curve}) =>
      Future<void>.value();
}

class Curve {
  const Curve();
  static const Curve linear = Curve();
  static const Curve easeInOut = Curve();
  static const Curve easeOutCubic = Curve();
}

class Scrollable extends Widget {
  const Scrollable({super.key, this.controller, this.child, this.axisDirection});
  final ScrollController? controller;
  final Widget? child;
  final AxisDirection? axisDirection;
}

enum Axis { horizontal, vertical }

enum AxisDirection { up, down, left, right }

class Scrollbar extends Widget {
  const Scrollbar({
    super.key,
    this.child,
    this.controller,
    this.thumbVisibility,
    this.thickness,
    this.radius,
  });
  final Widget? child;
  final ScrollController? controller;
  final bool? thumbVisibility;
  final double? thickness;
  final Radius? radius;
}

class Viewport extends Widget {
  const Viewport({super.key, this.controller, this.anchor, this.slivers = const []});
  final ScrollController? controller;
  final double? anchor;
  final List<Widget> slivers;
}

class CustomScrollView extends Widget {
  const CustomScrollView({
    super.key,
    this.controller,
    this.slivers = const [],
    this.cacheExtent,
    this.scrollDirection = Axis.vertical,
    this.physics,
  });
  final ScrollController? controller;
  final List<Widget> slivers;
  final double? cacheExtent;
  final Axis scrollDirection;
  final ScrollPhysics? physics;
}

class ScrollPhysics {
  const ScrollPhysics();
  static const ScrollPhysics alwaysScrollable = ScrollPhysics();
}

abstract class SliverChildDelegate {
  const SliverChildDelegate();
  int? get estimatedChildCount => null;
  int? estimatedChildCountOf(int itemCount) => itemCount;
}

class SliverChildBuilderDelegate extends SliverChildDelegate {
  SliverChildBuilderDelegate(
    this.builder, {
    this.childCount,
    this.addAutomaticKeepAlives = true,
    this.addRepaintBoundaries = true,
    this.findChildIndexCallback,
  });
  final NullableIndexedWidgetBuilder builder;
  final int? childCount;
  final bool addAutomaticKeepAlives;
  final bool addRepaintBoundaries;
  final ChildIndexGetter? findChildIndexCallback;
}

class SliverList extends Widget {
  const SliverList({super.key, required this.delegate});
  final SliverChildDelegate delegate;
}

class SliverFixedExtentList extends Widget {
  const SliverFixedExtentList({super.key, required this.delegate, required this.itemExtent});
  final SliverChildDelegate delegate;
  final double itemExtent;
}

class SliverVariedExtentList extends Widget {
  const SliverVariedExtentList({
    super.key,
    required this.delegate,
    required this.itemExtentBuilder,
  });
  final SliverChildDelegate delegate;
  final ItemExtentBuilder itemExtentBuilder;
}

class SliverLayoutDimensions {
  const SliverLayoutDimensions({
    required this.scrollOffset,
    required this.precedingScrollExtent,
    required this.crossAxisExtent,
    required this.viewportMainAxisExtent,
  });
  final double scrollOffset;
  final double? precedingScrollExtent;
  final double crossAxisExtent;
  final double viewportMainAxisExtent;
}

typedef ItemExtentBuilder = double? Function(int index, SliverLayoutDimensions dimensions);

abstract class ScrollPositionWithSingleContext extends ScrollPosition {
  /// Schedules a scroll notification after layout settles — the hook the ledger uses to
  /// prefetch the next page before the user actually hits the bottom.
  void applyNewDimensions() {}
}

abstract class ScrollMetrics {
  const ScrollMetrics();
  double get pixels;
  double get maxScrollExtent;
  double get viewportDimension;
  double get extentAfter => maxScrollExtent - pixels;
  bool get hasContentDimensions;
}

class ScrollNotification extends Notification {
  const ScrollNotification(this.metrics);
  final ScrollMetrics metrics;
}

class ScrollUpdateNotification extends ScrollNotification {
  const ScrollUpdateNotification(super.metrics);
}

class ScrollEndNotification extends ScrollNotification {
  const ScrollEndNotification(super.metrics);
}

class ScrollMetricsData extends ScrollMetrics {
  const ScrollMetricsData({
    this.pixels = 0,
    this.maxScrollExtent = 0,
    this.viewportDimension = 0,
    this.hasContentDimensions = true,
  });
  @override
  final double pixels;
  @override
  final double maxScrollExtent;
  @override
  final double viewportDimension;
  @override
  final bool hasContentDimensions;
}

/// The `KeyedSubtree` the list uses to attach a stable key to each cell.
class KeyedSubtree extends Widget {
  const KeyedSubtree({super.key, required this.child});
  final Widget child;
}

/// Frame callbacks, used exactly once in the widget layer: to check for a prefetch that no
/// scroll notification would announce (content shorter than the viewport).
class WidgetsBinding {
  const WidgetsBinding();
  static WidgetsBinding get instance => const WidgetsBinding();
  void addPostFrameCallback(void Function(Duration timeStamp) callback) {}
  void scheduleFrame() {}
}

class WidgetsFlutterBinding extends WidgetsBinding {
  const WidgetsFlutterBinding();
  static WidgetsBinding ensureInitialized() => const WidgetsFlutterBinding();
}

class NotificationListener<T extends Notification> extends Widget {
  const NotificationListener({super.key, this.onNotification, required this.child});
  final bool Function(T notification)? onNotification;
  final Widget child;
}

class Notification {
  const Notification();
  bool visitAncestor(Element element) => false;
}

class ListView extends Widget {
  const ListView({
    super.key,
    this.controller,
    this.itemExtent,
    this.itemExtentBuilder,
    this.prototypeItem,
    this.itemBuilder,
    this.findChildIndexCallback,
    this.itemCount,
    this.addAutomaticKeepAlives = true,
    this.addRepaintBoundaries = true,
    this.addSemanticIndexes = true,
    this.cacheExtent,
    this.physics,
    this.children = const [],
    this.padding,
    this.scrollDirection = Axis.vertical,
    this.shrinkWrap = false,
    this.reverse = false,
  });
  const ListView.builder({
    super.key,
    this.controller,
    this.itemExtent,
    this.itemExtentBuilder,
    this.prototypeItem,
    required this.itemBuilder,
    this.findChildIndexCallback,
    this.itemCount,
    this.addAutomaticKeepAlives = true,
    this.addRepaintBoundaries = true,
    this.addSemanticIndexes = true,
    this.cacheExtent,
    this.physics,
    this.padding,
    this.scrollDirection = Axis.vertical,
    this.shrinkWrap = false,
    this.reverse = false,
    this.children = const [],
  });
  final ScrollController? controller;
  final double? itemExtent;
  final ItemExtentBuilder? itemExtentBuilder;
  final Widget? prototypeItem;
  final NullableIndexedWidgetBuilder? itemBuilder;
  final ChildIndexGetter? findChildIndexCallback;
  final int? itemCount;
  final bool addAutomaticKeepAlives;
  final bool addRepaintBoundaries;
  final bool addSemanticIndexes;
  final double? cacheExtent;
  final ScrollPhysics? physics;
  final List<Widget> children;
  final EdgeInsetsGeometry? padding;
  final Axis scrollDirection;
  final bool shrinkWrap;
  final bool reverse;
}

/// `ListView` needs a `ListView.builder` companion for the two screens that index a flat
/// list of mixed-height cells — the ledger's day headers are shorter than its rows.
class SliverVariedExtentListWidget extends Widget {
  const SliverVariedExtentListWidget({super.key});
}

// ── animation ────────────────────────────────────────────────────────────────

class AnimationController extends Listenable {
  AnimationController({
    required TickerProvider this.vsync,
    this.duration,
    this.reverseDuration,
    this.lowerBound = 0,
    this.upperBound = 1,
  });
  final TickerProvider vsync;
  final Duration? duration;
  final Duration? reverseDuration;
  final double lowerBound;
  final double upperBound;
  double get value => 0;
  set value(double v) {}
  void dispose() {}
  @override
  void addListener(VoidCallback listener) {}
  @override
  void removeListener(VoidCallback listener) {}
  void forward({double? from}) {}
  void reverse({double? from}) {}
  void reset() {}
  void stop() {}
}

class Animation<T> extends Listenable {
  const Animation();
  T get value => throw UnimplementedError('stub');
  void addListener(VoidCallback listener) {}
  void removeListener(VoidCallback listener) {}
  Animation<double> drive(Animatable<double> child) => const AlwaysStoppedAnimation(0);
}

class AlwaysStoppedAnimation<T> extends Animation<T> {
  const AlwaysStoppedAnimation(this.value);
  @override
  final T value;
}

abstract class Animatable<T> {
  const Animatable();
}

class Tween<T> extends Animatable<T> {
  Tween({this.begin, this.end});
  final T? begin;
  final T? end;
  Animation<T> animate(Animation<double> parent) => AlwaysStoppedAnimation(begin as T);
}

class AnimatedBuilder extends Widget {
  const AnimatedBuilder({
    super.key,
    required this.animation,
    required this.builder,
    this.child,
  });
  final Listenable animation;
  final Widget Function(BuildContext context, Widget? child) builder;
  final Widget? child;
}

class AnimatedContainer extends Widget {
  const AnimatedContainer({
    super.key,
    this.duration,
    this.curve,
    this.decoration,
    this.color,
    this.child,
    this.height,
    this.width,
    this.padding,
  });
  final Duration? duration;
  final Curve? curve;
  final Decoration? decoration;
  final Color? color;
  final Widget? child;
  final double? height;
  final double? width;
  final EdgeInsetsGeometry? padding;
}

class AnimatedOpacity extends Widget {
  const AnimatedOpacity({
    super.key,
    required this.opacity,
    this.duration,
    this.curve,
    this.child,
  });
  final double opacity;
  final Duration? duration;
  final Curve? curve;
  final Widget? child;
}

typedef TickerCallback = void Function(Duration elapsed);

abstract class TickerProvider {
  Ticker createTicker(TickerCallback onTick);
}

/// The real `SingleTickerProviderStateMixin` shape: `on State<T>` so `vsync: this`
/// type-checks inside a `State` subclass, which is the only way the app uses it.
mixin SingleTickerProviderStateMixin<T extends StatefulWidget> on State<T>
    implements TickerProvider {
  Ticker? _ticker;
  @override
  Ticker createTicker(TickerCallback onTick) => _ticker = Ticker(onTick);
  @override
  void dispose() {
    _ticker?.dispose();
    super.dispose();
  }
}

final class Ticker {
  Ticker(this.onTick);
  final void Function(Duration elapsed) onTick;
  void dispose() {}
  void stop() {}
}

// ── material ─────────────────────────────────────────────────────────────────

enum Brightness { light, dark }

class ThemeData {
  const ThemeData({
    this.brightness = Brightness.light,
    this.colorScheme,
    this.scaffoldBackgroundColor = const Color(0x00000000),
    this.textTheme = const TextTheme(),
    this.useMaterial3 = true,
    this.fontFamily,
    this.fontFamilyFallback,
    this.extensions,
    this.visualDensity = VisualDensity.standard,
    this.platform,
  });
  final Brightness brightness;
  final ColorScheme? colorScheme;
  final Color scaffoldBackgroundColor;
  final TextTheme textTheme;
  final bool useMaterial3;
  final String? fontFamily;
  final List<String>? fontFamilyFallback;
  final Iterable<ThemeExtension<dynamic>>? extensions;
  final VisualDensity visualDensity;
  final Object? platform;
  /// The typed accessor the whole widget layer reads semantic colours through.
  T? extension<T>() => null;

  ThemeData copyWith({
    Brightness? brightness,
    ColorScheme? colorScheme,
    Color scaffoldBackgroundColor = const Color(0x00000000),
    TextTheme? textTheme,
    Iterable<ThemeExtension<dynamic>>? extensions,
  }) =>
      this;
}

class VisualDensity {
  const VisualDensity(this.horizontal, this.vertical);
  final double horizontal;
  final double vertical;
  static const VisualDensity standard = VisualDensity(0, 0);
  static const VisualDensity compact = VisualDensity(-2, -2);
  static const VisualDensity comfortable = VisualDensity(-1, -1);
}

/// The base class a project extension hangs its semantic colours on, so a widget reads
/// `Theme.of(context).extension<KhataColors>()` instead of importing the token class.
abstract class ThemeExtension<T extends ThemeExtension<T>> {
  const ThemeExtension();
  T copyWith();
  T lerp(covariant T? other, double t);
}

class Theme {
  const Theme({required this.data, required this.child});
  final ThemeData data;
  final Widget child;
  static ThemeData of(BuildContext context) => const ThemeData();
}

class TextTheme {
  const TextTheme({
    this.displayLarge,
    this.displayMedium,
    this.displaySmall,
    this.headlineLarge,
    this.headlineMedium,
    this.headlineSmall,
    this.titleLarge,
    this.titleMedium,
    this.titleSmall,
    this.bodyLarge,
    this.bodyMedium,
    this.bodySmall,
    this.labelLarge,
    this.labelMedium,
    this.labelSmall,
  });
  final TextStyle? displayLarge;
  final TextStyle? displayMedium;
  final TextStyle? displaySmall;
  final TextStyle? headlineLarge;
  final TextStyle? headlineMedium;
  final TextStyle? headlineSmall;
  final TextStyle? titleLarge;
  final TextStyle? titleMedium;
  final TextStyle? titleSmall;
  final TextStyle? bodyLarge;
  final TextStyle? bodyMedium;
  final TextStyle? bodySmall;
  final TextStyle? labelLarge;
  final TextStyle? labelMedium;
  final TextStyle? labelSmall;
  TextTheme apply({
    String? fontFamily,
    List<String>? fontFamilyFallback,
    double displayColor = 1,
  }) =>
      this;
  TextTheme copyWith({
    TextStyle? displayLarge,
    TextStyle? displayMedium,
    TextStyle? displaySmall,
    TextStyle? headlineSmall,
    TextStyle? titleLarge,
    TextStyle? titleMedium,
    TextStyle? titleSmall,
    TextStyle? bodyLarge,
    TextStyle? bodyMedium,
    TextStyle? bodySmall,
    TextStyle? labelLarge,
    TextStyle? labelMedium,
    TextStyle? labelSmall,
  }) =>
      this;
}

class ColorScheme {
  const ColorScheme({
    required this.brightness,
    required this.primary,
    required this.onPrimary,
    required this.secondary,
    required this.onSecondary,
    required this.error,
    required this.onError,
    required this.surface,
    required this.onSurface,
    this.surfaceContainerHighest,
    this.onSurfaceVariant,
    this.outline,
    this.outlineVariant,
  });
  final Brightness brightness;
  final Color primary;
  final Color onPrimary;
  final Color secondary;
  final Color onSecondary;
  final Color error;
  final Color onError;
  final Color surface;
  final Color onSurface;
  final Color? surfaceContainerHighest;
  final Color? onSurfaceVariant;
  final Color? outline;
  final Color? outlineVariant;
}

class MaterialApp extends Widget {
  const MaterialApp({
    super.key,
    this.title = '',
    this.theme,
    this.darkTheme,
    this.themeMode,
    this.home,
    this.routes,
    this.onGenerateRoute,
    this.onGenerateInitialRoutes,
    this.builder,
    this.locale,
    this.supportedLocales,
    this.localizationsDelegates,
    this.debugShowCheckedModeBanner = true,
    this.navigatorKey,
    this.navigatorObservers,
    this.restorationScopeId,
    this.scrollBehavior,
  });
  final String title;
  final ThemeData? theme;
  final ThemeData? darkTheme;
  final ThemeMode? themeMode;
  final Widget? home;
  final Map<String, WidgetBuilder>? routes;
  final Widget Function(RouteSettings settings)? onGenerateRoute;
  final List<Widget Function(BuildContext, String)>? onGenerateInitialRoutes;
  final Widget Function(BuildContext context, Widget? child)? builder;
  final Locale? locale;
  final List<Locale>? supportedLocales;
  final List<Object>? localizationsDelegates;
  final bool debugShowCheckedModeBanner;
  final GlobalKey? navigatorKey;
  final List<Object>? navigatorObservers;
  final String? restorationScopeId;
  final Object? scrollBehavior;
}

class RouteSettings {
  const RouteSettings({this.name, this.arguments});
  final String? name;
  final Object? arguments;
}

enum ThemeMode { system, light, dark }

class Locale {
  const Locale(this.languageCode, [this.countryCode]);
  final String languageCode;
  final String? countryCode;
}

class MediaQuery extends InheritedWidget {
  const MediaQuery({super.key, required this.data, required super.child});
  final MediaQueryData data;
  static MediaQueryData of(BuildContext context) => const MediaQueryData();
  static double textScaleFactorOf(BuildContext context) => 1;
}

class MediaQueryData {
  const MediaQueryData({
    this.size = const Size(360, 800),
    this.textScaler = TextScaler.noScaling,
    this.viewPadding = EdgeInsets.zero,
    this.padding = EdgeInsets.zero,
    this.devicePixelRatio = 1,
  });
  final Size size;
  final TextScaler textScaler;
  final EdgeInsets viewPadding;
  final EdgeInsets padding;
  final double devicePixelRatio;
  double get textScaleFactor => 1;
}

class Navigator extends StatefulWidget {
  const Navigator({super.key, this.pages, this.onPopPage, this.observers});
  final List<Object>? pages;
  final Object? onPopPage;
  final List<NavigatorObserver>? observers;
  @override
  State<Navigator> createState() => NavigatorState();

  static void pop<T extends Object?>(BuildContext context, [T? result]) {}
  static Future<T?> push<T extends Object?>(BuildContext context, Object route) =>
      Future<T?>.value();
  static NavigatorState of(BuildContext context) => NavigatorState();
}

class NavigatorState extends State<Navigator> {
  void pop<T extends Object?>([T? result]) {}
  Future<T?> push<T extends Object?>(Object page) => Future<T?>.value();
  bool canPop() => false;
}

class NavigatorObserver {
  const NavigatorObserver();
}

class Page<T> {
  const Page({this.key, this.name, this.arguments});
  final Key? key;
  final String? name;
  final Object? arguments;
}

class MaterialPage<T> extends Page<T> {
  const MaterialPage({super.key, super.name, super.arguments, required this.child});
  final Widget child;
}

class Route<T> {
  const Route({this.settings});
  final RouteSettings? settings;
}

class Scaffold extends Widget {
  const Scaffold({
    super.key,
    this.appBar,
    this.body,
    this.floatingActionButton,
    this.bottomNavigationBar,
    this.bottomSheet,
    this.backgroundColor,
    this.drawer,
    this.resizeToAvoidBottomInset,
  });
  final PreferredSizeWidget? appBar;
  final Widget? body;
  final Widget? floatingActionButton;
  final Widget? bottomNavigationBar;
  final Widget? bottomSheet;
  final Color? backgroundColor;
  final Widget? drawer;
  final bool? resizeToAvoidBottomInset;
}

class AppBar extends StatelessWidget implements PreferredSizeWidget {
  const AppBar({
    super.key,
    this.title,
    this.actions,
    this.leading,
    this.bottom,
    this.elevation,
    this.backgroundColor,
    this.centerTitle,
  });
  final Widget? title;
  final List<Widget>? actions;
  final Widget? leading;
  final PreferredSizeWidget? bottom;
  final double? elevation;
  final Color? backgroundColor;
  final bool? centerTitle;
  @override
  Size get preferredSize => const Size(0, 56);
  @override
  Widget build(BuildContext context) => throw UnimplementedError('stub');
}

abstract interface class PreferredSizeWidget implements Widget {
  Size get preferredSize;
}

class Card extends Widget {
  const Card({super.key, this.child, this.color, this.elevation, this.margin, this.shape});
  final Widget? child;
  final Color? color;
  final double? elevation;
  final EdgeInsetsGeometry? margin;
  final Object? shape;
}

class Divider extends Widget {
  const Divider({super.key, this.height, this.thickness, this.color, this.indent, this.endIndent});
  final double? height;
  final double? thickness;
  final Color? color;
  final double? indent;
  final double? endIndent;
}

class ListTile extends Widget {
  const ListTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.dense,
    this.isThreeLine,
  });
  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool? dense;
  final bool? isThreeLine;
}

class ElevatedButton extends StatelessWidget {
  const ElevatedButton({super.key, this.onPressed, this.child, this.style});
  const ElevatedButton.icon({
    super.key,
    required this.onPressed,
    required Widget icon,
    required Widget label,
  })  : child = label,
        style = null;
  final VoidCallback? onPressed;
  final Widget? child;
  final ButtonStyle? style;
  @override
  Widget build(BuildContext context) => child ?? const SizedBox();
}

class FilledButton extends StatelessWidget {
  const FilledButton({super.key, this.onPressed, this.child, this.style});
  const FilledButton.icon({
    super.key,
    required this.onPressed,
    required Widget icon,
    required Widget label,
  })  : child = label,
        style = null;
  final VoidCallback? onPressed;
  final Widget? child;
  final ButtonStyle? style;
  @override
  Widget build(BuildContext context) => child ?? const SizedBox();
}

class OutlinedButton extends StatelessWidget {
  const OutlinedButton({super.key, this.onPressed, this.child, this.style});
  final VoidCallback? onPressed;
  final Widget? child;
  final ButtonStyle? style;
  @override
  Widget build(BuildContext context) => child ?? const SizedBox();
}

class TextButton extends StatelessWidget {
  const TextButton({super.key, this.onPressed, this.child, this.style});
  final VoidCallback? onPressed;
  final Widget? child;
  final ButtonStyle? style;
  @override
  Widget build(BuildContext context) => child ?? const SizedBox();
}

class IconButton extends StatelessWidget {
  const IconButton({
    super.key,
    required this.onPressed,
    required this.icon,
    this.iconSize,
    this.tooltip,
    this.color,
  });
  final VoidCallback? onPressed;
  final Widget icon;
  final double? iconSize;
  final String? tooltip;
  final Color? color;
  @override
  Widget build(BuildContext context) => icon;
}

class ButtonStyle {
  const ButtonStyle({this.backgroundColor, this.foregroundColor, this.padding, this.shape});
  final Color? backgroundColor;
  final Color? foregroundColor;
  final EdgeInsetsGeometry? padding;
  final Object? shape;
}

class FloatingActionButton extends Widget {
  const FloatingActionButton({
    super.key,
    this.onPressed,
    this.child,
    this.tooltip,
    this.backgroundColor,
    this.foregroundColor,
    this.mini,
  });
  final VoidCallback? onPressed;
  final Widget? child;
  final String? tooltip;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final bool? mini;
}

class FloatingActionButtonLocation {
  const FloatingActionButtonLocation();
  static const FloatingActionButtonLocation endFloat = FloatingActionButtonLocation();
}

class TabBar extends Widget {
  const TabBar({super.key, required this.tabs, this.controller, this.onTap});
  final List<Widget> tabs;
  final Object? controller;
  final ValueChanged<int>? onTap;
}

class TabController extends Animation<double> {
  TabController({required this.length, required this.vsync, this.initialIndex = 0});
  final int length;
  final Object? vsync;
  final int initialIndex;
  int get index => initialIndex;
  void animateTo(int value) {}
  void dispose() {}
}

class CircularProgressIndicator extends Widget {
  const CircularProgressIndicator({super.key, this.value, this.color, this.strokeWidth});
  final double? value;
  final Color? color;
  final double? strokeWidth;
}

class LinearProgressIndicator extends Widget {
  const LinearProgressIndicator({super.key, this.value, this.color, this.backgroundColor});
  final double? value;
  final Color? color;
  final Color? backgroundColor;
}

class Checkbox extends Widget {
  const Checkbox({super.key, required this.value, this.onChanged});
  final bool? value;
  final ValueChanged<bool?>? onChanged;
}

class Switch extends Widget {
  const Switch({super.key, required this.value, this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;
}

class TextField extends Widget {
  const TextField({
    super.key,
    this.controller,
    this.decoration,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.autofocus,
    this.obscureText = false,
    this.textInputAction,
    this.style,
    this.maxLines,
  });
  final Object? controller;
  final Object? decoration;
  final Object? keyboardType;
  final List<Object>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final bool? autofocus;
  final bool obscureText;
  final Object? textInputAction;
  final TextStyle? style;
  final int? maxLines;
}

class InputDecoration {
  const InputDecoration({
    this.labelText,
    this.hintText,
    this.prefixIcon,
    this.suffixIcon,
    this.border,
    this.errorText,
    this.counterText,
  });
  final String? labelText;
  final String? hintText;
  final Widget? prefixIcon;
  final Widget? suffixIcon;
  final Object? border;
  final String? errorText;
  final String? counterText;
}

class TextEditingController {
  TextEditingController({String? text}) : text = text ?? '';
  String text;
  void dispose() {}
}

class Tooltip extends Widget {
  const Tooltip({super.key, required this.message, this.child});
  final String message;
  final Widget? child;
}

class SnackBar {
  const SnackBar({required this.content, this.duration, this.backgroundColor});
  final Widget content;
  final Duration? duration;
  final Color? backgroundColor;
}

class ScaffoldMessenger {
  static ScaffoldMessengerState of(BuildContext context) => ScaffoldMessengerState();
}

class ScaffoldMessengerState {
  void showSnackBar(SnackBar snackBar) {}
  void hideCurrentSnackBar() {}
}

class SingleChildScrollView extends Widget {
  const SingleChildScrollView({super.key, this.child, this.padding, this.controller});
  final Widget? child;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
}

class Semantics extends Widget {
  const Semantics({
    super.key,
    this.child,
    this.label,
    this.value,
    this.button,
    this.header,
    this.liveRegion,
    this.excludeSemantics,
  });
  final Widget? child;
  final String? label;
  final String? value;
  final bool? button;
  final bool? header;
  final bool? liveRegion;
  final bool? excludeSemantics;
}

class SafeArea extends Widget {
  const SafeArea({super.key, required this.child, this.top = true, this.bottom = true});
  final Widget child;
  final bool top;
  final bool bottom;
}

class Hero extends Widget {
  const Hero({super.key, required this.tag, required this.child});
  final Object tag;
  final Widget child;
}
