/// KhataPro · integer-only money.
///
/// RULE ZERO OF THIS CODEBASE: money is never a `double`, never a `num`, never
/// a `String` in transit. It is an `int` of minor units (paise) wrapped so the
/// compiler refuses to let it be added to a bare int by accident.
///
/// Why this file exists at all, rather than using `int` directly: the classic
/// accounting-app catastrophe is `balance = balance + 0.1` accumulating float
/// noise until a customer's ledger is off by a paisa and nobody can explain
/// where it went. Wrapping the int makes the integer-ness infectious.
///
/// No `package:` imports here — this file is pure Dart so it can be executed
/// and property-tested by `tool/crdt_verify.dart` with no dependency resolution.
library;

import '../errors/khata_exception.dart';

/// How thousands are grouped for display. Pakistani users read `12,34,567`
/// (lakh/crore) — printing `1,234,567` is a subtle "this app wasn't made for
/// me" signal, and it is a one-line fix to get right.
enum GroupingPattern {
  /// 1,234,567 — en-US, international finance.
  international,

  /// 12,34,567 — Indian subcontinent (lakh = 10^5, crore = 10^7).
  lakhCrore,

  /// 1234567 — no separators (machine output: CSV, QR payloads).
  none,
}

/// How a division that lands between two minor units is resolved.
enum RoundingMode {
  /// Half away from zero. What a shopkeeper expects: 2.345 → 2.35.
  halfUp,

  /// Banker's rounding (half to even). Use for statistical/aggregate reports
  /// where systematic upward bias would matter.
  halfEven,

  /// Always toward zero.
  truncate,

  /// Always away from zero.
  ceiling,
}

/// Thrown when two amounts of different currency scale meet. Mixing PKR
/// (scale 2) with JPY (scale 0) without an explicit conversion is a bug, and
/// this makes it a loud one instead of a 100× error.
final class MoneyScaleMismatch extends KhataException {
  const MoneyScaleMismatch(this.left, this.right)
      : super(code: 'MONEY_SCALE_MISMATCH', message: 'Currency scale mismatch: $left vs $right');

  final int left;
  final int right;
}

/// An exact monetary amount, stored as a signed count of minor units.
///
/// ```dart
/// final a = MoneyMinor.parse('Rs 1,25,000.50');   // 12500050 minor units
/// final b = a.percent(1800);                      // 18% GST → 22500.09
/// final parts = a.allocate([2, 1, 1]);            // splits with no lost paisa
/// ```
final class MoneyMinor implements Comparable<MoneyMinor> {
  const MoneyMinor.fromMinor(this.minor, this.scale);

  /// Zero for a currency with [scale] decimals.
  const MoneyMinor.zero([this.scale = 2]) : minor = 0;

  /// The signed amount in minor units. `Rs 1,250.75` → `125075`.
  final int minor;

  /// Number of decimal places for this currency: PKR 2, JPY 0, KWD 3.
  final int scale;

  /// Largest amount this type can hold: 2^63-1 minor units.
  /// At scale 2 that is ≈ Rs 92 quadrillion — no realistic ledger reaches it,
  /// and [guardOverflow] makes sure we find out before SQLite silently
  /// saturates.
  static const int maxMinor = 9223372036854775807;
  static const int minMinor = -9223372036854775808;

  // ── construction ────────────────────────────────────────────────────────

  /// From a whole-unit amount, e.g. `MoneyMinor.ofMajor(1250, 2)` = Rs 1,250.00.
  factory MoneyMinor.ofMajor(int major, [int scale = 2]) =>
      MoneyMinor.fromMinor(major * _pow10(scale), scale);

  /// From a decimal literal **for literals and tests only**.
  /// Uses `toStringAsFixed`-free arithmetic: the double is scaled and rounded
  /// once, which is exact for any value a programmer types in source. Never
  /// call this with a computed total — that is how floats get back in.
  factory MoneyMinor.fromDouble(double value, [int scale = 2]) {
    final scaled = value * _pow10(scale);
    assert(scaled.abs() < 9.007199254740992e15, 'fromDouble: value too large to be exact');
    return MoneyMinor.fromMinor(scaled.round(), scale);
  }

  /// Parse a user-entered or imported amount.
  ///
  /// Handles what a Pakistani shop actually produces:
  ///   `1,25,000.50` · `125000.5` · `Rs 1,250` · `(1,250)` (negative in parens) ·
  ///   `-1 250,75` · `۱۲۳۴.۵۰` Urdu · `١٢٣٤.٥٠` Arabic-Indic.
  ///
  /// Rejects anything ambiguous instead of guessing, because every silent guess
  /// is a potential 10× or 1000× error in someone's books:
  ///   · `1.5k`           → unknown letters
  ///   · `12.345`         → more decimals than the currency has (NOT 123.45)
  ///   · `1,2,3,4,5`      → malformed grouping
  ///   · `1.5` in JPY     → decimals for a zero-decimal currency
  ///
  /// Separator rules (deliberately simple and testable):
  ///   · space-likes are always grouping separators
  ///   · if both `.` and `,` appear, the LAST one is the decimal separator
  ///   · a single `.` with 1..scale trailing digits is a decimal point;
  ///     with more, it is an error (this locale writes decimals with `.`)
  ///   · a single `,` with 1..scale trailing digits is a decimal separator
  ///     (imported European data); otherwise it is grouping
  ///   · any other grouping must form valid groups (1-3 digits, last group 3)
  factory MoneyMinor.parse(String input, {int scale = 2}) {
    final normalised = _normaliseDigits(input).trim();
    if (normalised.isEmpty) throw FormatException('empty amount', input);

    // ── sign ──────────────────────────────────────────────────────────────
    var negative = false;
    var body = normalised;
    if (body.startsWith('(') && body.endsWith(')')) {
      negative = true;
      body = body.substring(1, body.length - 1).trim();
    }
    if (body.startsWith('-')) {
      negative = !negative;
      body = body.substring(1).trim();
    }
    if (body.endsWith('-')) {
      negative = !negative;
      body = body.substring(0, body.length - 1).trim();
    }

    // ── currency markers ──────────────────────────────────────────────────
    // Only known markers are stripped. Any other letter means the input is not
    // an amount ("1.5k", "about 500", "1250 rs extra") and guessing would be
    // reckless.
    body = _stripCurrencyMarkers(body, input);

    // ── separators ────────────────────────────────────────────────────────
    body = body.replaceAll(RegExp(r'[\u00A0\u2009\u202F ]'), '');
    if (body.isEmpty) throw FormatException('no digits in amount', input);

    final dots = '.'.allMatches(body).length;
    final commas = ','.allMatches(body).length;
    String? decimalSeparator;
    if (dots > 0 && commas > 0) {
      decimalSeparator = body.lastIndexOf('.') > body.lastIndexOf(',') ? '.' : ',';
    } else if (dots == 1) {
      final tail = body.substring(body.indexOf('.') + 1);
      if (tail.isEmpty || !_allDigits(tail)) {
        throw FormatException('malformed decimal part "$tail"', input);
      }
      if (tail.length <= scale) {
        decimalSeparator = '.';
      } else {
        throw FormatException(
          '"$input" has ${tail.length} decimal places but this currency has $scale',
          input,
        );
      }
    } else if (dots > 1) {
      // "1.234.567" — European grouping.
      decimalSeparator = null;
    } else if (commas == 1) {
      final tail = body.substring(body.indexOf(',') + 1);
      if (_allDigits(tail) && tail.length <= scale && scale > 0) {
        decimalSeparator = ',';
      }
    }

    String intPart = body;
    var fracPart = '';
    if (decimalSeparator != null) {
      final at = body.lastIndexOf(decimalSeparator);
      intPart = body.substring(0, at);
      fracPart = body.substring(at + 1);
    }

    // Whatever remains in the integer part must be digits or *grouping*
    // separators forming valid groups.
    final intDigits = _stripGrouping(intPart, input, scale);
    if (intDigits.isEmpty && fracPart.isEmpty) {
      throw FormatException('no digits in amount', input);
    }
    if (intDigits.length > 18) throw FormatException('amount out of range', input);
    if (fracPart.length > scale) {
      throw FormatException(
        '"$input" has more than $scale decimal places',
        input,
      );
    }
    if (fracPart.isNotEmpty && !_allDigits(fracPart)) {
      throw FormatException('malformed decimal part "$fracPart"', input);
    }
    if (scale == 0 && fracPart.isNotEmpty && _hasNonZeroDigit(fracPart)) {
      throw FormatException('$scale-decimal currency cannot hold a fraction', input);
    }

    final fraction = fracPart.padRight(scale, '0');
    final magnitude = int.parse('${intDigits.isEmpty ? '0' : intDigits}$fraction');
    if (magnitude > maxMinor) throw FormatException('amount out of range', input);
    return MoneyMinor.fromMinor(negative ? -magnitude : magnitude, scale);
  }

  /// Removes a leading or trailing currency marker from the allowlist.
  /// Throws when any other letter survives — the caller passed text, not an
  /// amount.
  static String _stripCurrencyMarkers(String body, String original) {
    const markers = [
      'Rs.', 'Rs', 'PKR', 'rs.', 'rs', 'pkr', '₨', 'INR', 'inr', '₹',
      'USD', 'usd', '\$', 'EUR', 'eur', '€', 'GBP', 'gbp', '£',
      'AED', 'aed', 'SAR', 'sar', 'د.إ', 'روپے', 'روپیہ', 'روپے۔',
    ];
    var body0 = body.trim();
    var changed = true;
    while (changed) {
      changed = false;
      for (final marker in markers) {
        if (body0.toLowerCase().startsWith(marker.toLowerCase())) {
          body0 = body0.substring(marker.length).trim();
          changed = true;
        } else if (body0.toLowerCase().endsWith(marker.toLowerCase())) {
          body0 = body0.substring(0, body0.length - marker.length).trim();
          changed = true;
        }
      }
    }
    // Any remaining letter (Latin, Urdu, Arabic) means we misread the input.
    final stray = RegExp(r'[A-Za-z\u0600-\u06FF]').firstMatch(body0);
    if (stray != null) {
      throw FormatException(
        'unrecognised text "${stray.group(0)}" in amount "$original"',
        original,
      );
    }
    return body0;
  }

  /// Validates and removes grouping separators from an integer part.
  /// Accepts both international (`1,234,567`) and lakh/crore (`1,25,000`)
  /// grouping, since both appear in real data. Rejects malformed groups.
  static String _stripGrouping(String intPart, String original, int scale) {
    if (intPart.isEmpty) return '';
    final separators = RegExp(r'[.,]');
    if (!separators.hasMatch(intPart)) return intPart;

    final parts = intPart.split(separators);
    for (var i = 0; i < parts.length; i++) {
      if (parts[i].isEmpty) {
        throw FormatException('empty digit group in "$original"', original);
      }
      if (!_allDigits(parts[i])) {
        throw FormatException('non-digit in amount "$original"', original);
      }
      if (parts[i].length > 3) {
        throw FormatException('malformed digit group "${parts[i]}" in "$original"', original);
      }
    }
    if (parts.length > 1 && parts.last.length != 3) {
      // "1,25" or "12,3" — not a valid grouping, and not a decimal we accepted.
      throw FormatException('malformed digit grouping in "$original"', original);
    }
    return parts.join();
  }

  // ── arithmetic (scale-checked, overflow-checked) ─────────────────────────

  MoneyMinor operator +(MoneyMinor other) {
    _sameScale(other);
    return MoneyMinor.fromMinor(guardedAdd(minor, other.minor, scale), scale);
  }

  MoneyMinor operator -(MoneyMinor other) {
    _sameScale(other);
    return MoneyMinor.fromMinor(guardedSub(minor, other.minor, scale), scale);
  }

  MoneyMinor operator -() => MoneyMinor.fromMinor(guardedNegate(minor, scale), scale);

  /// Multiply by a whole number (quantities, counts, instalments).
  MoneyMinor times(int factor) =>
      MoneyMinor.fromMinor(guardedMul(minor, factor, scale), scale);

  MoneyMinor abs() => minor < 0 ? -this : this;

  MoneyMinor negate() => -this;

  bool get isZero => minor == 0;
  bool get isPositive => minor > 0;
  bool get isNegative => minor < 0;
  int get sign => minor.sign;

  /// `total.percent(1800)` → 18.00 %. Integer math with explicit rounding.
  MoneyMinor percent(int basisPoints, {RoundingMode mode = RoundingMode.halfUp}) =>
      MoneyMinor.fromMinor(
          divRound(guardedMul(minor, basisPoints, scale), 10000, mode), scale);

  /// Multiply by a quantity expressed in thousandths (2.5 kg → 2500).
  MoneyMinor timesQuantityMilli(int quantityMilli,
          {RoundingMode mode = RoundingMode.halfUp}) =>
      MoneyMinor.fromMinor(
          divRound(guardedMul(minor, quantityMilli, scale), 1000, mode), scale);

  /// Convert using a rate in millionths (278.45 → 278450000).
  MoneyMinor convert(int rateMicros, {RoundingMode mode = RoundingMode.halfUp}) =>
      MoneyMinor.fromMinor(
          divRound(guardedMul(minor, rateMicros, scale), 1000000, mode), scale);

  /// Rescale between currencies with different exponents, rounding as needed.
  MoneyMinor rescale(int newScale, {RoundingMode mode = RoundingMode.halfUp}) {
    if (newScale == scale) return this;
    if (newScale > scale) {
      return MoneyMinor.fromMinor(
          guardedMul(minor, _pow10(newScale - scale), newScale), newScale);
    }
    return MoneyMinor.fromMinor(
        divRound(minor, _pow10(scale - newScale), mode), newScale);
  }

  /// Split this amount into [parts] pieces that **sum exactly to this amount**.
  ///
  /// This is the function that keeps instalment plans honest: Rs 1,000 split
  /// three ways gives 334 / 333 / 333, not three amounts of 333.33 that lose a
  /// paisa (the classic "why is my total 999.99?" bug). Remainders go to the
  /// earliest parts, which is what a customer expects on a receipt.
  List<MoneyMinor> splitEvenly(int parts) => allocate(List<int>.filled(parts, 1));

  /// Split proportionally to [weights], losing nothing (largest-remainder
  /// method — the same one used to apportion seats in elections, chosen here
  /// because it is deterministic and its error is provably < 1 minor unit).
  ///
  /// Negative amounts are split symmetrically: Rs -100 → [-34, -33, -33].
  List<MoneyMinor> allocate(List<int> weights) {
    if (weights.isEmpty) throw ArgumentError('allocate needs at least one weight');
    if (weights.any((w) => w < 0)) {
      throw ArgumentError('allocate weights must be non-negative');
    }
    final negativeAmount = minor < 0;
    final magnitude = minor.abs();
    final totalWeight = weights.fold<int>(0, (a, b) => a + b);

    // Degenerate case: everyone gets an equal share (largest remainder by index).
    final effective = totalWeight == 0 ? List<int>.filled(weights.length, 1) : weights;
    final effectiveTotal = totalWeight == 0 ? weights.length : totalWeight;

    final base = <int>[];
    final remainders = <int>[];
    var assigned = 0;
    for (final w in effective) {
      final exact = magnitude * w;
      final share = exact ~/ effectiveTotal;
      base.add(share);
      remainders.add(exact % effectiveTotal);
      assigned += share;
    }

    // Hand out the leftover minor units to the largest remainders, ties broken
    // by index so the result is identical on every device that runs it.
    var leftover = magnitude - assigned;
    final order = List<int>.generate(weights.length, (i) => i)
      ..sort((a, b) {
        final cmp = remainders[b].compareTo(remainders[a]);
        return cmp != 0 ? cmp : a.compareTo(b);
      });
    for (final i in order) {
      if (leftover <= 0) break;
      base[i]++;
      leftover--;
    }

    assert(base.fold<int>(0, (a, b) => a + b) == magnitude,
        'allocate must be lossless: ${base.fold<int>(0, (a, b) => a + b)} != $magnitude');
    return [
      for (final b in base) MoneyMinor.fromMinor(negativeAmount ? -b : b, scale),
    ];
  }

  /// Clamp into `[lower, upper]` (credit limits, stock reorder bounds).
  MoneyMinor clamp(MoneyMinor lower, MoneyMinor upper) {
    _sameScale(lower);
    _sameScale(upper);
    if (minor < lower.minor) return lower;
    if (minor > upper.minor) return upper;
    return this;
  }

  /// Sum, preserving exactness and refusing mixed scales.
  static MoneyMinor sum(Iterable<MoneyMinor> amounts, {int scale = 2}) {
    var total = 0;
    for (final a in amounts) {
      if (a.scale != scale) throw MoneyScaleMismatch(scale, a.scale);
      total = guardedAdd(total, a.minor, scale);
    }
    return MoneyMinor.fromMinor(total, scale);
  }

  /// SQL values are plain ints of minor units — this is the only conversion
  /// allowed to touch the database.
  int toSql() => minor;

  // ── formatting ──────────────────────────────────────────────────────────

  /// Render for display: `Rs 1,25,000.50`.
  ///
  /// [urduNumerals] switches to ۰۱۲۳۴۵۶۷۸۹ for the Urdu locale; [symbolText]
  /// overrides the currency label (`Rs`, `₨`, `PKR`).
  String format({
    String symbolText = 'Rs',
    bool showSymbol = true,
    GroupingPattern grouping = GroupingPattern.lakhCrore,
    bool urduNumerals = false,
    bool alwaysShowScale = true,
    String decimalSeparator = '.',
  }) {
    final negative = minor < 0;
    final magnitude = minor.abs();
    final unit = magnitude ~/ _pow10(scale);
    final fraction = magnitude % _pow10(scale);

    var digits = unit.toString();
    if (grouping == GroupingPattern.lakhCrore && digits.length > 3) {
      final tail = digits.substring(digits.length - 3);
      var head = digits.substring(0, digits.length - 3);
      final groups = <String>[];
      while (head.length > 2) {
        groups.insert(0, head.substring(head.length - 2));
        head = head.substring(0, head.length - 2);
      }
      if (head.isNotEmpty) groups.insert(0, head);
      digits = '${groups.join(',')},$tail';
    } else if (grouping == GroupingPattern.international && digits.length > 3) {
      final groups = <String>[];
      var head = digits;
      while (head.length > 3) {
        groups.insert(0, head.substring(head.length - 3));
        head = head.substring(0, head.length - 3);
      }
      if (head.isNotEmpty) groups.insert(0, head);
      digits = groups.join(',');
    }

    final buffer = StringBuffer();
    if (negative) buffer.write('-');
    if (showSymbol) buffer..write(symbolText)..write('\u00A0');
    buffer.write(digits);
    if (scale > 0 && (alwaysShowScale || fraction != 0)) {
      buffer..write(decimalSeparator)..write(fraction.toString().padLeft(scale, '0'));
    }
    var out = buffer.toString();
    if (urduNumerals) out = _toUrduNumerals(out);
    return out;
  }

  /// Machine-readable, ungrouped: `125000.50`. For CSV, QR payloads and PDF
  /// text that must round-trip through [parse].
  String toPlainString({String decimalSeparator = '.', bool urduNumerals = false}) {
    final negative = minor < 0;
    final magnitude = minor.abs();
    final unit = magnitude ~/ _pow10(scale);
    final fraction = magnitude % _pow10(scale);
    var out = '${negative ? '-' : ''}$unit';
    if (scale > 0) out = '$out$decimalSeparator${fraction.toString().padLeft(scale, '0')}';
    return urduNumerals ? _toUrduNumerals(out) : out;
  }

  /// For logging and error messages only — never for display or arithmetic.
  @override
  String toString() => '$minor minor (scale $scale)';

  @override
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  // A value type: every field is final and instances are compared by
  // value. The class stays free of package imports so it can run in a
  // bare Dart process (see tool/crdt_verify.dart).
  bool operator ==(Object other) =>
      other is MoneyMinor && other.minor == minor && other.scale == scale;

  @override
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  // A value type: every field is final and instances are compared by
  // value. The class stays free of package imports so it can run in a
  // bare Dart process (see tool/crdt_verify.dart).
  int get hashCode => Object.hash(minor, scale);

  @override
  int compareTo(MoneyMinor other) {
    _sameScale(other);
    return minor.compareTo(other.minor);
  }

  bool operator <(MoneyMinor other) => compareTo(other) < 0;
  bool operator <=(MoneyMinor other) => compareTo(other) <= 0;
  bool operator >(MoneyMinor other) => compareTo(other) > 0;
  bool operator >=(MoneyMinor other) => compareTo(other) >= 0;

  // ── JSON (used by the sync transport and backup packs) ───────────────────

  /// Wire format is a plain integer; scale travels with the ledger or currency
  /// row, not with every amount, because embedding it would bloat the oplog.
  int toJson() => minor;

  static MoneyMinor fromJson(Object? type, int scale) {
    if (type is! int) throw FormatException('money must be an integer, got ${type.runtimeType}');
    return MoneyMinor.fromMinor(type, scale);
  }

  // ── internals ───────────────────────────────────────────────────────────

  void _sameScale(MoneyMinor other) {
    if (other.scale != scale) throw MoneyScaleMismatch(scale, other.scale);
  }

  /// Guard the SQLite INTEGER boundary explicitly. Without this, Dart would
  /// silently wrap on overflow (or, worse, `int` becomes a double in JS
  /// targets) and an absurd entry would corrupt a balance rather than fail.
  static int guardOverflow(int value, int scale) {
    // NOTE: this can only validate an already-computed value, so it is used
    // for parsed/imported input — never after arithmetic. Dart's `int` wraps
    // silently on overflow, so `maxMinor * 2` evaluates to `-2`, which *passes*
    // a range check. Arithmetic therefore goes through guardedAdd /
    // guardedSub / guardedMul, which detect the overflow *before* it happens.
    if (value > maxMinor || value < minMinor) {
      throw MoneyOverflowException(value: value, scale: scale);
    }
    return value;
  }

  /// `a + b` with overflow detected before the machine add.
  ///
  /// Fast path: |a|,|b| ≤ 2^52 guarantees |sum| ≤ 2^53, far inside the 64-bit
  /// range, so the check is two integer comparisons. Values beyond that (never
  /// seen in a real ledger — 2^52 paise is Rs 45 trillion) fall through to an
  /// exact BigInt comparison.
  static int guardedAdd(int a, int b, int scale) {
    const safeBound = 1 << 52;
    if (_withinSafe(a, safeBound) && _withinSafe(b, safeBound)) return a + b;
    final exact = BigInt.from(a) + BigInt.from(b);
    if (exact > BigInt.from(maxMinor) || exact < BigInt.from(minMinor)) {
      throw MoneyOverflowException(value: a, scale: scale);
    }
    return exact.toInt();
  }

  /// `a - b` with overflow detected before the machine subtract.
  static int guardedSub(int a, int b, int scale) {
    const safeBound = 1 << 52;
    if (_withinSafe(a, safeBound) && _withinSafe(b, safeBound)) return a - b;
    final exact = BigInt.from(a) - BigInt.from(b);
    if (exact > BigInt.from(maxMinor) || exact < BigInt.from(minMinor)) {
      throw MoneyOverflowException(value: a, scale: scale);
    }
    return exact.toInt();
  }

  /// `a * b` with overflow detected before the machine multiply.
  /// The fast bound is 2^31 squared = 2^62, still inside the signed range.
  static int guardedMul(int a, int b, int scale) {
    if (a == 0 || b == 0) return 0;
    const safeBound = 1 << 31;
    if (_withinSafe(a, safeBound) && _withinSafe(b, safeBound)) return a * b;
    final exact = BigInt.from(a) * BigInt.from(b);
    if (exact > BigInt.from(maxMinor) || exact < BigInt.from(minMinor)) {
      throw MoneyOverflowException(value: a, scale: scale);
    }
    return exact.toInt();
  }

  /// Negation, which also has one unrepresentable input.
  static int guardedNegate(int value, int scale) {
    if (value == minMinor) throw MoneyOverflowException(value: value, scale: scale);
    return -value;
  }

  /// True when |value| ≤ bound, computed without `int.abs()`.
  ///
  /// `(-9223372036854775808).abs()` returns a *negative* number (two's
  /// complement has no positive counterpart for the minimum), so an
  /// `abs() <= bound` test silently green-lights the machine-arithmetic fast
  /// path for the one input that overflows it. Caught by the BigInt property
  /// test in tool/crdt_verify.dart — kept as a named helper so the reason is
  /// not lost the next time someone "simplifies" the comparisons.
  static bool _withinSafe(int value, int bound) => value >= -bound && value <= bound;

  static int _pow10(int n) {
    var r = 1;
    for (var i = 0; i < n; i++) {
      r *= 10;
    }
    return r;
  }

  static bool _hasNonZeroDigit(String s) {
    for (final r in s.runes) {
      if (r != 0x30) return true;
    }
    return false;
  }

  static bool _allDigits(String s) {
    for (final r in s.runes) {
      if (r < 0x30 || r > 0x39) return false;
    }
    return s.isNotEmpty;
  }

  /// Map Urdu (۰-۹) and Arabic-Indic (٠-٩) digits to ASCII so every downstream
  /// rule (parsing, sorting, exporting) sees one alphabet.
  static String _normaliseDigits(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= 0x06F0 && rune <= 0x06F9) {
        buffer.writeCharCode(0x30 + (rune - 0x06F0)); // Urdu
      } else if (rune >= 0x0660 && rune <= 0x0669) {
        buffer.writeCharCode(0x30 + (rune - 0x0660)); // Arabic-Indic
      } else if (rune == 0x066B) {
        buffer.write('.'); // Arabic decimal separator
      } else if (rune == 0x066C) {
        buffer.write(','); // Arabic thousands separator
      } else if (rune == 0x066A) {
        buffer.write('%');
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static String _toUrduNumerals(String input) {
    final buffer = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= 0x30 && rune <= 0x39) {
        buffer.writeCharCode(0x06F0 + (rune - 0x30));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }
}

/// Integer division with an explicit, testable rounding mode.
///
/// Deliberately integer-only: `(a / b).round()` would introduce a double and
/// therefore a rounding cliff at 2^53 on large ledgers.
int divRound(int numerator, int denominator, RoundingMode mode) {
  if (denominator == 0) throw ArgumentError('division by zero');
  final negative = (numerator < 0) != (denominator < 0);
  final n = numerator.abs();
  final d = denominator.abs();
  final quotient = n ~/ d;
  final remainder = n % d;

  switch (mode) {
    case RoundingMode.truncate:
      return negative ? -quotient : quotient;
    case RoundingMode.ceiling:
      if (remainder == 0) return negative ? -quotient : quotient;
      return negative ? -(quotient + 1) : quotient + 1;
    case RoundingMode.halfUp:
      // Half away from zero: 2.345 → 2.35, -2.345 → -2.35.
      final rounded = (remainder * 2 >= d) ? quotient + 1 : quotient;
      return negative ? -rounded : rounded;
    case RoundingMode.halfEven:
      final twice = remainder * 2;
      var rounded = quotient;
      if (twice > d) {
        rounded = quotient + 1;
      } else if (twice == d) {
        rounded = quotient.isEven ? quotient : quotient + 1;
      }
      return negative ? -rounded : rounded;
  }
}
