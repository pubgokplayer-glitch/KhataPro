/// KhataPro · the design tokens, as pure integers.
///
/// Everything a screen needs to look like itself lives here as plain values — colours as
/// ARGB `int`s, spacing and type sizes as `double`s, motion as `Duration`s. No Flutter
/// import, which means two things:
///
///  * `lib/ui/theme/theme.dart` (the thin file that builds a `ThemeData`) is the only
///    place that knows about `Color`, and
///  * **the palette can be checked**. `tool/ui_verify.dart` computes the WCAG contrast
///    ratio of every foreground/background pair below and fails the suite if one drops
///    under 4.5:1. A shopkeeper reading a balance in daylight, on a cheap LCD, at 60, is
///    the actual user of this palette; "it looks nice on my monitor" is not a test.
///
/// Colour is used with meaning, and only with meaning:
///
/// | token | means | never means |
/// | --- | --- | --- |
/// | `moneyIn` | money arriving (sales, receipts) | a debit |
/// | `moneyOut` | money leaving (purchases, payments) | a credit |
/// | `warning` | due soon, low stock, drafts | an error |
/// | `critical` | overdue, integrity finding, failed sync | a warning |
///
/// The `moneyIn`/`moneyOut` pair is deliberately *not* the accounting Dr/Cr pair: in a
/// ledger, "debit" is not "good" and the sign convention differs per account. Dr/Cr are
/// rendered in text (`formatting.dart`) with the account's own colour, and cash flow —
/// where the direction really is unambiguous — gets the red/green.
library;

/// A token set for one mode.
final class ThemeTokens {
  const ThemeTokens({
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

  /// The page behind the cards.
  final int canvas;

  /// Cards, sheets, the list background.
  final int surface;

  /// Pressed states, table stripes, skeleton rows.
  final int surfaceVariant;

  /// Hairlines: separators, card borders. Perceptible, not assertive.
  final int outline;

  /// Lines that carry meaning: chart axes, focus rings, the edge of a record that is
  /// selected. Checked at ≥ 3:1, the WCAG threshold for non-text.
  final int outlineStrong;

  final int onCanvas;
  final int onSurfaceMuted;

  /// The brand green — used for primary actions and the app bar, nowhere else.
  final int brand;
  final int onBrand;

  final int moneyIn;
  final int moneyOut;
  final int warning;
  final int critical;

  final bool isDark;

  /// `F7F7F5` — for log output and for building an ARGB value from parts.
  String get canvasHex => canvas.toRadixString(16).padLeft(8, '0').toUpperCase();

  static const ThemeTokens light = ThemeTokens(
    canvas: 0xFFF7F7F5,
    surface: 0xFFFFFFFF,
    surfaceVariant: 0xFFEFEFEB,
    outline: 0xFFD0D0C8,
    outlineStrong: 0xFF84847A,
    onCanvas: 0xFF181815,
    onSurfaceMuted: 0xFF57574F,
    brand: 0xFF0F6B4F,
    onBrand: 0xFFFFFFFF,
    moneyIn: 0xFF11624A,
    moneyOut: 0xFFA33327,
    warning: 0xFF8A5300,
    critical: 0xFFB3261E,
    isDark: false,
  );

  /// The dark set is not the light set inverted: the semantic colours are *lightened*
  /// (a saturated red on a dark background vibrates and reads as a warning when it is
  /// not), and the surfaces are warm rather than blue-grey so the app does not look
  /// like a terminal at night.
  static const ThemeTokens dark = ThemeTokens(
    canvas: 0xFF101208,
    surface: 0xFF191B14,
    surfaceVariant: 0xFF24271E,
    outline: 0xFF3B3F33,
    outlineStrong: 0xFF727866,
    onCanvas: 0xFFEDEDE4,
    onSurfaceMuted: 0xFFA6AA9C,
    brand: 0xFF6FD3AC,
    onBrand: 0xFF04301F,
    moneyIn: 0xFF7BD8AE,
    moneyOut: 0xFFFF9E90,
    warning: 0xFFE7C36A,
    critical: 0xFFFF8A80,
    isDark: true,
  );
}

/// WCAG 2.1 relative luminance and contrast, in pure integer arithmetic on ARGB.
///
/// This exists so the palette is *checked* rather than admired. The curve below is the
/// standard sRGB → linear transform and the standard luminance weights; getting them
/// wrong is how a palette ends up 3.1:1 while its author swears it is 5:1.
abstract final class Contrast {
  /// The contrast ratio between two colours, always ≥ 1. 4.5 is the body-text floor,
  /// 3.0 the large-text and UI-component floor.
  static double ratio(int foreground, int background) {
    final a = luminance(foreground);
    final b = luminance(background);
    final lighter = a > b ? a : b;
    final darker = a > b ? b : a;
    return (lighter + 0.05) / (darker + 0.05);
  }

  static double luminance(int argb) {
    final r = _linear((argb >> 16) & 0xFF);
    final g = _linear((argb >> 8) & 0xFF);
    final b = _linear(argb & 0xFF);
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  }

  static double _linear(int channel) {
    final value = channel / 255.0;
    return value <= 0.03928
        ? value / 12.92
        : _pow(value + 0.055, 2.4) / _pow(1.055, 2.4);
  }

  /// `math.pow` returns `num`; the exponent here is a constant so a small loop is both
  /// faster and free of `num`→`double` casts.
  static double _pow(double base, double exponent) {
    // x^2.4 = x^2 · x^0.4, and x^0.4 = exp(0.4 · ln x) — one `dart:math` call, kept out
    // of the hot path by the fact that palettes are checked once per test run.
    var result = 1.0;
    var squared = base * base;
    var rest = exponent - 2;
    result = squared;
    while (rest > 0) {
      final step = rest > 1 ? 1.0 : rest;
      result *= _exp(_ln(base) * step);
      rest -= step;
    }
    return result;
  }

  static double _ln(double x) {
    // Natural log by the standard series around 1, with range reduction by powers of
    // two. Enough precision for a contrast ratio; not used anywhere else.
    if (x <= 0) return double.negativeInfinity;
    var scaled = x;
    var adjustment = 0;
    while (scaled > 2) {
      scaled /= 2;
      adjustment += 1;
    }
    while (scaled < 0.5) {
      scaled *= 2;
      adjustment -= 1;
    }
    final z = (scaled - 1) / (scaled + 1);
    var term = z;
    var sum = 0.0;
    for (var n = 1; n <= 41; n += 2) {
      sum += term / n;
      term *= z * z;
    }
    return 2 * sum + adjustment * 0.6931471805599453;
  }

  static double _exp(double x) {
    var term = 1.0;
    var sum = 1.0;
    for (var n = 1; n < 40; n++) {
      term *= x / n;
      sum += term;
    }
    return sum;
  }
}

/// The 4/8 pt spacing scale, named by intent rather than size — `Spacing.lg` survives a
/// redesign, `Spacing.sixteen` does not.
abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;

  /// The minimum size of anything a thumb is expected to hit.
  static const double minTouchTarget = 48;

  /// The height of a ledger row — 56 shows a date, a description and an amount without
  /// the eye having to hunt, and packs eleven of them onto a 640 dp screen.
  static const double listRowHeight = 56;
  static const double dayHeaderHeight = 34;
}

abstract final class Radii {
  static const double sm = 6;
  static const double md = 12;
  static const double lg = 18;
  static const double pill = 999;
}

/// Motion timings. Short on purpose: 120–220 ms reads as *fast* on a 120 Hz panel, and
/// anything over 400 ms starts to feel like the app is thinking.
abstract final class Motion {
  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration base = Duration(milliseconds: 220);
  static const Duration slow = Duration(milliseconds: 320);

  /// The chart animation on a range change. Long enough to show the direction of
  /// travel, short enough that a shopkeeper changing the period five times in a row is
  /// never waiting on an animation.
  static const Duration chartMorph = Duration(milliseconds: 260);
}

/// Type sizes, in logical pixels. The Urdu face needs ~15 % more line height than Latin
/// at the same size — Nastaliq has deep descenders and stacked forms — which is why the
/// two are separate constants rather than one ratio.
abstract final class TypeScale {
  static const double displayAmount = 30;
  static const double title = 21;
  static const double section = 16;
  static const double body = 14.5;
  static const double caption = 12.5;
  static const double micro = 11;

  static const double lineHeightLatin = 1.35;
  static const double lineHeightUrdu = 1.55;
}
