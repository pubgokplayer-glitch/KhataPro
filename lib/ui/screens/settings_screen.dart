import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../commands/book_commands.dart';
import '../format/formatting.dart';
import '../format/strings.dart';
import '../state/providers.dart';
import '../theme/theme.dart';
import '../widgets/skeletons.dart';
import '../theme/tokens.dart';
import '../widgets/cards.dart';
import '../widgets/outcome_toast.dart';

/// Settings: how the app looks, how the books are doing, and how to find out.
///
/// The screen is deliberately three groups and no more:
///
/// 1. **Language and digits** — the only two display preferences that change what a number
///    *means* to the person reading it (Urdu digits, lakh vs international grouping), and both
///    of them rewrite every amount in the app the moment they change.
/// 2. **Book health** — pending sync operations, unreviewed conflicts, the last verified
///    backup, and the two buttons that matter when something looks wrong: *check my books*
///    (the full 15-critical-class integrity sweep, ~275 ms on a 20 000-entry book) and
///    *rebuild totals* (the cache rebuild, for when a phone was restored from a backup).
/// 3. **This device** — the custody line, the node id, the schema version. The information a
///    support conversation needs, on the screen a support conversation asks about.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({
    super.key,
    this.custodyNote,
    this.nodeId,
    this.createdNow = false,
    this.inviteTicket,
  });

  /// Set by the boot path. Null when the app was opened without a keystore and a passphrase
  /// did the unwrapping.
  final String? custodyNote;

  /// This device's `node_id` — the identity every replicated row is stamped with, and the
  /// first thing to check when two phones disagree about who wrote what.
  final String? nodeId;

  /// True on the run that created the database: the screen says so instead of claiming a
  /// backup that has never happened.
  final bool createdNow;

  /// A pairing ticket that arrived in a deep link (`khatapro://join?t=…`). Shown here rather
  /// than on a screen of its own: the ticket is only useful next to "pair a phone", and that
  /// is a sync action belonging to this screen's health section.
  final String? inviteTicket;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final strings = UiStrings(ref.watch(displayPrefsProvider).language);
    final prefs = ref.watch(displayPrefsProvider);
    final text = Theme.of(context).textTheme;
    final colors = KhataTheme.colorsOf(context);

    return Scaffold(
      appBar: AppBar(title: Text(strings.settings)),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SectionHeader(title: strings.languageLabel),
            ListTile(
              leading: const Icon(Icons.lock, size: 20),
              title: Text(strings.englishLabel),
              trailing: prefs.language == UiLanguage.english ? const Icon(Icons.check) : null,
              onTap: () => ref.read(displayPrefsProvider.notifier).setLanguage(UiLanguage.english),
            ),
            ListTile(
              leading: const Icon(Icons.lock, size: 20),
              title: Text(strings.urduLabel),
              trailing: prefs.language == UiLanguage.urdu ? const Icon(Icons.check) : null,
              onTap: () => ref.read(displayPrefsProvider.notifier).setLanguage(UiLanguage.urdu),
            ),
            SectionHeader(title: strings.digitGrouping),
            ListTile(
              title: Text(strings.lakhCrore),
              trailing: prefs.grouping == GroupingStyle.lakh ? const Icon(Icons.check) : null,
              onTap: () => ref.read(displayPrefsProvider.notifier).setGrouping(GroupingStyle.lakh),
            ),
            ListTile(
              title: Text(strings.westernGrouping),
              trailing: prefs.grouping == GroupingStyle.western ? const Icon(Icons.check) : null,
              onTap: () => ref.read(displayPrefsProvider.notifier).setGrouping(GroupingStyle.western),
            ),
            const ListHairline(),
            SectionHeader(title: strings.syncHealth),
            ref.watch(syncHealthProvider).when(
                  loading: () => const Padding(
                    padding: EdgeInsets.all(Spacing.lg),
                    child: LinearProgressIndicator(),
                  ),
                  error: (error, _) => Padding(
                    padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.md),
                    child: Text(strings.couldNotLoad(error), style: text.labelSmall),
                  ),
                  data: (health) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                        child: Text(
                          health.pendingOps == 0
                              ? strings.uptoDate
                              : strings.pendingChanges(health.pendingOps),
                          style: text.bodyMedium,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                        child: Text(
                          health.trustedPeers == 0
                              ? strings.noPeersYet
                              : strings.peersPaired(health.trustedPeers),
                          style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                        child: Text(
                          health.unreviewedConflicts == 0
                              ? strings.noConflicts
                              : strings.conflictsWaiting(health.unreviewedConflicts),
                          style: text.labelSmall?.copyWith(
                            color: health.unreviewedConflicts == 0 ? colors.onSurfaceMuted : colors.warning,
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                        child: Text(
                          health.lastBackupAtMs == null
                              ? strings.noBackupYet
                              : strings.lastBackup(health.lastBackupAtMs!),
                          style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted),
                        ),
                      ),
                    ],
                  ),
                ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, 0),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _checkBooks(context, ref),
                      child: Text(strings.checkBooks),
                    ),
                  ),
                  const SizedBox(width: Spacing.sm),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => _rebuild(context, ref),
                      child: Text(strings.rebuildCaches),
                    ),
                  ),
                ],
              ),
            ),
            if (inviteTicket != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, Spacing.sm, Spacing.lg, 0),
                child: AttentionBanner(
                  message: strings.invitationReady(inviteTicket!),
                  actionLabel: strings.copyInvitation,
                  onAction: () => Clipboard.setData(ClipboardData(text: inviteTicket!)),
                ),
              ),
            const ListHairline(),
            SectionHeader(title: strings.about),
            if (custodyNote != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.lock, size: 16, color: colors.moneyIn),
                    const SizedBox(width: Spacing.sm),
                    Expanded(child: Text(custodyNote!, style: text.labelMedium)),
                  ],
                ),
              ),
            if (createdNow)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.sm),
                child: Text(strings.createdToday, style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted)),
              ),
            if (nodeId != null)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(Spacing.lg, 0, Spacing.lg, Spacing.xl),
                child: Text(
                  '${strings.thisDevice}: $nodeId',
                  style: text.labelSmall?.copyWith(color: colors.onSurfaceMuted),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The full integrity sweep, on demand. Slow by design — it checks every critical class the
  /// schema knows — and the answer is a sentence, not a spinner: "no problems found" or the
  /// findings themselves.
  Future<void> _checkBooks(BuildContext context, WidgetRef ref) async {
    final commands = ref.read(bookCommandsProvider);
    final strings = UiStrings(ref.read(displayPrefsProvider).language);
    if (commands == null) return;
    final report = await commands.audit();
    if (!context.mounted) return;
    final findings = report.findings.map((f) => f.detail).toList();
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: KhataTheme.colorsOf(context).surface,
      builder: (context) => Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(strings.checkBooks, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: Spacing.sm),
            Text(
              report.isClean
                  ? strings.booksAreClean(report.accountsChecked, report.durationMs)
                  : strings.booksHaveProblems(findings.length),
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            for (final detail in findings.take(6))
              Padding(
                padding: const EdgeInsetsDirectional.only(top: Spacing.xs),
                child: Text('· $detail', style: Theme.of(context).textTheme.labelSmall),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _rebuild(BuildContext context, WidgetRef ref) async {
    final commands = ref.read(bookCommandsProvider);
    if (commands == null) return;
    await commands.rebuildCaches();
    if (!context.mounted) return;
    showOutcome(
      context,
      CommandOutcome.posted(message: UiStrings(ref.read(displayPrefsProvider).language).rebuildDone),
    );
  }
}
