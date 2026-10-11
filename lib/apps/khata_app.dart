/// KhataPro · the app root: one `ProviderScope`, one router, one place where a link lands.
///
/// ## Why the root owns the container
///
/// `databaseProvider` throws unless it is overridden, and it must be overridden with the
/// **one** database the boot path opened — a second connection re-runs SQLCipher's key
/// derivation (see `docs/DATA_LAYER.md` and the singleton in `database.dart`). So the
/// container is created here, once, immediately around the app, and the handle comes from the
/// boot result rather than from a lookup. Nothing deeper in the tree can open a database.
///
/// ## Why the router is built in `initState` and not in `build`
///
/// A `GoRouter` holds navigation state. Building it inside `build` would mint a new one on
/// every rebuild — losing the back stack on a theme change — so it is a `late final` field,
/// and the widget is stateful for exactly that reason.
///
/// ## Deep links, cold start and warm start
///
/// They arrive by two different routes, and handling only one is the classic bug:
///
/// * **Cold start** (the app was not running): the operating system passes the uri as the
///   platform's default route name, so it is read once in `initState` and used as the router's
///   `initialLocation`. A reminder tapped from an SMS opens the customer's ledger, not the
///   dashboard.
/// * **Warm start** (the app is in the background): the engine calls
///   `WidgetsBindingObserver.didPushRouteInformation`, which this widget implements and turns
///   into a `go`. Without it, tapping a second reminder while the app is open does nothing at
///   all — the most common deep-link bug there is.
///
/// The parse itself lives in `apps/deep_links.dart` as a pure function, so the shapes
/// (`khatapro://…`, an https app link, and a percent-encoded url inside a query parameter) are
/// verified in the sweep rather than by tapping a phone.
///
/// The native registration the platform needs — the Android `intent-filter`, the iOS
/// `CFBundleURLTypes`, and the `assetlinks.json` fingerprint for an app link — cannot be
/// patched into a workspace that has no `flutter create` output. `docs/DEEP_LINKS.md` has the
/// exact blocks to paste, with the reason each line is there.
library;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../data/db/database_init.dart';
import '../ui/screens/bill_book_screen.dart';
import '../ui/screens/cash_book_screen.dart';
import '../ui/screens/dashboard_screen.dart';
import '../ui/screens/party_ledger_screen.dart';
import '../ui/screens/party_list_screen.dart';
import '../ui/screens/settings_screen.dart';
import '../ui/screens/staff_book_screen.dart';
import '../ui/screens/stock_book_screen.dart';
import '../ui/format/strings.dart';
import '../ui/routes.dart';
import '../ui/state/providers.dart';
import '../ui/theme/theme.dart';
import '../ui/widgets/nav_shell.dart';
import 'deep_links.dart';

class KhataApp extends StatefulWidget {
  const KhataApp({super.key, required this.boot});

  /// The opened book. Everything the app can read or write comes from it.
  final KhataBoot boot;

  @override
  State<KhataApp> createState() => _KhataAppState();
}

class _KhataAppState extends State<KhataApp> with WidgetsBindingObserver {
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();
  late final GoRouter _router;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _router = GoRouter(
      navigatorKey: _navigatorKey,
      initialLocation: _initialLocation(),
      debugLogDiagnostics: false,
      routes: _routes(),
      // A uri that is ours but does not resolve — a party id from another phone's book, a bill
      // that has since been deleted — gets a sentence and a way home, not a blank screen.
      errorBuilder: (context, state) => _LinkNotice(uri: state.uri.toString()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _router.dispose();
    super.dispose();
  }

  /// The warm-start half. The engine hands over the uri the OS just delivered.
  @override
  Future<bool> didPushRouteInformation(RouteInformation routeInformation) async {
    final uri = Uri.tryParse(routeInformation.uri.toString());
    if (uri == null) return false;
    final link = parseDeepLink(uri);
    if (link != null) {
      _router.go(_locationFor(uri));
      return true;
    }
    return false;
  }

  /// The cold-start half: the OS's initial uri, parsed once.
  String _initialLocation() {
    final raw = WidgetsBinding.instance.platformDispatcher.defaultRouteName;
    final uri = Uri.tryParse(raw);
    if (uri == null || raw.isEmpty || raw == '/') return KhataRoutes.dashboard;
    return _locationFor(uri);
  }

  /// Where a uri lands. One mapping — [`routeFor`], in `ui/routes.dart` — for both the cold
  /// and the warm start, and the same one the sweep asserts against. A second copy here ("read
  /// the link's location") is the copy that would go stale the first time a route is renamed.
  String _locationFor(Uri uri) {
    final link = parseDeepLink(uri);
    if (link == null) return KhataRoutes.dashboard;
    return switch (routeFor(link)) {
      final GoScreen screen => screen.path,
      final String location => location,
      _ => KhataRoutes.dashboard,
    };
  }

  /// The action a party link carried, or `open` for a plain one. Read from the router's own
  /// uri rather than from the widget that received the link, because the location keeps the
  /// query through a go, a push and a cold start alike.
  LinkAction _actionOf(Uri uri) {
    final link = parseDeepLink(uri);
    return link == null ? LinkAction.open : actionOf(link);
  }

  List<RouteBase> _routes() => [
        GoRoute(
          path: KhataRoutes.dashboard,
          builder: (context, state) => AppShell(
            location: state.matchedLocation,
            child: const DashboardScreen(),
          ),
        ),
        GoRoute(
          path: KhataRoutes.parties,
          builder: (context, state) => AppShell(
            location: state.matchedLocation,
            child: PartyListScreen(
              // `?kind=1` is the supplier list, reachable from the bill book and from a
              // supplier's own row. Parsed defensively: a hand-typed link must not crash the
              // router, it must fall back to customers.
              kind: int.tryParse(state.uri.queryParameters['kind'] ?? '') ?? 0,
            ),
          ),
        ),
        GoRoute(
          path: KhataRoutes.cash,
          builder: (context, state) => AppShell(
            location: state.matchedLocation,
            child: const CashBookScreen(),
          ),
        ),
        GoRoute(
          path: KhataRoutes.bills,
          builder: (context, state) => AppShell(
            location: state.matchedLocation,
            child: BillBookScreen(documentId: state.uri.queryParameters['doc']),
          ),
        ),
        GoRoute(
          path: KhataRoutes.stock,
          builder: (context, state) => AppShell(
            location: state.matchedLocation,
            child: const StockBookScreen(),
          ),
        ),

        // Pushed screens: no shell, so the back gesture returns to the tab the user came from.
        GoRoute(
          path: '/party/:partyId',
          builder: (context, state) => PartyLedgerScreen(
            partyId: state.pathParameters['partyId'] ?? '',
            action: _actionOf(state.uri),
          ),
        ),
        GoRoute(
          path: KhataRoutes.settings,
          builder: (context, state) => SettingsScreen(
            // The custody notes are the boot path's own words about where the key lives
            // (`CustodyPlan.notes`). Repeating them here would be a second copy of a security
            // claim, and a security claim with two copies eventually has two versions.
            custodyNote: widget.boot.plan.notes.isEmpty ? null : widget.boot.plan.notes.first,
            nodeId: widget.boot.identity.nodeId,
            createdNow: widget.boot.createdNow,
            inviteTicket: state.uri.queryParameters['invite'],
          ),
        ),
        GoRoute(
          path: KhataRoutes.staff,
          builder: (context, state) => const StaffBookScreen(),
        ),

        // A pairing invitation: a ticket in the url, handed to the sync screen. The pairing
        // flow itself is D3's (`lib/sync/`); what a link can do is put the ticket in front of
        // the user on the screen that starts it.
        GoRoute(
          path: KhataRoutes.scanJoin,
          redirect: (context, state) =>
              '${KhataRoutes.settings}?invite=${state.uri.queryParameters['t'] ?? ''}',
        ),
      ];

  @override
  Widget build(BuildContext context) {
    // The scope is *inside* the app so that the language switch, which is a provider, can
    // rebuild the router's `MaterialApp` (locale) without re-creating the router itself.
    return ProviderScope(
      overrides: [databaseProvider.overrideWithValue(widget.boot.db)],
      child: _KhataMaterialApp(router: _router),
    );
  }
}

/// The `MaterialApp.router`, split out so the `ProviderScope` above it can be read from —
/// the locale comes from `displayPrefsProvider`, which lives inside that scope.
class _KhataMaterialApp extends ConsumerWidget {
  const _KhataMaterialApp({required this.router});

  final GoRouter router;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final (light, dark) = KhataTheme.pair();
    final language = ref.watch(displayPrefsProvider).language;

    return MaterialApp.router(
      title: 'KhataPro',
      debugShowCheckedModeBanner: false,
      theme: light,
      darkTheme: dark,
      themeMode: ThemeMode.system,
      routerConfig: router,
      // Urdu is not a translation of English here; it is a first language. The `locale` drives
      // Material's own strings and, more importantly, the text direction.
      locale: Locale(language.code),
      supportedLocales: const [Locale('en'), Locale('ur')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
    );
  }
}

/// What an unresolvable link gets: one sentence, and a button home.
class _LinkNotice extends StatelessWidget {
  const _LinkNotice({required this.uri});

  final String uri;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 40, color: colors.warning),
              const SizedBox(height: 16),
              Text(
                UiStrings(
                  ProviderScope.containerOf(context).read(displayPrefsProvider).language,
                ).linkNotInBook,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                uri,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: colors.onSurfaceMuted),
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () => context.go(KhataRoutes.dashboard),
                child: Text(
                  UiStrings(
                    ProviderScope.containerOf(context).read(displayPrefsProvider).language,
                  ).goToDashboard,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
