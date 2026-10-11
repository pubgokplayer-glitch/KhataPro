/// KhataPro · `ThemeData` from `tokens.dart`.
///
/// The palette, the contrast pairs and the type scale were audited by `tool/ui_verify.dart`
/// (contrast ratios, dark/light pairs, semantic names). This file only *transports* them
/// into Flutter's theme system, and it is deliberately the only file that does: a widget
/// that reaches for `ThemeTokens.light` directly would stop following the dark theme, which
/// is exactly the bug the theme extension below exists to prevent.
///
/// ## Three rules this file encodes
///
/// 1. **Semantic colours come from [KhataColors], not from `colorScheme`.** `colorScheme`
///    has `error` but not `warning`, and it has no notion of "money in" versus "money out" —
///    the two colours a ledger is read by. `moneyIn`/`moneyOut` are theme extensions so a
///    row can ask for them without importing the token class.
/// 2. **Urdu gets its own line height.** Nastaliq stacks and kerning make 1.35 clip; the
///    verified value is [TypeScale.lineHeightUrdu] (1.55). [KhataType.urdu] applies it.
/// 3. **Fonts are opt-in by name.** The font files are fetched by `tool/fetch_fonts.sh` and
///    the `fonts:` block in `pubspec.yaml` ships commented — a declared-but-missing font
///    asset is a *hard build failure*. So the families are parameters with a null default:
///    pass them after uncommenting the block, and everything picks them up from here.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// The font family names that `tool/fetch_fonts.sh` + the pubspec `fonts:` block declare.
abstract final class KhataFonts {
  /// Urdu Nastaliq. Shaping matters more than the family name: without this the Urdu
  /// strings render in a Naskh fallback, which reads as "some other language".
  static const String urdu = 'NotoNastaliqUrdu';

  /// Latin + numerals. Inter is what the design tokens were measured against.
  static const String latin = 'Inter';
}

/// The semantic colours, reachable as `Theme.of(context).extension<KhataColors>()!`.
///
/// `lerp` and `copyWith` are not decoration: Flutter calls `lerp` on every theme
/// transition (light → dark switch), and a null-returning implementation turns the
/// animation into a flash of the wrong palette.
final class KhataColors extends ThemeExtension<KhataColors> {
  const KhataColors({
    required this.canvas,
    required this.surface,
    required this.surfaceVariant,
    required this.outline,
    required this.outlineStrong,
    required this.onCanvas,
    required this.onSurfaceMuted,
    required this.brand,
    required this.onBrand,
    required this.moneyIn,
    required this.moneyOut,
    required this.warning,
    required this.critical,
    required this.isDark,
  });

  factory KhataColors.of(ThemeTokens tokens) => KhataColors(
        canvas: Color(tokens.canvas),
        surface: Color(tokens.surface),
        surfaceVariant: Color(tokens.surfaceVariant),
        outline: Color(tokens.outline),
        outlineStrong: Color(tokens.outlineStrong),
        onCanvas: Color(tokens.onCanvas),
        onSurfaceMuted: Color(tokens.onSurfaceMuted),
        brand: Color(tokens.brand),
        onBrand: Color(tokens.onBrand),
        moneyIn: Color(tokens.moneyIn),
        moneyOut: Color(tokens.moneyOut),
        warning: Color(tokens.warning),
        critical: Color(tokens.critical),
        isDark: tokens.isDark,
      );

  /// The page behind the cards.
  final Color canvas;
  final Color surface;

  /// Rows that alternate, empty-state panels, the "no data" band.
  final Color surfaceVariant;

  /// Hairlines that are decoration only.
  final Color outline;

  /// Lines that carry meaning: chart axes, the selected row's edge. ≥ 3:1 by contract.
  final Color outlineStrong;

  final Color onCanvas;

  /// Secondary text: dates, memos, counts. Still ≥ 4.5:1 — muted is not "faint".
  final Color onSurfaceMuted;

  final Color brand;

  /// Text on [brand]. Never hard-coded white: the brand is dark in light mode.
  final Color onBrand;

  /// Received / credited. A colour, never the *only* signal — the `Dr`/`Cr` suffix always
  /// ships with it, because colour alone fails for the ~8% of men who cannot separate
  /// these two greens and reds.
  final Color moneyIn;

  /// Paid / debited.
  final Color moneyOut;

  /// Something needs attention but is not wrong (a stale sync, an unverified backup).
  final Color warning;

  /// The books do not balance, or an invariant is violated.
  final Color critical;

  final bool isDark;

  /// The colour a signed balance renders in. Zero is neutral, and the sign decides — the
  /// one place a sign-to-colour decision is made, so a screen cannot disagree with a chart.
  Color forBalance(int minor) {
    if (minor > 0) return moneyIn;
    if (minor < 0) return moneyOut;
    return onSurfaceMuted;
  }

  @override
  KhataColors copyWith({
    Color? canvas,
    Color? surface,
    Color? surfaceVariant,
    Color? outline,
    Color? outlineStrong,
    Color? onCanvas,
    Color? onSurfaceMuted,
    Color? brand,
    Color? onBrand,
    Color? moneyIn,
    Color? moneyOut,
    Color? warning,
    Color? critical,
    bool? isDark,
  }) =>
      KhataColors(
        canvas: canvas ?? this.canvas,
        surface: surface ?? this.surface,
        surfaceVariant: surfaceVariant ?? this.surfaceVariant,
        outline: outline ?? this.outline,
        outlineStrong: outlineStrong ?? this.outlineStrong,
        onCanvas: onCanvas ?? this.onCanvas,
        onSurfaceMuted: onSurfaceMuted ?? this.onSurfaceMuted,
        brand: brand ?? this.brand,
        onBrand: onBrand ?? this.onBrand,
        moneyIn: moneyIn ?? this.moneyIn,
        moneyOut: moneyOut ?? this.moneyOut,
        warning: warning ?? this.warning,
        critical: critical ?? this.critical,
        isDark: isDark ?? this.isDark,
      );

  @override
  KhataColors lerp(covariant KhataColors? other, double t) {
    if (other == null) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t) ?? a;
    return KhataColors(
      canvas: mix(canvas, other.canvas),
      surface: mix(surface, other.surface),
      surfaceVariant: mix(surfaceVariant, other.surfaceVariant),
      outline: mix(outline, other.outline),
      outlineStrong: mix(outlineStrong, other.outlineStrong),
      onCanvas: mix(onCanvas, other.onCanvas),
      onSurfaceMuted: mix(onSurfaceMuted, other.onSurfaceMuted),
      brand: mix(brand, other.brand),
      onBrand: mix(onBrand, other.onBrand),
      moneyIn: mix(moneyIn, other.moneyIn),
      moneyOut: mix(moneyOut, other.moneyOut),
      warning: mix(warning, other.warning),
      critical: mix(critical, other.critical),
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }
}

/// Urdu/Nastaliq text, and the one place its line height is applied.
abstract final class KhataType {
  /// Applies the Urdu line height and (when supplied) the Nastaliq family, keeping every
  /// other property of [base]. A ledger row in Urdu is taller than the same row in
  /// English — that is correct, and the list row height accounts for it.
  ///
  /// `fontFamily` is left alone when [family] is null, so the system fallback is used
  /// until `tool/fetch_fonts.sh` has run and the pubspec block is uncommented.
  static TextStyle urdu(TextStyle base, {String? family}) => base.copyWith(
        height: TypeScale.lineHeightUrdu,
        fontFamily: family,
        fontFamilyFallback: family == null ? null : const [KhataFonts.urdu],
      );

  /// Proportional digits misalign a column of amounts; tabular ones do not.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures];
}

abstract final class KhataTheme {
  /// The light theme. Pass the font families once they exist (`fetch_fonts.sh`).
  static ThemeData light({
    String? latinFamily,
    String? urduFamily,
    VisualDensity density = VisualDensity.standard,
  }) =>
      _build(ThemeTokens.light, latinFamily: latinFamily, urduFamily: urduFamily, density: density);

  static ThemeData dark({
    String? latinFamily,
    String? urduFamily,
    VisualDensity density = VisualDensity.standard,
  }) =>
      _build(ThemeTokens.dark, latinFamily: latinFamily, urduFamily: urduFamily, density: density);

  /// Both themes, for `MaterialApp(theme:, darkTheme:, themeMode: ThemeMode.system)`.
  static (ThemeData, ThemeData) pair({String? latinFamily, String? urduFamily}) => (
        light(latinFamily: latinFamily, urduFamily: urduFamily),
        dark(latinFamily: latinFamily, urduFamily: urduFamily),
      );

  /// The semantic colours of the active theme. A single accessor, so a widget never
  /// repeats the `extension<KhataColors>()!` dance (and never silently gets null).
  static KhataColors colorsOf(BuildContext context) =>
      Theme.of(context).extension<KhataColors>() ?? KhataColors.of(ThemeTokens.light);

  static ThemeData _build(
    ThemeTokens tokens, {
    String? latinFamily,
    String? urduFamily,
    VisualDensity density = VisualDensity.standard,
  }) {
    final colors = KhataColors.of(tokens);
    final text = _textTheme(tokens, colors, latinFamily: latinFamily, urduFamily: urduFamily);

    return ThemeData(
      brightness: tokens.isDark ? Brightness.dark : Brightness.light,
      // The nine required roles, all from verified tokens. `background`/`onBackground`
      // are deliberately absent: they are deprecated and the token audit does not
      // measure them.
      colorScheme: ColorScheme(
        brightness: tokens.isDark ? Brightness.dark : Brightness.light,
        primary: colors.brand,
        onPrimary: colors.onBrand,
        secondary: colors.moneyIn,
        onSecondary: colors.surface,
        error: colors.critical,
        onError: colors.surface,
        surface: colors.surface,
        // The M3 component containers are the same token in three places on purpose:
        // this app has one surface, not a stack of elevation tints.
        surfaceContainerHighest: colors.surfaceVariant,
        onSurfaceVariant: colors.onSurfaceMuted,
        outline: colors.outlineStrong,
        outlineVariant: colors.outline,
        onSurface: colors.onCanvas,
      ),
      scaffoldBackgroundColor: colors.canvas,
      textTheme: text,
      useMaterial3: true,
      fontFamily: latinFamily,
      extensions: <ThemeExtension<dynamic>>[colors],
      visualDensity: density,
    );
  }

  static TextTheme _textTheme(
    ThemeTokens tokens,
    KhataColors colors, {
    String? latinFamily,
    String? urduFamily,
  }) {
    // Every amount is tabular: a column of figures must not shimmer as it scrolls, and
    // `FontFeature.tabularFigures` is cheaper than a monospace family.
    TextStyle money(double size, {FontWeight weight = FontWeight.w500}) => TextStyle(
          fontSize: size,
          fontWeight: weight,
          height: TypeScale.lineHeightLatin,
          fontFamily: latinFamily,
          fontFeatures: KhataType.tabular,
        );

    TextStyle body(double size, {Color? color}) => TextStyle(
          fontSize: size,
          height: TypeScale.lineHeightLatin,
          fontFamily: latinFamily,
          color: color,
        );

    return TextTheme(
      displayLarge: money(TypeScale.displayAmount, weight: FontWeight.w600),
      displayMedium: money(TypeScale.title),
      displaySmall: money(TypeScale.section),
      headlineSmall: money(TypeScale.section),
      titleLarge: body(TypeScale.title),
      // The AppBar title is the book's name: Latin, but it may contain an Urdu shop name,
      // so it carries the Urdu fallback as well.
      titleMedium: body(TypeScale.section),
      titleSmall: body(TypeScale.body),
      bodyLarge: body(TypeScale.body),
      bodyMedium: body(TypeScale.body),
      bodySmall: body(TypeScale.caption, color: colors.onSurfaceMuted),
      labelLarge: body(TypeScale.body),
      labelMedium: body(TypeScale.caption),
      labelSmall: body(TypeScale.micro, color: colors.onSurfaceMuted),
    ).apply(
      fontFamily: latinFamily,
      // Applied once here rather than per-style: Nastaliq is the fallback for *any* string
      // that needs it, so an Urdu party name inside an otherwise Latin list still shapes.
      fontFamilyFallback: urduFamily == null ? null : <String>[urduFamily],
    );
  }
}
