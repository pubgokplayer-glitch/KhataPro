/// KhataPro · calendar-day arithmetic that matches how shops think.
///
/// The schema stores dates as **epoch-days**: days since 1970-01-01, in the
/// ledger's local calendar. Two consequences worth stating plainly:
///
///   · A sale rung up at 23:40 on the 30th in Karachi belongs to the 30th. It
///     must never "move" to the 31st because a UTC-based serializer said so.
///     Storing a *day* rather than an *instant* makes that impossible.
///   · Epoch-days are integers, so `entry_date BETWEEN ? AND ?` is an index
///     range scan, month arithmetic is subtraction, and no timezone parsing
///     happens inside the query planner.
///
/// The conversion uses Howard Hinnant's `days_from_civil` algorithm — pure
/// integer math, valid for any proleptic Gregorian year, with no dependence on
/// `DateTime`'s platform behaviour or on the system timezone database.
///
/// Pure Dart, no `package:` imports.
library;

/// Conversion helpers between calendar dates and epoch-days.
abstract final class EpochDay {
  /// Days from 1970-01-01 to 0000-03-01, the offset baked into the algorithm.
  static const int _daysToEpoch = 719468;

  /// Build an epoch-day from calendar components (proleptic Gregorian).
  static int fromDate(int year, int month, int day) {
    var y = year;
    // Shift the year so that March is month 0, which puts the leap day at the
    // end of the cycle and removes all special-casing.
    y -= month <= 2 ? 1 : 0;
    final era = (y >= 0 ? y : y - 399) ~/ 400;
    final yearOfEra = y - era * 400;                                   // 0..399
    final monthShifted = (month + 9) % 12;                             // Mar = 0
    final dayOfYear = (153 * monthShifted + 2) ~/ 5 + day - 1;         // 0..365
    final dayOfEra = yearOfEra * 365 + yearOfEra ~/ 4 - yearOfEra ~/ 100 + dayOfYear;
    return era * 146097 + dayOfEra - _daysToEpoch;
  }

  /// Extract calendar components back out of an epoch-day.
  static ({int year, int month, int day}) toDate(int epochDay) {
    final shifted = epochDay + _daysToEpoch;
    final era = (shifted >= 0 ? shifted : shifted - 146096) ~/ 146097;
    final dayOfEra = shifted - era * 146097;                           // 0..146096
    final yearOfEra = (dayOfEra - dayOfEra ~/ 1460 + dayOfEra ~/ 36524 - dayOfEra ~/ 146096) ~/ 365;
    final y = yearOfEra + era * 400;
    final dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra ~/ 4 - yearOfEra ~/ 100);
    final mp = (5 * dayOfYear + 2) ~/ 153;                             // Mar = 0
    final day = dayOfYear - (153 * mp + 2) ~/ 5 + 1;
    final month = mp + (mp < 10 ? 3 : -9);
    return (year: y + (month <= 2 ? 1 : 0), month: month, day: day);
  }

  /// The epoch-day of a [DateTime], read in **its own** zone fields.
  ///
  /// Callers pass a DateTime already expressed in the ledger's timezone (for a
  /// normal single-timezone shop, that is simply `DateTime.now()`). We read
  /// `.year/.month/.day` rather than `.toUtc()` on purpose: the user's wall
  /// calendar is the authority for which day a transaction belongs to.
  static int fromDateTime(DateTime dateTime) =>
      fromDate(dateTime.year, dateTime.month, dateTime.day);

  /// Today, in the ledger's local time.
  ///
  /// [utcOffset] converts to a ledger whose timezone differs from the device's
  /// (a Karachi shop reviewing a Dubai branch, say). When the offset is zero we
  /// use the device's own zone, which is the common case and avoids depending
  /// on a timezone database for the app's most common query.
  static int today({Duration utcOffset = Duration.zero}) {
    final now = utcOffset == Duration.zero
        ? DateTime.now()
        : DateTime.now().toUtc().add(utcOffset);
    return fromDateTime(now);
  }

  /// Local midnight of an epoch-day, in the device's current zone (for display
  /// and for handing to date pickers).
  static DateTime toLocalMidnight(int epochDay) {
    final date = toDate(epochDay);
    return DateTime(date.year, date.month, date.day);
  }

  /// `2026-10-11`, the format the database itself produces via
  /// `date(julianday('1970-01-01') + ?)` — so ISO images and hand-written SQL
  /// agree byte for byte.
  static String toIso(int epochDay) {
    final date = toDate(epochDay);
    final mm = date.month.toString().padLeft(2, '0');
    final dd = date.day.toString().padLeft(2, '0');
    final yyyy = date.year.toString().padLeft(4, '0');
    return '$yyyy-$mm-$dd';
  }

  /// Parse `YYYY-MM-DD` (or `D/M/YYYY`, `DD-MM-YYYY` as users type them).
  /// Returns null when the input is not a date — callers decide whether that is
  /// an error or an empty field.
  static int? tryParse(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return null;

    final iso = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(trimmed);
    if (iso != null) {
      return _validated(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!));
    }
    final local = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{4})$').firstMatch(trimmed);
    if (local != null) {
      // Day-first: what a Pakistani keyboard produces (d/M/y is the stored
      // preference in app_settings: ui.date_format).
      return _validated(int.parse(local[3]!), int.parse(local[2]!), int.parse(local[1]!));
    }
    return null;
  }

  static int? _validated(int year, int month, int day) {
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    final epochDay = fromDate(year, month, day);
    final back = toDate(epochDay);
    // Rejects 31 Feb and friends: the round-trip changes the day.
    if (back.year != year || back.month != month || back.day != day) return null;
    return epochDay;
  }

  static int addDays(int epochDay, int days) => epochDay + days;

  static int daysBetween(int from, int to) => to - from;

  /// 1 = Monday … 7 = Sunday (ISO-8601). 1970-01-01 was a Thursday (=4).
  static int isoWeekday(int epochDay) {
    final remainder = (epochDay + 3) % 7;
    return (remainder < 0 ? remainder + 7 : remainder) + 1;
  }

  /// 0 = Sunday … 6 = Saturday — the JS/POSIX convention some pickers want.
  static int weekdaySunFirst(int epochDay) => isoWeekday(epochDay) % 7;

  static int startOfMonth(int epochDay) {
    final date = toDate(epochDay);
    return fromDate(date.year, date.month, 1);
  }

  static int endOfMonth(int epochDay) {
    final date = toDate(epochDay);
    final lastDay = DateTime(date.year, date.month + 1, 0).day; // day 0 of next month
    return fromDate(date.year, date.month, lastDay);
  }

  static int startOfYear(int epochDay) => fromDate(toDate(epochDay).year, 1, 1);

  static int endOfYear(int epochDay) => fromDate(toDate(epochDay).year, 12, 31);

  /// First day of the fiscal year containing [epochDay].
  ///
  /// Pakistan's fiscal year runs 1 July → 30 June, which is why
  /// `ledgers.fiscal_year_start_month` defaults to 7. Getting this wrong is
  /// how a business ends up filing against the wrong year, so it lives in one
  /// tested function rather than in a report query.
  static int fiscalYearStart(int epochDay, int startMonth) {
    if (startMonth < 1 || startMonth > 12) {
      throw ArgumentError.value(startMonth, 'startMonth', 'must be 1..12');
    }
    final date = toDate(epochDay);
    final year = date.month >= startMonth ? date.year : date.year - 1;
    return fromDate(year, startMonth, 1);
  }

  /// Fiscal-year *end*, inclusive — the day before the next fiscal year starts.
  /// (FY2026 in Pakistan = 2026-07-01 … 2027-06-30.)
  static int fiscalYearEndInclusive(int epochDay, int startMonth) {
    if (startMonth < 1 || startMonth > 12) {
      throw ArgumentError.value(startMonth, 'startMonth', 'must be 1..12');
    }
    final start = fiscalYearStart(epochDay, startMonth);
    final date = toDate(start);
    return addDays(fromDate(date.year + 1, startMonth, 1), -1);
  }

  /// True when the two days fall in the same month.
  static bool sameMonth(int a, int b) => startOfMonth(a) == startOfMonth(b);

  /// Human label used in list group headers: `Oct 2026`.
  static String monthLabel(int epochDay, {bool short = true}) {
    const names = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    final date = toDate(epochDay);
    final name = names[date.month - 1];
    return short ? '${name.substring(0, 3)} ${date.year}' : '$name ${date.year}';
  }

  /// Sanity bound used when validating imported data and peer payloads:
  /// nothing legitimate is dated before 1990 or after ~200 years from now.
  static bool isPlausible(int epochDay, {int? referenceDay}) {
    final reference = referenceDay ?? today();
    return epochDay >= 7305 && epochDay <= reference + 365 * 200;
  }
}
