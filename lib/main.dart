/// KhataPro — the entry point. Four lines of code and the reasons they are these four.
///
/// ## 1. `ensureInitialized()` before anything touches a plugin
///
/// The first thing the app does is open an encrypted database whose key comes from the Android
/// Keystore / iOS Secure Enclave, over a `MethodChannel`. A channel call made before the
/// binding exists throws — and it throws *inside* `main`, which is the worst place for an error
/// to land because there is no widget tree to show it in. So the binding comes first.
///
/// ## 2. No `await` here, and no `FutureBuilder` in `main`
///
/// The database open takes ~1.5 s of Argon2id on a mid-range phone plus the keystore round trip
/// and 11 migrations. Doing that before `runApp` would show the platform's white splash for the
/// whole time — no brand, no explanation. `KhataBootstrap` owns the future instead, renders
/// [BootSplash]/[BiometricGate] while it runs, and builds the app only once a real handle
/// exists. A failed boot therefore never produces a `ProviderScope` at all, so no screen can
/// query a half-open book (see `lib/apps/bootstrap.dart`).
///
/// ## 3. `KhataApp` is where the deep link is read
///
/// The bootstrap hands over a plain `KhataBoot` — the database, the device identity, the custody
/// plan. The router, the initial location from the operating system's uri, and the warm-start
/// observer all belong to the app widget. Splitting them this way is what lets the whole boot
/// path be driven in a test with a temp directory and a fake security transport.
///
/// ## 4. What is deliberately *not* here
///
/// * **No crash reporting.** `sentry_flutter` is pinned in `pubspec.yaml` and uninitialised,
///   on purpose: a shopkeeper's ledger is not something to start uploading because a button
///   threw. When it is wired, it goes here — inside `runZonedGuarded`, with `sendDefaultPii`
///   off and the database file never in a breadcrumb.
/// * **No `SystemChrome` calls.** The status bar is the platform's business, and an app that
///   fights it is an app with a black bar on one phone and a white one on another.
/// * **No service locator.** The container is created by `KhataApp` with the one override that
///   matters (`databaseProvider`), and everything else is read from it.
library;

import 'package:flutter/material.dart';

import 'apps/bootstrap.dart';
import 'apps/khata_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(KhataBootstrap(builder: (context, boot) => KhataApp(boot: boot)));
}
