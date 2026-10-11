/// KhataPro · the custody ladder and the authentication session.
///
/// ## The two questions this file answers
///
/// **1 · Which key do we use on this device?** Not a guess at boot: the policy
/// probes, then chooses, then *records the choice*, because a device that once had
/// a hardware key and now does not is a different situation from a fresh install
/// and must be reported differently.
///
///   hardwareBiometric → hardwareDevice → passphraseWrapped → unprotected
///
/// Each step down is announced in the Security screen with the sentence the
/// salesman will actually read (from [CustodyLevel]). Nothing here silently
/// degrades: a downgrade from a hardware key to a passphrase is a visible event
/// with a reason attached.
///
/// **2 · How does background sync open the database without prompting?** By not
/// using the prompt-gated key for that job. The ladder puts the **database** DEK
/// behind an after-first-unlock key, and reserves the biometric key for export.
/// [AuthenticationSession] then exists for the *opposite* problem: one user action
/// that touches the vault twice (read the export key, then sign the manifest)
/// should prompt **once**, not twice — so an authentication is held for a short,
/// stamped window rather than for a whole session.
///
/// Everything in this file is pure Dart: no Flutter import, no platform channel.
/// The fake keystore in `fake_security_transport.dart` reproduces the platform's
/// semantics (opaque handles, refusals, invalidation by enrolment, locked device)
/// and the harness runs the real ladder against it.
library;

import 'dart:math' as math;

import '../../core/security/key_custody.dart';
import 'platform_key_custody.dart';
import 'security_transport.dart';

/// What the user chose in Settings, and what the device allows. The two are
/// deliberately separate: a preference is not a capability.
enum CustodyPreference {
  /// Hardware key where possible, biometric gate on export. The default.
  hardwarePreferred('hardware_preferred'),

  /// Never use biometrics, even for export. Hardware key still used if present.
  noBiometrics('no_biometrics'),

  /// Never use the platform keystore at all: Argon2id from the passphrase.
  passphraseOnly('passphrase_only');

  const CustodyPreference(this.id);

  final String id;

  static CustodyPreference fromId(String id) {
    for (final value in CustodyPreference.values) {
      if (value.id == id) return value;
    }
    return CustodyPreference.hardwarePreferred;
  }
}

/// The outcome of probing, choosing and (optionally) creating keys.
final class CustodyPlan {
  const CustodyPlan({
    required this.level,
    required this.capabilities,
    required this.notes,
    required this.backend,
    this.recoveredFromFallback = false,
  });

  /// What the database will actually be wrapped with.
  final CustodyLevel level;

  /// What the device reported about itself, verbatim.
  final SecurityCapabilities capabilities;

  /// Sentences for the Security screen — including the uncomfortable ones.
  final List<String> notes;

  /// The implementation that owns the key, or null when the caller must supply a
  /// [PassphraseKeyCustody] alongside it.
  final KeyCustody? backend;

  /// True when the previous installation used a hardware key that is no longer
  /// available (device restored, keystore cleared, app reinstalled without restore).
  /// The app must then offer "restore from backup" rather than present an empty
  /// ledger as if nothing happened.
  final bool recoveredFromFallback;

  bool get isHardware => level.isHardwareBacked;
}

/// Chooses and constructs the custody for this device. Stateless by design: the
/// state lives in `key_material` and in [PlatformKeyCustody], not here.
final class SecurityPolicy {
  SecurityPolicy({
    SecurityTransport? transport,
    this.preference = CustodyPreference.hardwarePreferred,
  }) : _transport = transport;

  final SecurityTransport? _transport;
  final CustodyPreference preference;

  /// The ladder. Order matters and is asserted by the harness:
  ///
  ///  1. no transport at all (desktop host, unit test) → passphrase;
  ///  2. the platform says there is no hardware → passphrase;
  ///  3. the user asked for passphrase-only → passphrase;
  ///  4. the user refused biometrics → hardware key with **no** vault alias;
  ///  5. otherwise → hardware key + biometric vault key.
  Future<CustodyPlan> resolve() async {
    final transport = _transport;
    if (transport == null) {
      return CustodyPlan(
        level: CustodyLevel.passphraseWrapped,
        capabilities: _noPlatformCapabilities,
        notes: const [
          'No platform keystore on this device, so the database key is derived from '
              'your passphrase.',
        ],
        backend: null,
      );
    }

    final platform = PlatformKeyCustody(transport: transport);

    // The user's refusal is checked *before* the keystore is touched. Asking for a
    // capability probe is fine (it reads nothing), but creating a key the user
    // explicitly declined to have stored would be a policy violation, not a
    // performance detail — and this ordering is asserted by security_verify.
    if (preference == CustodyPreference.passphraseOnly) {
      final capabilities = await _probe(platform);
      return CustodyPlan(
        level: CustodyLevel.passphraseWrapped,
        capabilities: capabilities,
        notes: [
          'You chose the passphrase path, so no key is stored in the device keystore.',
          ...await _describeNotes(platform),
        ],
        backend: null,
      );
    }

    try {
      await platform.initialise(
        requireBiometricForVault: preference == CustodyPreference.hardwarePreferred,
      );
    } on SecurityChannelException catch (error) {
      // A device that cannot do hardware at all steps down. A device that *can*
      // and returned something else is a real failure and is rethrown: treating a
      // broken keystore as "no keystore" would quietly weaken the app.
      if (error.code == SecurityErrorCodes.unimplemented ||
          error.code == SecurityErrorCodes.hardwareUnavailable) {
        return CustodyPlan(
          level: CustodyLevel.passphraseWrapped,
          capabilities: _noPlatformCapabilities,
          notes: [
            'This device refused to provide a hardware key (${error.code}), so the '
                'database key is derived from your passphrase.',
          ],
          backend: null,
        );
      }
      rethrow;
    }

    final capabilities = platform.capabilities ?? _noPlatformCapabilities;
    final notes = <String>[...await _describeNotes(platform)];

    if (!platform.isReady) {
      // The device has no usable keystore. Say which key protects the books now,
      // in the same breath as why they are not hardware-protected.
      return CustodyPlan(
        level: CustodyLevel.passphraseWrapped,
        capabilities: capabilities,
        notes: [
          'This device has no hardware keystore, so the database key is derived '
              'from your passphrase (Argon2id) and never stored.',
          ...notes,
        ],
        backend: null,
      );
    }

    final level = preference == CustodyPreference.noBiometrics &&
            platform.level == CustodyLevel.hardwareBiometric
        ? CustodyLevel.hardwareDevice
        : platform.level;

    return CustodyPlan(
      level: level,
      capabilities: capabilities,
      notes: [
        ...notes,
        if (!capabilities.deviceUnlockedSinceBoot)
          'After a restart, sync waits for your first unlock. That is the price of '
              'not asking for a fingerprint every time.',
      ],
      backend: platform,
    );
  }

  Future<List<String>> _describeNotes(PlatformKeyCustody platform) async {
    final capability = await platform.describe();
    return capability.notes;
  }

  /// Reads what the device can do without creating anything. Used by the
  /// passphrase-only path, which must not leave a key behind merely to find out.
  Future<SecurityCapabilities> _probe(PlatformKeyCustody platform) async {
    final transport = _transport;
    if (transport == null) return _noPlatformCapabilities;
    try {
      return SecurityCapabilities.fromMap(
        await transport.invoke(SecurityMethods.capabilities),
      );
    } on SecurityChannelException {
      return _noPlatformCapabilities;
    }
  }

  static const SecurityCapabilities _noPlatformCapabilities = SecurityCapabilities(
    hardwareBacked: false,
    biometricAvailable: false,
    strongBoxAvailable: false,
    deviceUnlockedSinceBoot: true,
    presentAliases: <String>{},
    notes: <String>[],
  );
}

/// One authentication, reused for a few seconds.
///
/// The problem it solves: exporting the books touches the vault key more than once
/// (read the key, write the manifest, sign the header). Prompting per operation is
/// the behaviour that makes people disable the lock. Prompting once and holding the
/// fact in memory for a short window is the honest compromise.
///
/// What it deliberately is **not**: a session-long flag. It expires, it is not
/// persisted, it cannot be recreated without the user, and it is scoped to one
/// action by [begin]/[end].
final class AuthenticationSession {
  AuthenticationSession({
    required this.gracePeriod,
    this.clock = DateTime.now,
  });

  /// How long one prompt covers. Long enough for an export to finish on a slow
  /// phone, short enough that picking the device up a minute later prompts again.
  final Duration gracePeriod;

  final DateTime Function() clock;

  int? _authenticatedAtMs;
  int? _scopedTo;

  /// True when a previous [begin] is still inside its window.
  bool get isOpen {
    final opened = _authenticatedAtMs;
    if (opened == null) return false;
    return clock().millisecondsSinceEpoch - opened <= gracePeriod.inMilliseconds;
  }

  /// Records that the user just authenticated successfully.
  void grant() {
    _authenticatedAtMs = clock().millisecondsSinceEpoch;
  }

  /// Opens a window for [scope]. Returns true when the caller may proceed without
  /// prompting: either the same scope authenticated moments ago, or a fresh grant
  /// exists. A *different* scope does not inherit another action's authentication.
  bool begin(Object scope) {
    if (!isOpen) return false;
    final scoped = _scopedTo;
    if (scoped != null && scoped != scope.hashCode) return false;
    _scopedTo = scope.hashCode;
    return true;
  }

  /// Ends the action. The grant survives until [gracePeriod] elapses, so a
  /// second operation in the same flow does not prompt again.
  void end() => _scopedTo = null;

  /// Forgets everything: called on logout, on lock, on screen-off, and whenever
  /// the app returns to the foreground after a long absence.
  void revoke() {
    _authenticatedAtMs = null;
    _scopedTo = null;
  }

  /// Milliseconds left in the window; 0 when closed. Drives a subtle countdown in
  /// the export sheet so the behaviour is visible rather than mysterious.
  int remainingMs() {
    final opened = _authenticatedAtMs;
    if (opened == null) return 0;
    final elapsed = clock().millisecondsSinceEpoch - opened;
    return math.max(0, gracePeriod.inMilliseconds - elapsed);
  }
}

/// The numbers the ladder is allowed to use, in one place, with reasons.
abstract final class SecurityTuning {
  /// One prompt covers an export that takes up to this long. Chosen to be longer
  /// than a 20 000-row export on a low-end phone (~6 s measured) and shorter than
  /// the time it takes to put the phone down and hand it to someone else.
  static const Duration exportGrace = Duration(seconds: 30);

  /// Biometric keys on Android are invalidated by enrolment changes (see the
  /// Kotlin file) — this is not configurable, only documented here so the
  /// behaviour is findable from the Dart side too.
  static const bool invalidateOnEnrolmentChange = true;
}
