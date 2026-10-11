/// KhataPro · the app's own words, in the two languages it is actually used in.
///
/// There is deliberately **no ARB/`AppLocalizations` pipeline** here. The generated-strings
/// route needs `l10n.yaml`, an `assets/i18n/*.arb` set and a code-generation step, and the
/// project ships none of those (`assets/i18n/` holds a `.gitkeep` on purpose). What it needs
/// instead is *correct* — Urdu strings are not translations of English ones, they are the
/// words a shopkeeper in Rahim Yar Khan reads: `وصولی`, not "collection"; `بکیا`, not
/// "outstanding receivable".
///
/// So this is a single class of getters and a handful of count helpers, selected by
/// `DisplayPrefs.language`. It is not scalable to a language the team does not read, and
/// that is the honest shape for a two-language app: a translator can open one file and see
/// every sentence that will appear on a screen, in context, with the widgets that use it one
/// grep away.
///
/// ## Rules this file follows
///
/// * **Numbers come from `MoneyFormat`/`DateText`, never from here.** Urdu digits are a
///   formatting concern with a verified implementation; duplicating "۰۱۲۳۴۵۶۷۸۹" in a string
///   table is how the ledger and the dashboard end up disagreeing about the number 7.
/// * **A count is a method, not a `PluralFormat`.** Urdu's plural rules for these labels are
///   "one thing / more than one thing", which is two branches, not a framework.
/// * **Nothing here is a sentence built from a fragment.** Concatenating "Balance: " + "Rs 5"
///   in English and then translating the pieces produces Urdu that reads like a machine did
///   it, which is exactly what it would be.
library;

import '../state/providers.dart';

/// The screen strings for one language.
final class UiStrings {
  const UiStrings(this.language);

  final UiLanguage language;

  bool get isUrdu => language == UiLanguage.urdu;

  /// Picks the right string for a language without every call site writing a ternary.
  String _pick(String english, String urdu) => isUrdu ? urdu : english;

  // ── the app ──────────────────────────────────────────────────────────────

  String get appTitle => _pick('KhataPro', 'کھاتہ پرو');
  String get dashboard => _pick('Dashboard', 'ڈیش بورڈ');
  String get parties => _pick('Parties', 'پارٹیاں');
  String get cashBook => _pick('Cash Book', 'کیش بک');
  String get stockBook => _pick('Stock', 'اسٹاک');
  String get staffBook => _pick('Staff', 'عملہ');
  String get billBook => _pick('Bills', 'بل');
  String get settings => _pick('Settings', 'ترتیبات');

  // ── dashboard ────────────────────────────────────────────────────────────

  String get todaysSales => _pick("Today's sales", 'آج کی فروخت');
  String get thisMonthSales => _pick('This month', 'اس ماہ کی فروخت');
  String get thisMonthProfit => _pick('Profit this month', 'اس ماہ کا منافع');
  String get cashAndBank => _pick('Cash & bank', 'نقد اور بینک');
  String get receivables => _pick('Customers owe', 'گاہکوں سے لینا');
  String get payables => _pick('You owe suppliers', 'سپلائرز کو دینا');
  String get cashFlow => _pick('Cash movement', 'نقد کی آمد و رفت');
  String get topDebtors => _pick('Who to chase', 'کس سے وصولی کرنی ہے');
  String get noDebtors => _pick('Nobody owes you right now', 'ابھی کسی سے لینا نہیں');
  String get draftsWaiting => _pick('Unposted entries', 'غیر پوسٹ شدہ اندراجات');
  String get quickActions => _pick('New', 'نیا');

  // ── ledger ───────────────────────────────────────────────────────────────

  String entriesCount(int count) => isUrdu
      ? '${count == 1 ? 'ایک اندراج' : '$count اندراجات'}'
      : '$count ${count == 1 ? 'entry' : 'entries'}';
  String get noEntriesTitle => _pick('No entries yet', 'ابھی کوئی اندراج نہیں');
  String get customerBalance => _pick('Customer balance', 'گاہک کا بیلنس');
  String get supplierBalance => _pick('Supplier balance', 'سپلائر کا بیلنس');
  String get cashBalance => _pick('Cash balance', 'نقد بیلنس');
  String get recordPayment => _pick('Record payment', 'ادائیگی درج کریں');
  String get newSale => _pick('New sale', 'نئی فروخت');
  String get newInvoice => _pick('Credit sale (invoice)', 'اُدھار فروخت (بل)');
  String get newExpense => _pick('New expense', 'نیا خرچ');
  String get newReceipt => _pick('Money received', 'رقم موصول');
  String get newSupplierBill => _pick('New bill', 'نیا بل');
  String get postEntry => _pick('Save entry', 'اندراج محفوظ کریں');

  // ── forms ────────────────────────────────────────────────────────────────

  String get amount => _pick('Amount', 'رقم');
  String get date => _pick('Date', 'تاریخ');
  String get memo => _pick('Note', 'تفصیل');
  String get party => _pick('Party', 'پارٹی');
  String get chooseParty => _pick('Choose a party', 'پارٹی منتخب کریں');
  String get account => _pick('Account', 'کھاتہ');
  String get cashOrBank => _pick('Cash or bank', 'نقد یا بینک');
  String get paymentSource => _pick('Paid from', 'کہاں سے ادا کیا');
  String get cancel => _pick('Cancel', 'منسوخ');
  String get save => _pick('Save', 'محفوظ کریں');
  String get addParty => _pick('Add party', 'نئی پارٹی');
  String get name => _pick('Name', 'نام');
  String get nameUrdu => _pick('Name (Urdu)', 'نام (اردو)');
  String get phone => _pick('Phone', 'فون');
  String get customer => _pick('Customer', 'گاہک');
  String get supplier => _pick('Supplier', 'سپلائر');
  String get search => _pick('Search', 'تلاش');
  String get dueDate => _pick('Due date', 'ادائیگی کی تاریخ');

  // ── bills, stock, staff ──────────────────────────────────────────────────

  String get unpaid => _pick('Unpaid', 'واجب الادا');
  String get paid => _pick('Paid', 'ادا شدہ');
  String get overpaid => _pick('Advance', 'پیشگی');
  String get salesInvoices => _pick('Sales invoices', 'فروخت کے بل');
  String get purchaseBills => _pick('Supplier bills', 'خرید کے بل');
  String overdueDays(int days) => isUrdu
      ? (days == 1 ? 'ایک دن تاخیر' : '$days دن تاخیر')
      : '$days ${days == 1 ? 'day' : 'days'} overdue';
  String get notOverdue => _pick('On time', 'وقت پر');
  String get lowStockOnly => _pick('Low stock only', 'کم اسٹاک');
  String get inStock => _pick('In stock', 'اسٹاک میں');
  String get quantity => _pick('Quantity', 'مقدار');
  String get value => _pick('Value', 'مالیت');
  String get movements => _pick('Movements', 'آمد و رفت');
  String get noMovements => _pick('No movements for this item yet', 'اس آئٹم کی کوئی آمد و رفت نہیں');
  String get advance => _pick('Advance', 'پیشگی');
  String get salary => _pick('Salary', 'تنخواہ');

  // ── settings & status ────────────────────────────────────────────────────

  String get languageLabel => _pick('Language', 'زبان');
  String get englishLabel => 'English';
  String get urduLabel => 'اردو';
  String get digitGrouping => _pick('Number grouping', 'ہندسوں کی ترتیب');
  String get lakhCrore => _pick('Lakh / crore (12,34,567)', 'لاکھ / کروڑ (۱۲،۳۴،۵۶۷)');
  String get westernGrouping => _pick('International (1,234,567)', 'بین الاقوامی (۱،۲۳۴،۵۶۷)');
  String get security => _pick('Security', 'سیکیورٹی');
  String get syncHealth => _pick('Sync', 'ہم آہنگی');
  String get backup => _pick('Backup', 'بیک اپ');
  String get about => _pick('About this book', 'اس کھاتے کے بارے میں');
  String get noPeersYet => _pick('No phone has paired with this one yet', 'ابھی کوئی فون جڑا نہیں');
  String pendingChanges(int count) =>
      _pick('$count ${count == 1 ? 'change' : 'changes'} waiting to sync',
          '$count تبدیلیاں ہم آہنگی کا انتظار کر رہی ہیں');
  String get uptoDate => _pick('Everything is synced', 'سب کچھ ہم آہنگ ہے');
  String lastSynced(String relative) => _pick('Last synced $relative', 'آخری ہم آہنگی: $relative');
  String get neverSynced => _pick('Never synced', 'کبھی ہم آہنگ نہیں ہوا');
  String get noBackupYet => _pick('No verified backup yet', 'ابھی کوئی تصدیق شدہ بیک اپ نہیں');
  String backupAge(String relative) => _pick('Last backup $relative', 'آخری بیک اپ: $relative');
  String get custodyNote =>
      _pick('The database key is held by this device.', 'ڈیٹا بیس کی چابی اسی ڈیوائس میں ہے۔');
  String get thisDevice => _pick('This device', 'یہ ڈیوائس');
  String get bookOpened => _pick('Book opened', 'کھاتہ کھلا');
  String get createdToday => _pick('This is a new book', 'یہ نیا کھاتہ ہے');
  String entriesWalked(int count) => _pick('$count entries in this book', 'اس کھاتے میں $count اندراجات');
  String get conflictsTitle => _pick('Merged changes', 'ضم شدہ تبدیلیاں');
  String get noConflicts => _pick('No conflicts to review', 'کوئی تنازع نہیں');
  String get checkBooks => _pick('Check my books', 'کھاتے کی جانچ کریں');
  String get rebuildCaches => _pick('Rebuild totals', 'ٹوٹل دوبارہ بنائیں');
  String get done => _pick('Done', 'مکمل');
}
