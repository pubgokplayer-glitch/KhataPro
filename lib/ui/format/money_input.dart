/// KhataPro · money as the user types it, and back again.
///
/// The books only ever see integer minor units (`docs/DATA_LAYER.md`: no floats, ever). The
/// keyboard only ever produces a string. This file is the **only** place those two meet, and
/// it is pure Dart so the sweep can hammer it without a widget tree.
///
/// What it has to survive, from a real shop counter:
///
/// | typed | means |
/// |---|---|
/// | `1250` | 1 250 rupees |
/// | `12,500` | 12 500 rupees (international grouping) |
/// | `12,34,500` | 12 34 500 rupees (lakh grouping — the same number, different commas) |
/// | `۱۲۵۰۰` | Urdu digits, on a phone with an Urdu keyboard |
/// | `1250.50` | 1 250 rupees 50 paisa |
/// | `1250.5` | the same 50 paisa — one decimal place is half a rupee, not 5 paisa |
/// | `Rs 1,250` | the currency symbol pasted in with the number |
/// | `1 250` | a space as the group separator (some Urdu keyboards emit nbsp) |
/// | `` / `-` | nothing: null, never zero |
///
/// The last row matters. `parseAmountMinor('')` returning `0` is how a blank form becomes a
/// zero-rupee entry, and a zero-rupee entry is what the ledger gate refuses (`FIN-1`). The
/// parser refuses first — a form that says "enter an amount" is better than a save button
/// that explains an invariant code.
library;

import 'formatting.dart';

/// Parses what the user typed into minor units, or `null` if it is not a number.
///
/// Rejects rather than guesses: `12..5`, `1,2,3` (an impossible grouping), and `–500` all
/// return `null`, because the alternative is a silent 500-rupee debt invented by a typo.
int? parseAmountMinor(String raw, {GroupingStyle grouping = GroupingStyle.lakh}) {
  final normalised = normaliseDigits(raw).trim();
  if (normalised.isEmpty) return null;

  // Shed everything that is decoration rather than maths: the currency symbol, spaces
  // (including the no-break kinds an Urdu keyboard emits), and the group separators.
  var cleaned = normalised
      .replaceAll(RegExp(r'[a-zA-Z]'), '')
      .replaceAll('\u00a0', '')
      .replaceAll('\u202f', '')
      .replaceAll(RegExp(r'\s+'), '');
  final hasSeparators = cleaned.contains(',');
  cleaned = cleaned.replaceAll(',', '');
  if (cleaned.isEmpty) return null;

  // A minus sign is a *bookkeeping* sign, produced by the reversal machinery — never by the
  // keypad. Refusing it here means the only way to reach a negative entry is through the
  // code that records one deliberately.
  if (cleaned.startsWith('-') || cleaned.startsWith('+')) return null;

  // At most one decimal point, and at most two digits after it.
  final parts = cleaned.split('.');
  if (parts.length > 2) return null;
  final whole = parts[0];
  final fraction = parts.length == 2 ? parts[1] : '';
  if (fraction.length > 2) return null;
  if (whole.isEmpty && fraction.isEmpty) return null;

  final rupees = whole.isEmpty ? 0 : int.tryParse(whole);
  if (rupees == null) return null;
  if (fraction.isNotEmpty && int.tryParse(fraction) == null) return null;

  // `1250.5` is 50 paisa: pad, never truncate.
  final paisa = fraction.isEmpty ? 0 : int.parse(fraction.padRight(2, '0'));

  // The separator *shape* is checked after the digits, because a mangled grouping means a
  // mangled number far more often than it means a big one. `1,2,3` is not 123.
  if (hasSeparators && !_groupingIsPlausible(normalised, grouping)) return null;

  final minor = rupees * 100 + paisa;
  if (minor <= 0) return null;
  return minor;
}

/// Renders a minor-unit amount for editing: no currency symbol, no group separators, and a
/// decimal part only when there is one. This is what fills a field when an entry is edited —
/// `MoneyFormat` is for reading, this is for typing, and using one for the other is how a
/// field ends up containing `Rs 1,250.00` and refusing to save.
String amountForEditing(int minor, {DigitStyle digits = DigitStyle.western}) {
  final sign = minor < 0 ? '-' : '';
  final abs = minor.abs();
  final rupees = abs ~/ 100;
  final paisa = abs % 100;
  final text = paisa == 0 ? '$rupees' : '$rupees.${paisa.toString().padLeft(2, '0')}';
  return digits.apply('$sign$text');
}

/// Urdu/Arabic-Indic digits → ASCII. The reverse of `DigitStyle.apply`.
String normaliseDigits(String input) {
  const urdu = '۰۱۲۳۴۵۶۷۸۹';
  const arabic = '٠١٢٣٤٥٦٧٨٩';
  final buffer = StringBuffer();
  for (final rune in input.runes) {
    final char = String.fromCharCode(rune);
    final urduIndex = urdu.indexOf(char);
    if (urduIndex >= 0) {
      buffer.write(urduIndex);
      continue;
    }
    final arabicIndex = arabic.indexOf(char);
    if (arabicIndex >= 0) {
      buffer.write(arabicIndex);
      continue;
    }
    buffer.write(char);
  }
  return buffer.toString();
}

/// True when the commas sit where a real number puts them.
///
/// Both groupings are accepted regardless of the setting, because a shopkeeper whose app is
/// set to international will still paste a lakh-grouped number out of WhatsApp, and refusing
/// it would be pedantry with a support ticket attached. What is rejected is a grouping that
/// **cannot** be a number: `1,2,3`, `12,,34`, a leading comma, a group of four digits.
bool _groupingIsPlausible(String normalised, GroupingStyle grouping) {
  final integer = normalised.split('.').first.replaceAll(RegExp(r'[^0-9,]'), '');
  final groups = integer.split(',');
  if (groups.length < 2) return false;
  for (final group in groups) {
    if (group.isEmpty || int.tryParse(group) == null) return false;
  }

  final head = groups.first;
  if (head.length > 3 || (grouping == GroupingStyle.lakh && head.length > 2)) return false;

  final tail = groups.sublist(1);
  for (var i = 0; i < tail.length; i += 1) {
    final length = tail[i].length;
    if (i == tail.length - 1) {
      // The last group is always three digits — that is what grouping *is*.
      if (length != 3) return false;
      continue;
    }
    final expected = grouping == GroupingStyle.western ? 3 : 2;
    if (length != expected) return false;
  }
  return true;
}
