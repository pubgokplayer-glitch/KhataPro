/// KhataPro · the app chrome: the bottom navigation and the sync badge.
///
/// ## Why the navigation is not inside the router's state
///
/// Each tab is a top-level `GoRoute` and the shell wraps whichever one is showing, with the
/// selected index derived from the current location. That means the URL and the tab can never
/// disagree — a deep link that opens `/cash` lights the cash tab, and a back gesture returns to
/// the tab it came from. The alternative (a `StatefulShellRoute` or an index held in a provider)
/// has to keep two sources of truth in step, and the first failing case is exactly the one that
/// matters: a link opened from a reminder while the app was on the bills tab.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../apps/deep_links.dart';
import '../format/strings.dart';
import '../state/providers.dart';
import '../state/queries.dart' show SyncHealth;
import '../theme/theme.dart';

/// The five tabs, in order. `/staff` and `/settings` are reached from the app bar of the
/// screens that own them, so they stay out of the bar.
const List<String> kTabLocations = <String>[
  KhataRoutes.dashboard,
  KhataRoutes.parties,
  KhataRoutes.cash,
  KhataRoutes.bills,
  KhataRoutes.stock,
];

class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.location, required this.child});

  /// The current router location, used to decide which tab is lit.
  final String location;
  final Widget child;

  static int indexFor(String location) {
    for (var i = 0; i < kTabLocations.length; i += 1) {
      final tab = kTabLocations[i];
      if (tab == KhataRoutes.dashboard) {
        if (location == '/' || location.isEmpty) return i;
        continue;
      }
      if (location == tab || location.startsWith('$tab/') || location.startsWith('$tab?')) {
        return i;
      }
    }
    // A pushed screen (a party ledger, a bill from a link) has no tab of its own; the bar
    // keeps showing the tab it was opened from, which is the one `GoRouter` reports as the
    // last matched location — hence `location` is the *matched* location, not the uri.
    return 0;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);

    return Scaffold(
      body: child,
      bottomNavigationBar: NavigationBar(
        selectedIndex: indexFor(location),
        onDestinationSelected: (index) => context.go(kTabLocations[index]),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.dashboard), label: strings.dashboard),
          NavigationDestination(icon: const Icon(Icons.groups), label: strings.parties),
          NavigationDestination(icon: const Icon(Icons.payments), label: strings.cashBook),
          NavigationDestination(icon: const Icon(Icons.receipt_long), label: strings.billBook),
          NavigationDestination(icon: const Icon(Icons.inventory_2), label: strings.stockBook),
        ],
      ),
    );
  }
}

/// One small dot in every app bar: synced, syncing, or never.
///
/// It reads `syncHealthProvider` — the same provider the settings screen reads — and shows a
/// single glyph with a tooltip, because the number of pending operations is not something to
/// put in front of a shopkeeper who is mid-sale. The tap target opens the settings screen,
/// where the numbers are spelled out.
class SyncBadge extends ConsumerWidget {
  const SyncBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = KhataTheme.colorsOf(context);
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final health = ref.watch(syncHealthProvider).value;

    final (IconData icon, Color tone, String tooltip) = switch (health) {
      null => (Icons.cloud_off, colors.onSurfaceMuted, strings.neverSynced),
      SyncHealth(pendingOps: final pending, unreviewedConflicts: final conflicts)
          when conflicts > 0 =>
        (Icons.warning_amber, colors.critical, strings.conflictsWaiting(conflicts)),
      SyncHealth(pendingOps: final pending) when pending > 0 =>
        (Icons.sync, colors.warning, strings.pendingChanges(pending)),
      _ => (Icons.cloud_done, colors.moneyIn, strings.uptoDate),
    };

    return IconButton(
      tooltip: tooltip,
      onPressed: () => context.go(KhataRoutes.settings),
      icon: Icon(icon, size: 20, color: tone),
    );
  }
}
