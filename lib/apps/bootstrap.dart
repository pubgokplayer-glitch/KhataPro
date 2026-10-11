/// KhataPro · boot wiring: open the database, then hand the app a live one.
///
/// This is the seam between "the phone" and "the state layer", and it is deliberately the
/// only file that knows about both:
///
///   platform keystore ──▶ [openKhataDatabase] ──▶ `KhataDatabase`
///                                                       │
///                        `databaseProvider.overrideWithValue(db)`  ← [KhataBootstrap]
///                                                       │
///                                              the app's `ProviderScope`
///
/// ## Why the switch is a `FutureBuilder` and not a provider
///
/// `databaseProvider` throws unless it is overridden (`providers.dart` says why: two live
/// databases would be two truths). So the boot cannot be *inside* the container it feeds.
/// [KhataBootstrap] therefore owns the future, renders the unlock screen or the database
/// screen, and only builds the `ProviderScope` once a real handle exists. A failed boot
/// never produces a container at all, which means no screen can accidentally query a
/// half-open book.
///
/// ## What the passwords/passphrase flow costs
///
/// Argon2id at the verified parameters takes ~1.5 s on a mid-range phone, and the keystore
/// round trip plus 11 migrations take a few hundred milliseconds more. That is a splash
/// screen, not a spinner over a broken layout: [KhataBootstrap] shows the same brand
/// surface the app uses, with the migration progress reported honestly (the runner counts
/// files, and the count is printed rather than guessed).
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../core/security/key_custody.dart';
import '../data/db/database_init.dart';
import '../platform/security/security_policy.dart';
import '../platform/security/security_transport.dart';
import '../ui/theme/theme.dart';
import '../ui/theme/tokens.dart';
import '../ui/widgets/biometric_gate.dart';

/// Boots the database and then builds the app.
///
/// [open] and [appDirectory] are injectable so the flow can be driven in a test with the
/// fake security transport and a temp directory — the same code path, no phone.
class KhataBootstrap extends StatefulWidget {
  const KhataBootstrap({
    super.key,
    required this.builder,
    this.appDirectory,
    this.transport,
    this.requireEncryption = true,
  });

  /// Builds the app once the book is open. Receives the boot result so the app can show
  /// custody details in Settings and know whether this is a first run.
  final Widget Function(BuildContext context, KhataBoot boot) builder;

  final Directory? appDirectory;
  final SecurityTransport? transport;

  /// Must stay `true` on a device. See [openKhataDatabase].
  final bool requireEncryption;

  @override
  State<KhataBootstrap> createState() => _KhataBootstrapState();
}

class _KhataBootstrapState extends State<KhataBootstrap> {
  Future<KhataBoot>? _boot;

  /// The plan from the last attempt. Kept so the unlock screen can say *which* key is
  /// protecting the book even when the attempt failed — that sentence is exactly what the
  /// user needs before deciding between "type it again" and "restore a backup".
  CustodyPlan? _plan;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    setState(() {
      _boot = _open();
    });
  }

  Future<KhataBoot> _open() async {
    final dir = widget.appDirectory ?? await getApplicationDocumentsDirectory();
    return openKhataDatabase(
      appDir: dir,
      transport: widget.transport,
      requireEncryption: widget.requireEncryption,
      platform: Platform.operatingSystem,
    );
  }

  /// Unlocks with a passphrase — the no-hardware-keystore path. Re-runs the whole boot:
  /// the DEK has to be unwrapped again with the newly derived KEK, so there is nothing
  /// cheaper to reuse.
  Future<void> _unlockWithPassphrase(String passphrase) async {
    final dir = widget.appDirectory ?? await getApplicationDocumentsDirectory();
    setState(() {
      _boot = openKhataDatabase(
        appDir: dir,
        transport: widget.transport,
        requireEncryption: widget.requireEncryption,
        platform: Platform.operatingSystem,
        passphrase: passphrase,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final future = _boot ?? Future<KhataBoot>.error(StateError('boot not started'));

    return FutureBuilder<KhataBoot>(
      future: future,
      builder: (context, snapshot) {
        final boot = snapshot.data;
        if (boot != null) return widget.builder(context, boot);

        final failure = snapshot.error;
        if (failure is KhataUnlockFailure) {
          return _GateForFailure(
            failure: failure,
            plan: _plan,
            onPassphrase: _unlockWithPassphrase,
            onRetry: _start,
          );
        }
        if (failure != null) {
          // Not a typed unlock failure: a bug or a device problem, and the honest thing is
          // to say so with the error text rather than a generic "something went wrong".
          return _BootError(error: failure, onRetry: _start);
        }
        return const BootSplash();
      },
    );
  }
}

/// Splash while the book opens. No fake progress bar: the work is a migration count, and a
/// bar that has to invent its position is worse than a sentence.
class BootSplash extends StatelessWidget {
  const BootSplash({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.sync, size: 48, color: colors.brand),
            const SizedBox(height: Spacing.lg),
            Text('Opening your book…', style: Theme.of(context).textTheme.bodyLarge),
            const SizedBox(height: Spacing.sm),
            Text(
              'Decrypting with the key held in this device.',
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: colors.onSurfaceMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Maps a boot failure onto the unlock screen's view object.
///
/// It lives here rather than in the widget because the mapping *is* the contract: which
/// failure gets which affordance ("try again" vs. "restore a backup") is a product decision
/// that has to see the boot result, and the widget must stay renderable from plain values.
class _GateForFailure extends StatelessWidget {
  const _GateForFailure({
    required this.failure,
    required this.plan,
    required this.onPassphrase,
    required this.onRetry,
  });

  final KhataUnlockFailure failure;
  final CustodyPlan? plan;
  final Future<void> Function(String passphrase) onPassphrase;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final needsPassphrase =
        failure.reason == UnlockFailureReason.passphraseRequired || plan?.backend == null;
    final capabilities = plan?.capabilities;

    return BiometricGate(
      view: KhataUnlockView(
        title: 'KhataPro',
        notes: plan?.notes ?? const [],
        level: plan?.level ?? CustodyLevel.passphraseWrapped,
        biometricAvailable: (capabilities?.biometricAvailable ?? false) && !needsPassphrase,
        needsPassphrase: needsPassphrase,
        deviceUnlockedSinceBoot: capabilities?.deviceUnlockedSinceBoot ?? true,
        failureMessage: needsPassphrase ? null : failure.message,
        // Only these two reasons have a useful second action. "Wrong passphrase" gets
        // another attempt, not a wipe.
        offerRestore: failure.reason == UnlockFailureReason.envelopeNotReadable ||
            failure.reason == UnlockFailureReason.envelopeUnreadable,
      ),
      onUnlock: needsPassphrase ? null : () async => onRetry(),
      onPassphrase: needsPassphrase ? onPassphrase : null,
    );
  }
}

class _BootError extends StatelessWidget {
  const _BootError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = KhataTheme.colorsOf(context);
    return Scaffold(
      backgroundColor: colors.canvas,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(Spacing.xl),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.error_outline, size: 48, color: colors.critical),
              const SizedBox(height: Spacing.lg),
              Text('The book could not be opened',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: Spacing.sm),
              Text('$error', style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: Spacing.xl),
              SizedBox(
                height: Spacing.minTouchTarget,
                child: OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('Try again'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
