/// KhataPro · the messages the shop sends out: payment reminders and shared invoices.
///
/// Three things live here, and they are all pure functions on purpose — the sweep runs them
/// without a phone (`tool/ui_verify.dart`), which is the only way to be sure the Urdu a
/// customer reads is the Urdu the app thinks it is sending.
///
/// 1. **The message** ([buildReminder], [buildInvoiceMessage]). Written in the shopkeeper's
///    language, not the customer's — the shopkeeper is the one sending it, and a message in
///    the wrong script reads like a machine and gets ignored.
/// 2. **The link** (`lib/apps/deep_links.dart`) — so the customer taps through to the ledger.
/// 3. **The uri** ([smsUri], [whatsAppUri]) — the transport. This project has **no plugin**
///    for either: `url_launcher`/`share_plus` are paid-for conveniences this app does not
///    need, and the platform side already has `SecurityChannels` for the cases that do. The
///    sms: and https://wa.me uris are handed to the platform's own handler, which is both
///    cheaper and less to go wrong. (A `Clipboard` fallback is the honest path when no
///    handler is installed — `lib/ui/widgets/reminder_sheet.dart` does exactly that.)
///
/// ## The one rule about the text
///
/// **Never compose a sentence out of translated fragments.** "You owe " + "Rs 12,500" + " to "
/// + name produces Urdu in English word order, which is the single most common way an app
/// reads as foreign. Every message below is a whole sentence with the values folded in,
/// written twice, in the shape each language actually uses.
library;

import '../../apps/deep_links.dart';
import '../format/formatting.dart';
import '../state/providers.dart';

/// A reminder about money a customer still owes.
///
/// [daysOverdue] is optional because a shopkeeper frequently wants to remind someone whose
/// bill is not late yet — "the bill is 20 days old, he always pays this week" is a legitimate
/// reason to nudge, and the message should not call him late when he is not.
String buildReminder({
  required String partyName,
  required int balanceMinor,
  required MoneyFormat money,
  required String link,
  required UiLanguage language,
  int? daysOverdue,
}) {
  final amount = money.balance(balanceMinor);
  final urdu = language == UiLanguage.urdu;

  if (urdu) {
    final late = daysOverdue == null || daysOverdue <= 0
        ? ''
        : (daysOverdue == 1 ? '\nیہ بل ایک دن سے باقی ہے۔' : '\nیہ بل $daysOverdue دن سے باقی ہے۔');
    return 'السلام علیکم $partyName،\n'
        'آپ کے کھاتے میں $amount باقی ہے۔$late\n'
        'تفصیل یہاں دیکھیں: $link\n'
        'شکریہ — کھاتہ پرو';
  }

  final late = daysOverdue == null || daysOverdue <= 0
      ? ''
      : daysOverdue == 1
          ? '\nThis bill has been open for a day.'
          : '\nThis bill has been open for $daysOverdue days.';
  return 'Assalam-o-Alaikum $partyName,\n'
      'Your account shows $amount outstanding.$late\n'
      'You can see the details here: $link\n'
      'Thank you — KhataPro';
}

/// The message that travels with a bill: the number, the amount, what is still owed, and a
/// link that opens *that* bill inside the app.
String buildInvoiceMessage({
  required String partyName,
  required String docNo,
  required int totalMinor,
  required int balanceMinor,
  required MoneyFormat money,
  required int docDate,
  required String link,
  required UiLanguage language,
}) {
  final total = money.format(totalMinor);
  final due = money.balance(balanceMinor);
  final date = DateText.short(docDate, digits: money.digits);
  final urdu = language == UiLanguage.urdu;

  if (urdu) {
    final settled = balanceMinor == 0 ? '\nادائیگی مکمل ہے۔' : '\nباقی: $due';
    return '$partyName کے لیے بل $docNo ($date)\n'
        'کل رقم: $total$settled\n'
        'بل دیکھیں: $link';
  }

  final settled = balanceMinor == 0 ? '\nPaid in full.' : '\nBalance: $due';
  return 'Bill $docNo for $partyName ($date)\n'
      'Total: $total$settled\n'
      'Open the bill: $link';
}

/// A party's pending balance, as a link.
String partyLinkFor(String partyId) => buildPartyLink(partyId).toString();

/// `sms:+923001234567?body=…`.
///
/// The `+` is not optional on Android: without it the platform treats the number as a local
/// one and the message silently fails to send on a phone travelling abroad. iOS wants `&body=`
/// instead of `?body=`, and the difference is absorbed by [smsUri] using `&` when the uri
/// already has a query — which is what `Uri` does for us.
Uri smsUri({required String phone, required String body}) =>
    Uri(scheme: 'sms', path: normalisePhone(phone), queryParameters: {'body': body});

/// `https://wa.me/923001234567?text=…`.
///
/// `wa.me` (not `api.whatsapp.com/send`) because the short form is what the Android and iOS
/// apps both claim without a redirect hop, and a redirect in a chat client's in-app browser
/// is where taps get lost.
Uri whatsAppUri({required String phone, required String body}) =>
    Uri.parse('https://wa.me/${normalisePhone(phone).replaceAll('+', '')}'
        '?text=${Uri.encodeComponent(body)}');

/// A Pakistani phone number as E.164, from whatever the shopkeeper typed.
///
/// Shopkeepers type `0300-1234567`, `03001234567`, `+92 300 1234567`, `0092 300 1234567`, or
/// — from a customer's WhatsApp profile — `923001234567`. All five are the same phone, and a
/// reminder that fails because of a dash is a reminder the shopkeeper will not send twice.
/// Anything that does not look like a number is returned digits-only rather than guessed at:
/// a wrong `+92` prefix would send a stranger a message about someone else's debt.
String normalisePhone(String raw) {
  var digits = raw.replaceAll(RegExp(r'[^0-9+]'), '');
  if (digits.startsWith('+92')) return digits;
  if (digits.startsWith('0092')) return '+${digits.substring(2)}';
  if (digits.startsWith('92') && digits.length >= 12) return '+$digits';
  if (digits.startsWith('0') && digits.length >= 10) return '+92${digits.substring(1)}';
  if (digits.startsWith('+')) return digits;
  return digits.length >= 10 ? '+92$digits' : digits;
}

/// True when a phone number is plausible enough to offer "send a reminder" for. Used by the
/// screens to *hide* the button rather than show one that cannot work.
bool isDialablePhone(String? phone) =>
    phone != null && normalisePhone(phone).replaceAll('+', '').length >= 10;
