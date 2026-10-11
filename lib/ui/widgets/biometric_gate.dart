/// KhataPro · the unlock screen.
///
/// This is the only screen that runs *before* the database exists, so it cannot read a
/// provider: everything it knows arrives in [KhataUnlockView] — a value object assembled by
/// `lib/apps/bootstrap.dart` from the boot attempt.
///
/// ## What it shows, and why it shows that
///
///  * **Which key protects the books.** The custody ladder can land on a hardware key
///    (Android Keystore / Secure Enclave), a hardware key without biometrics, or a
///    passphrase — and `CustodyPlan.notes` says which, in the app's own words. A screen that
///    claimed "protected by your fingerprint" on a phone with no keystore would be a lie the
///    user cannot check, and this app's whole pitch is that the numbers can be checked.
///  * **That sync is not a second prompt.** From `docs/SYNC.md` §1: the *database* alias is
///    gated `afterFirstUnlock`, so a background peer sync or a Drive backup can reach the
///    database without a biometric prompt; only the *vault* (export the recovery phrase,
///    reveal a key) is `biometricPerUse`. The screen says so, because the alternative —
///    leaving the user to discover it — is the user disabling the feature to stop the
///    prompts.
///  * **The honest one-liner about a restart.** If `deviceUnlockedSinceBoot` is false,
///    background work waits for the first unlock. That is the price of not prompting every
///    time, and it is stated at the moment it applies.
///
/// The unlock action itself is `custody.authenticate(reason:)` — a single prompt whose
/// result is recorded in an [AuthenticationSession] so that the next operation inside the
/// grace period does not prompt again (a 20 000-row export must not ask twice).
library;

import 'package:flutter/material.dart';

import '../../core/security/key_custody.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';

/// Everything the unlock screen needs, with no dependency on the database.
final class KhataUnlockView {
  const KhataUnlockView({
    required this.title,
    required this.notes,
    required this.level,
    required this.biometricAvailable,
    required this.needsPassphrase,
    required this.deviceUnlockedSinceBoot,
    this.failureMessage,
    this.offerRestore = false,
  });

  /// The shop's name if it is known before the open (it is not, on a first run), else the
  /// app name. Never a placeholder like "Loading…" on a screen with a button on it.
  final String title;

  /// `CustodyPlan.notes` — verbatim, in order. The screen does not editorialise.
  final List<String> notes;

  final CustodyLevel level;
  final bool biometricAvailable;

  /// True when the device has no hardware keystore and the user must type a passphrase.
  final bool needsPassphrase;

  final bool deviceUnlockedSinceBoot;

  /// Set when the *previous* attempt failed, e.g. wrong passphrase. Null on a first paint.
  final String? failureMessage;

  /// Set when the envelope could not be read at all: the useful action is "restore from a
  /// verified backup", not "try again", and offering only the latter would invite a wipe.
  final bool offerRestore;

  bool get isHardware => level.isHardwareBacked;
}

/// The gate.
///
/// Stateless on purpose: the prompt has its own state in the platform dialog, and a
/// `StatefulWidget` here would only duplicate it (and hold a stale failure message across a
/// retry, which is the bug the "clear on retry" code would then have to fix).
class BiometricGate extends StatelessWidget {
  const BiometricGate({
    super.key,
    required this.view,
    this.onUnlock,
    this.onPassphrase,
    this.onRestore,
    this.busy = false,
  });

  final KhataUnlockView view;

  /// Called when the user taps unlock. Null ⇒ the button is disabled (already unlocking).
  final Future<void> Function()? onUnlock;

  /// Called with the typed passphrase. Only reachable when [KhataUnlockView.needsPassphrase].
  final Future<void> Function(String passphrase)? onPassphrase;

  /// Called when the envelope is unreadable and the user chooses to restore instead.
  final void Function()? onRestore;

  final bool busy;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Spacing.xl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: Spacing.minTouchTarget),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    view.biometricAvailable
                        ? Icons.fingerprint
                        : (view.isHardware ? Icons.sync : Icons.warning),
                    size: 64,
                    color: colors.brand,
                  ),
                  const SizedBox(height: Spacing.lg),
                  Text(
                    view.title,
                    textAlign: TextAlign.center,
                    style: text.titleLarge,
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    _headline(view),
                    textAlign: TextAlign.center,
                    style: text.bodyMedium?.copyWith(color: colors.onSurfaceMuted),
                  ),
                  if (view.notes.isNotEmpty) ...[
                    const SizedBox(height: Spacing.lg),
                    _Notes(notes: view.notes, colors: colors),
                  ],
                  if (!view.deviceUnlockedSinceBoot) ...[
                    const SizedBox(height: Spacing.md),
                    _RestartNote(colors: colors),
                  ],
                  if (view.failureMessage != null) ...[
                    const SizedBox(height: Spacing.lg),
                    _Failure(message: view.failureMessage!, colors: colors),
                  ],
                  const SizedBox(height: Spacing.xl),
                  if (view.needsPassphrase)
                    _PassphraseField(
                      onSubmit: onPassphrase,
                      busy: busy,
                      colors: colors,
                    )
                  else
                    SizedBox(
                      height: Spacing.minTouchTarget,
                      child: ElevatedButton.icon(
                        onPressed: busy ? null : onUnlock,
                        icon: const Icon(Icons.fingerprint),
                        label: Text(view.biometricAvailable ? 'Unlock' : 'Open the book'),
                      ),
                    ),
                  if (view.offerRestore && onRestore != null) ...[
                    const SizedBox(height: Spacing.md),
                    SizedBox(
                      height: Spacing.minTouchTarget,
                      child: OutlinedButton(
                        onPressed: busy ? null : onRestore,
                        child: const Text('Restore from a backup instead'),
                      ),
                    ),
                  ],
                  const SizedBox(height: Spacing.md),
                  Text(
                    'Your books stay on this device. Backups go to your own Google '
                    'Drive or iCloud, and syncing happens directly between your '
                    'phones — there is no KhataPro server.',
                    textAlign: TextAlign.center,
                    style: text.labelSmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// One sentence that answers "why am I being asked this?" before the user has to reason
  /// about it.
  static String _headline(KhataUnlockView view) {
    if (view.needsPassphrase) return 'Enter the passphrase that protects this book.';
    if (view.biometricAvailable) {
      return 'Unlock with your fingerprint or face. Sync keeps working in the '
          'background afterwards.';
    }
    return 'Open the book. This device holds the key, so there is nothing to type.';
  }
}

/// The custody notes, as a list. Rendered verbatim: they are the honest sentences the
/// security policy produced, not marketing copy.
class _Notes extends StatelessWidget {
  const _Notes({required this.notes, required this.colors});

  final List<String> notes;
  final KhataColors colors;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceVariant,
        borderRadius: BorderRadius.circular(Radii.md),
      ),
      child: Padding(
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final note in notes)
              Padding(
                padding: const EdgeInsets.only(bottom: Spacing.sm),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline, size: 16, color: colors.onSurfaceMuted),
                    const SizedBox(width: Spacing.sm),
                    Expanded(
                      child: Text(
                        note,
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: colors.onSurfaceMuted),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _RestartNote extends StatelessWidget {
  const _RestartNote({required this.colors});

  final KhataColors colors;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(Icons.sync, size: 16, color: colors.warning),
        const SizedBox(width: Spacing.sm),
        Expanded(
          child: Text(
            'After a restart, syncing waits for your first unlock.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

/// A failure is shown as a sentence and a next action, never as a code the user cannot act
/// on. The code lives in the log, which is what a support bundle reads.
class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.colors});

  final String message;
  final KhataColors colors;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Spacing.md),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: colors.critical),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: colors.critical),
          const SizedBox(width: Spacing.sm),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onCanvas),
            ),
          ),
        ],
      ),
    );
  }
}

/// The passphrase path. A `TextField` and a button — no "forgot passphrase?" link, because
/// there is no server to recover from and offering one would be the most dangerous lie in
/// the app; the restore button is the honest escape hatch.
class _PassphraseField extends StatefulWidget {
  const _PassphraseField({
    required this.onSubmit,
    required this.busy,
    required this.colors,
  });

  final Future<void> Function(String passphrase)? onSubmit;
  final bool busy;
  final KhataColors colors;

  @override
  State<_PassphraseField> createState() => _PassphraseFieldState();
}

class _PassphraseFieldState extends State<_PassphraseField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text;
    if (value.isEmpty || widget.busy) return;
    // Not cleared on success — the screen is replaced. Cleared on failure by the caller
    // rebuilding with a failure message; keeping the text would let a bystander read it.
    widget.onSubmit?.call(value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _controller,
          autofocus: true,
          obscureText: true,
          maxLines: 1,
          onChanged: (_) => setState(() {}),
          decoration: const InputDecoration(hintText: 'Passphrase'),
        ),
        const SizedBox(height: Spacing.md),
        SizedBox(
          height: Spacing.minTouchTarget,
          child: ElevatedButton(
            onPressed:
                widget.busy || _controller.text.isEmpty ? null : _submit,
            child: widget.busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Unlock'),
          ),
        ),
      ],
    );
  }
}
