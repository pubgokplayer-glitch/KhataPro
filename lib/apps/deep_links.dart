/// KhataPro · deep links: the addresses that arrive from outside the app.
///
/// A shopkeeper does not type a deep link. A deep link arrives because *something the app
/// sent* was tapped: an SMS reminder, a WhatsApp message, a shared invoice PDF's link, the
/// "open in KhataPro" button in a Drive backup notification. Every one of those is a
/// `Uri` that the operating system hands to the app, and the router has to turn it into a
/// screen — with the right party or the right bill already open, not the dashboard.
///
/// ## The shapes, and why they are parsed here and not in the router
///
/// There are three ways the same destination can arrive, and a router that only understands
/// one of them loses the others:
///
/// | arrival | example |
/// |---|---|
/// | custom scheme (SMS, WhatsApp, both platforms) | `khatapro://party/019a1b2c-…?name=…` |
/// | https link (universal link / app link) | `https://khatapro.app/party/019a1b2c-…` |
/// | a URL that escaped into a query parameter | `https://…/open?url=khatapro%3A%2F%2Fparty%2F…` |
///
/// That third one is not hypothetical: WhatsApp and some SMS clients wrap links they forward,
/// and a link that survives two hops *and* arrives percent-encoded still has to open the right
/// screen. So the parse is written once, as a pure function with no `BuildContext`, and
/// verified in the sweep (`tool/ui_verify.dart`). The router then only ever sees a plain
/// path — which is also what makes the routes testable without a widget tree.
///
/// ## What is not here
///
/// Nothing in this file sends anything. Building the *message* that carries a link is
/// `lib/ui/commands/reminders.dart`; the platform-side registration is the Android
/// `intent-filter` and the iOS `CFBundleURLTypes` added in the same batch. Keeping the three
/// apart is what lets the message text be tested for Urdu, the link for parsing, and the
/// manifest for the fact that the OS knows the scheme at all.
library;

/// The destinations the app answers to.
abstract final class KhataRoutes {
  static const String dashboard = '/';
  static const String parties = '/parties';
  static const String cash = '/cash';
  static const String bills = '/bills';
  static const String stock = '/stock';
  static const String staff = '/staff';
  static const String settings = '/settings';
  static const String scanJoin = '/join';

  /// One party's ledger. `partyId` is a UUIDv7, so the path is stable and shareable.
  static String partyLedger(String partyId) => '/party/$partyId';

  /// The bill book, with one document already open. A query parameter rather than a path
  /// segment: the bill book is a worklist, and "show me this bill" is a *view* of it — the
  /// back button should land on the list, not an empty stack.
  static String bill(String documentId) => '$bills?doc=$documentId';

  /// A LAN pairing invitation (the QR in the sync screen) carrying the pairing ticket.
  static String join(String ticket) => '$scanJoin?t=$ticket';
}

/// The custom scheme registered in `AndroidManifest.xml` and `Info.plist`.
const String khataScheme = 'khatapro';

/// The https host reserved for universal links. Nothing has to be deployed for the *custom
/// scheme* links to work; this is the fallback for when a link has to be clickable in a
/// browser or a chat client that strips unknown schemes.
const String khataLinkHost = 'khatapro.app';

/// A parsed deep link: where to go, and what to call it.
final class KhataDeepLink {
  const KhataDeepLink({
    required this.location,
    this.partyId,
    this.documentId,
    this.ticket,
    this.source,
  });

  /// A location `GoRouter` understands, e.g. `/party/019a1b2c-…`.
  final String location;

  /// Present for a party link. The screen uses it to name the party in the app bar before
  /// the row has loaded — the whole point of the link is that the user arrives at *Amjad's*
  /// ledger, and a title that says "Ledger" until the query lands is a wasted moment.
  final String? partyId;

  /// Present for a bill link.
  final String? documentId;

  /// Present for a pairing ticket.
  final String? ticket;

  /// The raw uri, kept for logging and for the "this link did not work" report.
  final String? source;

  @override
  String toString() => 'KhataDeepLink($location)';
}

/// Turns an incoming uri into a route, or `null` when the app should ignore it.
///
/// Returning `null` rather than a "not found" screen is deliberate: a link that belongs to
/// another app, or a malformed one, should leave the user exactly where they were. The router
/// only shows an error page for a link that *is* ours and cannot be resolved (a party id that
/// is not in this book), because that is a fact the user needs to know.
KhataDeepLink? parseDeepLink(Uri uri) {
  final direct = _parse(uri);
  if (direct != null) return direct;

  // The wrapper case: our scheme or host arrived inside a query parameter, percent-encoded,
  // possibly twice. Unwrap up to twice — enough for the real clients, and a bound rather
  // than a loop that can be made to spin.
  var candidate = uri;
  for (var depth = 0; depth < 2; depth += 1) {
    final nested = _nested(candidate);
    if (nested == null) break;
    final parsed = _parse(nested);
    if (parsed != null) return parsed;
    candidate = nested;
  }
  return null;
}

/// The single-level parse: scheme form, https form, and the bare path form.
KhataDeepLink? _parse(Uri uri) {
  final isOurs = uri.scheme == khataScheme ||
      (uri.scheme == 'https' && uri.host == khataLinkHost) ||
      // `flutter_deeplinking_enabled` on Android hands over a path-only uri when the app is
      // already running, and an empty scheme then means "this app, this path".
      (uri.scheme.isEmpty && uri.pathSegments.isNotEmpty);
  if (!isOurs) return null;

  // `khatapro://party/<id>` puts the first segment in `host`; `https://host/party/<id>` does
  // not. Normalising here is what keeps the rest of the function from having two branches.
  final segments = <String>[
    if (uri.scheme == khataScheme && uri.host.isNotEmpty) uri.host,
    ...uri.pathSegments,
  ].where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;

  switch (segments.first) {
    case 'party':
      final id = segments.length > 1 ? segments[1] : uri.queryParameters['id'];
      if (id == null || id.isEmpty) return null;
      // The action rides along inside the location, because the location is the only thing
      // `GoRouter` keeps. A cold start navigates to the location and nothing else, so an action
      // left behind in the query would mean a "receive payment" notification opening a ledger
      // that then sits there doing nothing — which is the bug this line exists to prevent.
      final action = uri.queryParameters['action'];
      return KhataDeepLink(
        location: action == null || action.isEmpty
            ? KhataRoutes.partyLedger(id)
            : '${KhataRoutes.partyLedger(id)}?action=$action',
        partyId: id,
        source: uri.toString(),
      );

    case 'bill':
    case 'bills':
      final id = segments.length > 1 ? segments[1] : uri.queryParameters['doc'];
      if (id == null || id.isEmpty) {
        return KhataDeepLink(location: KhataRoutes.bills, source: uri.toString());
      }
      return KhataDeepLink(
        location: KhataRoutes.bill(id),
        documentId: id,
        source: uri.toString(),
      );

    case 'join':
      final ticket = uri.queryParameters['t'] ?? (segments.length > 1 ? segments[1] : null);
      if (ticket == null || ticket.isEmpty) return null;
      return KhataDeepLink(
        location: KhataRoutes.join(ticket),
        ticket: ticket,
        source: uri.toString(),
      );

    case 'cash':
      return KhataDeepLink(location: KhataRoutes.cash, source: uri.toString());
    case 'stock':
      return KhataDeepLink(location: KhataRoutes.stock, source: uri.toString());
    case 'staff':
      return KhataDeepLink(location: KhataRoutes.staff, source: uri.toString());
    case 'settings':
      return KhataDeepLink(location: KhataRoutes.settings, source: uri.toString());
    case 'parties':
      return KhataDeepLink(location: KhataRoutes.parties, source: uri.toString());
    case 'dashboard':
    case 'home':
      return KhataDeepLink(location: KhataRoutes.dashboard, source: uri.toString());
    default:
      return null;
  }
}

/// `.../open?url=<enc>` → the inner uri, when the wrapper is one of ours or a known
/// forwarder. `target` and `link` are what WhatsApp inserts when it rewrites a url.
Uri? _nested(Uri uri) {
  for (final key in const ['url', 'target', 'link', 'u']) {
    final value = uri.queryParameters[key];
    if (value == null || value.isEmpty) continue;
    final decoded = Uri.tryParse(value);
    if (decoded != null && (decoded.scheme.isNotEmpty || decoded.path.isNotEmpty)) {
      return decoded;
    }
  }
  return null;
}

/// The uri the app *emits*. Used by the reminder and the share sheet, so the link that leaves
/// the phone is built by the same code that parses it — the one way to be sure the two agree.
Uri buildPartyLink(String partyId) =>
    Uri.parse('$khataScheme://party/$partyId');

/// A bill link. `doc_no` travels as a query parameter so the shared link is readable by a
/// human ("this is about INV-0007") even when it is not tapped.
Uri buildBillLink({required String documentId, required String docNo}) =>
    Uri(scheme: khataScheme, host: 'bill', path: '/$documentId', queryParameters: {'no': docNo});
