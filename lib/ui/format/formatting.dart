/// KhataPro · every number and date the UI shows, formatted in pure Dart.
///
/// A shopkeeper in Rahim Yar Khan reads `Rs 1,23,456.78`, not `123456.78`, and many
/// read `۱،۲۳،۴۵۶.۷۸` more comfortably than the western digits. Getting that wrong is
/// not a cosmetic problem: the whole point of a ledger is that a number can be checked
/// at a glance, and a mismatched convention costs a second of doubt on every row.
///
/// ## Why this is hand-written and not `intl`
///
/// `intl` is a dependency and a locale-data initialisation step, and it gets three
/// things about this market wrong by default: Pakistani business software groups in
/// **lakh/crore** (12,34,567), not thousands, Urdu digits are **Extended Arabic-Indic**
/// (۰۱۲۳۴۵۶۷۸۹ — not the Arabic ٠١٢٣٤٥٦٧٨٩ that a generic locale table gives), and
/// the ledger convention is `Dr`/`Cr` **after** the amount, not a minus sign before it.
/// All three are format decisions a shopkeeper will notice immediately.
///
/// Everything here is pure arithmetic over integers, so it is asserted in
/// `tool/ui_verify.dart` — including the properties that are easy to get subtly wrong:
/// lakh grouping on both sides of a fraction, negatives, exact-zero, and the epoch-day
/// arithmetic (no `DateTime` timezone can leak into a date column).
library;

import '../../core/utils/epoch_day.dart';

// ── digits ───────────────────────────────────────────────────────────────────

/// Which glyphs a number is drawn with.
enum DigitStyle {
  western,
  urdu;

  static const String _urduDigits = '۰۱۲۳۴۵۶۷۸۹';

  /// Maps the ASCII digits in [value] to this style. Everything else — currency
  /// symbols, separators, `Dr`/`Cr` — is left alone: those are not digits, and
  /// transliterating a comma produces a string nobody uses.
  String apply(String value) {
    if (this == DigitStyle.western) return value;
    final buffer = StringBuffer();
    for (final unit in value.codeUnits) {
      if (unit >= 0x30 && unit <= 0x39) {
        buffer.write(_urduDigits[unit - 0x30]);
      } else {
        buffer.writeCharCode(unit);
      }
    }
    return buffer.toString();
  }
}

// ── money ────────────────────────────────────────────────────────────────────

/// How digit groups are separated above a thousand.
enum GroupingStyle {
  /// 1,234,567 — international.
  western,

  /// 12,34,567 — lakh/crore, the convention in Pakistan and India. The last three
  /// digits are a group; every group above them is two digits.
  lakh;

  /// Inserts separators into a string of digits (no sign, no decimal point).
  String group(String digits) {
    if (digits.length <= 3) return digits;
    if (this == GroupingStyle.western) {
      final buffer = StringBuffer();
      var count = 0;
      for (var i = digits.length - 1; i >= 0; i--) {
        buffer.write(digits[i]);
        count += 1;
        if (count % 3 == 0 && i != 0) buffer.write(',');
      }
      return buffer.toString().split('').reversed.join();
    }
    // Lakh: last three, then pairs. 1234567 → 12,34,567
    final head = digits.substring(0, digits.length - 3);
    final tail = digits.substring(digits.length - 3);
    final groupedHead = StringBuffer();
    var count = 0;
    for (var i = head.length - 1; i >= 0; i--) {
      groupedHead.write(head[i]);
      count += 1;
      if (count.isEven && i != 0) groupedHead.write(',');
    }
    return '${groupedHead.toString().split('').reversed.join()},$tail';
  }
}

/// The ledger convention for a balance sign. Money in a khata is not "negative"; it is
/// a *credit* — the shopkeeper owes the other side — and every screen says so.
enum BalanceSide {
  debit('Dr'),
  credit('Cr'),
  zero('');

  const BalanceSide(this.label);

  final String label;

  /// In this schema a positive amount is a net debit (the party owes the business),
  /// which is why `net_minor > 0` reads as `Dr`.
  static BalanceSide of(int minorUnits) =>
      minorUnits > 0 ? debit : (minorUnits < 0 ? credit : zero);
}

/// Money in a given convention. Immutable and cheap; the app builds two of these at
/// startup (Urdu and English) rather than re-deriving per row.
final class MoneyFormat {
  const MoneyFormat({
    this.currencySymbol = 'Rs',
    this.decimals = 2,
    this.grouping = GroupingStyle.lakh,
    this.digits = DigitStyle.western,
    this.showSymbol = true,
  });

  final String currencySymbol;
  final int decimals;
  final GroupingStyle grouping;
  final DigitStyle digits;
  final bool showSymbol;

  MoneyFormat copyWith({
    String? currencySymbol,
    int? decimals,
    GroupingStyle? grouping,
    DigitStyle? digits,
    bool? showSymbol,
  }) =>
      MoneyFormat(
        currencySymbol: currencySymbol ?? this.currencySymbol,
        decimals: decimals ?? this.decimals,
        grouping: grouping ?? this.grouping,
        digits: digits ?? this.digits,
        showSymbol: showSymbol ?? this.showSymbol,
      );

  /// The absolute value, grouped and padded: `1,23,456.78`.
  String amount(int minorUnits) {
    final magnitude = minorUnits.abs();
    final scale = _pow10(decimals);
    final whole = (magnitude ~/ scale).toString();
    final fraction = decimals == 0 ? '' : '.${(magnitude % scale).toString().padLeft(decimals, '0')}';
    return digits.apply('${grouping.group(whole)}$fraction');
  }

  /// The signed amount, WITHOUT the currency symbol: `-1,23,456.78`.
  String signed(int minorUnits) =>
      minorUnits < 0 ? '-${amount(minorUnits)}' : amount(minorUnits);

  /// The full form: `Rs 1,23,456.78`. The minus goes outside the symbol so the number
  /// itself can be read left to right, which is how it is read aloud.
  String format(int minorUnits) {
    final body = signed(minorUnits);
    if (!showSymbol || currencySymbol.isEmpty) return body;
    return body.startsWith('-')
        ? '-$currencySymbol ${body.substring(1)}'
        : '$currencySymbol $body';
  }

  /// A balance with its side: `Rs 1,23,456.78 Dr`, `-Rs 4,500.00 Cr`, `Rs 0.00`.
  ///
  /// The sign stays where [format] puts it — outside the symbol — so the same amount
  /// does not change shape between the ledger list and the party list. And a zero
  /// balance carries no side at all: `Dr` on a settled account would invent a position
  /// that does not exist.
  String balance(int minorUnits) {
    final side = BalanceSide.of(minorUnits);
    final text = format(minorUnits);
    return side == BalanceSide.zero ? text : '$text ${side.label}';
  }

  /// A short form for axis labels and stat tiles, where eight digits will not fit:
  /// `45.0k`, `3.40L`, `1.20Cr` (lakh grouping) or `1.20M` (western).
  ///
  /// Deliberately lossy and deliberately obvious about it — a chart axis that reads
  /// `1.2Cr` is a scale marker, and the exact figure is one tap away.
  String compact(int minorUnits) {
    final magnitude = minorUnits.abs();
    final (divisor, suffix) = switch (grouping) {
      GroupingStyle.lakh => magnitude >= _croreMinor
          ? (_croreMinor, 'Cr')
          : magnitude >= _lakhMinor
              ? (_lakhMinor, 'L')
              : magnitude >= _thousandMinor
                  ? (_thousandMinor, 'k')
                  : (1, ''),
      GroupingStyle.western => magnitude >= _millionMinor
          ? (_millionMinor, 'M')
          : magnitude >= _thousandMinor
              ? (_thousandMinor, 'k')
              : (1, ''),
    };
    if (suffix.isEmpty) return format(minorUnits);
    final scaled = magnitude / divisor;
    // One decimal below 10 (`1.2Cr`), two below 100 — enough to read a scale, not
    // enough to imply precision that a compact label does not have.
    final text = scaled >= 100
        ? scaled.toStringAsFixed(0)
        : scaled >= 10
            ? scaled.toStringAsFixed(1)
            : scaled.toStringAsFixed(2);
    final sign = minorUnits < 0 ? '-' : '';
    return digits.apply('$sign$text$suffix');
  }

  int get _thousandMinor => 1000 * _pow10(decimals);
  int get _lakhMinor => 100000 * _pow10(decimals);
  int get _croreMinor => 10000000 * _pow10(decimals);
  int get _millionMinor => 1000000 * _pow10(decimals);

  static int _pow10(int exponent) {
    var result = 1;
    for (var i = 0; i < exponent; i++) {
      result *= 10;
    }
    return result;
  }
}

/// `82%` — for the collection rate and other ratios. Percentages here are always
/// "part of whole" over non-negative money, and a zero whole is reported as `—`
/// rather than `0%`, because "we sold nothing" and "we collected nothing of what we
/// sold" are different facts.
abstract final class PercentFormat {
  static String of(int partMinor, int wholeMinor, {DigitStyle digits = DigitStyle.western}) {
    if (wholeMinor == 0) return '—';
    final ratio = (partMinor * 1000) ~/ wholeMinor; // tenths of a percent
    final whole = ratio ~/ 10;
    final tenth = ratio % 10;
    final text = tenth == 0 ? '$whole%' : '$whole.$tenth%';
    return digits.apply(text);
  }
}

// ── dates ────────────────────────────────────────────────────────────────────

/// Dates are `INTEGER` epoch days in this schema (see `docs/DB_SCHEMA.md`), which is
/// why nothing here builds a `DateTime`: a date column must not acquire a timezone on
/// its way to the screen.
abstract final class DateText {
  static const List<String> _monthsEn = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Urdu month names as they are written in Pakistan (not transliterations).
  static const List<String> _monthsUr = [
    'جنوری', 'فروری', 'مارچ', 'اپریل', 'مئی', 'جون',
    'جولائی', 'اگست', 'ستمبر', 'اکتوبر', 'نومبر', 'دسمبر',
  ];

  /// `11 Oct 2026` / `۱۱ اکتوبر ۲۰۲۶`.
  static String short(int epochDay, {DigitStyle digits = DigitStyle.western}) {
    final date = EpochDay.toDate(epochDay);
    final month = digits == DigitStyle.urdu
        ? _monthsUr[date.month - 1]
        : _monthsEn[date.month - 1];
    return digits.apply('${date.day} $month ${date.year}');
  }

  /// `11/10/2026` — the compact form for table cells, where the month name costs a
  /// column width the shopkeeper would rather spend on the amount.
  static String numeric(int epochDay, {DigitStyle digits = DigitStyle.western}) {
    final date = EpochDay.toDate(epochDay);
    return digits.apply(
      '${date.day.toString().padLeft(2, '0')}/'
      '${date.month.toString().padLeft(2, '0')}/${date.year}',
    );
  }

  /// `Today`, `Yesterday`, `3 days ago` — for the recency column, where the exact day
  /// matters less than how long it has been sitting there.
  static String relative(
    int epochDay, {
    required int today,
    DigitStyle digits = DigitStyle.western,
  }) {
    final days = EpochDay.daysBetween(epochDay, today);
    if (days == 0) return digits == DigitStyle.urdu ? 'آج' : 'Today';
    if (days == 1) return digits == DigitStyle.urdu ? 'کل' : 'Yesterday';
    if (days < 0) return 'in ${digits.apply('${-days}')} days';
    if (days < 30) {
      return digits == DigitStyle.urdu
          ? '${digits.apply('$days')} دن پہلے'
          : '$days days ago';
    }
    final months = days ~/ 30;
    if (months < 12) {
      return digits == DigitStyle.urdu
          ? '${digits.apply('$months')} ماہ پہلے'
          : '$months months ago';
    }
    return short(epochDay, digits: digits);
  }

  /// `11 Oct – 10 Nov 2026`, collapsing what can be collapsed. Period labels sit in a
  /// header that is already tight, and a repeated year is noise.
  static String range(int fromEpochDay, int toEpochDay, {DigitStyle digits = DigitStyle.western}) {
    final from = EpochDay.toDate(fromEpochDay);
    final to = EpochDay.toDate(toEpochDay);
    if (from.year == to.year && from.month == to.month) {
      return digits.apply('${from.day}–${to.day} ${_monthsEn[to.month - 1]} ${to.year}');
    }
    if (from.year == to.year) {
      return '${short(fromEpochDay, digits: digits)} – ${short(toEpochDay, digits: digits)}';
    }
    return '${short(fromEpochDay, digits: digits)} – ${short(toEpochDay, digits: digits)}';
  }
}
