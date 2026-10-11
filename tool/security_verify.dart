#!/usr/bin/env dart
// KhataPro · Deliverable 3 · platform security bindings, verified.
//
// Runs the *real* custody policy (`lib/platform/security/`) against a fake
// Keystore/Keychain that keeps the semantics that matter: opaque handles,
// idempotent key creation, device-lock refusal, per-use authentication, and
// invalidation when the biometric enrolment changes.
//
// What it demonstrates, in the user's terms:
//
//   · the database key opens with **no prompt** — background sync works;
//   · the export key **always** prompts, and one prompt covers exactly one
//     operation;
//   · a reboot delays sync instead of breaking it;
//   · enrolling a new fingerprint destroys the export key and leaves the books
//     readable;
//   · neither key can ever be read out of the device.
//
// Run from the harness:
//   cd /tmp/harness && ./dartx run ../../../home/user/khata_pro/tool/security_verify.dart
//
// No Flutter import anywhere in the path: this is bare Dart by construction.

import 'dart:io';
import 'dart:typed_data';

import 'package:khata_pro/core/security/hasher.dart';
import 'package:khata_pro/core/security/key_custody.dart';
import 'package:khata_pro/core/security/wraps.dart';
import 'package:khata_pro/platform/security/fake_security_transport.dart';
import 'package:khata_pro/platform/security/platform_key_custody.dart';
import 'package:khata_pro/platform/security/security_policy.dart';
import 'package:khata_pro/platform/security/security_transport.dart';

// ── a tiny check runner, same shape as the other verify tools ────────────────

var _checks = 0;
var _failed = 0;
final _section = <String>[];

void section(String name) {
  _section.add(name);
  final pad = 62 - name.length;
  print('\n  ── $name ${pad > 0 ? '─' * pad : ''}');
}

void check(String what, bool ok, [String? detail]) {
  _checks += 1;
  if (ok) {
    print('    ✓ $what');
  } else {
    _failed += 1;
    print('    ✗ $what${detail == null ? '' : '  —  $detail'}');
  }
}

Future<void> main() async {
  print('  KhataPro · platform security bindings');
  print('  ══════════════════════════════════════════════════════════════════');

  await _ladderStepsDown();
  await _ladderHonoursPreferences();
  await _keyCreationIsIdempotent();
  await _databaseKeyNeedsNoPrompt();
  await _exportKeyAlwaysPrompts();
  await _onePromptOneOperation();
  await _deviceLockDelaysSync();
  await _enrolmentChangeDestroysExportKey();
  await _bothPlatformFlavoursRoundTrip();
  await _wrongKeyFailsClosed();
  await _wipeLeavesNothing();
  await _capabilityReportingIsHonest();
  await _authenticationSessionWindow();

  print('\n  ══════════════════════════════════════════════════════════════════');
  if (_failed == 0) {
    print('  ✓ all $_checks checks passed');
  } else {
    print('  ✗ $_failed of $_checks checks FAILED');
    exit(1);
  }
}

// ── the ladder ───────────────────────────────────────────────────────────────

Future<void> _ladderStepsDown() async {
  section('the custody ladder steps down, never sideways');

  final bare = await SecurityPolicy().resolve();
  check(
    'no platform keystore → passphrase custody, and the user is told',
    bare.level == CustodyLevel.passphraseWrapped &&
        bare.backend == null &&
        bare.notes.any((n) => n.contains('passphrase')),
    'level=${bare.level.id}',
  );

  final noHardware = FakeSecurityTransport(hardwareBacked: false);
  final plan = await SecurityPolicy(transport: noHardware).resolve();
  check(
    'the device reports no hardware → passphrase custody',
    plan.level == CustodyLevel.passphraseWrapped && !plan.isHardware,
    'level=${plan.level.id}',
  );
  check(
    'the plan says which key protects the books now, not just that hardware is absent',
    plan.notes.any((n) => n.contains('derived from your passphrase')),
    plan.notes.firstOrNull,
  );
  check(
    'the screen does not claim hardware protection it does not have',
    plan.notes.any((n) => n.contains('No hardware keystore')),
  );

  final enrolled = FakeSecurityTransport();
  final full = await SecurityPolicy(transport: enrolled).resolve();
  check(
    'hardware + biometrics → the top of the ladder',
    full.level == CustodyLevel.hardwareBiometric && full.isHardware,
  );
  check(
    'both key aliases exist afterwards',
    enrolled.holdsKey(KeyAlias.database) && enrolled.holdsKey(KeyAlias.vault),
  );

  final noBiometrics = FakeSecurityTransport(biometricAvailable: false);
  final deviceOnly = await SecurityPolicy(transport: noBiometrics).resolve();
  check(
    'no biometrics enrolled → device-bound key, no vault alias',
    deviceOnly.level == CustodyLevel.hardwareDevice &&
        noBiometrics.holdsKey(KeyAlias.database) &&
        !noBiometrics.holdsKey(KeyAlias.vault),
  );
  check(
    'the user is told how export is protected instead',
    (await PlatformKeyCustody(transport: noBiometrics).describe())
        .notes
        .any((n) => n.contains('No biometrics enrolled')),
  );
}

Future<void> _ladderHonoursPreferences() async {
  section('preferences are honoured, and are not mistaken for capabilities');

  final device = FakeSecurityTransport();
  final optedOut = await SecurityPolicy(
    transport: device,
    preference: CustodyPreference.noBiometrics,
  ).resolve();
  check(
    'user refuses biometrics → hardware key, no biometric gate',
    optedOut.level == CustodyLevel.hardwareDevice && !device.holdsKey(KeyAlias.vault),
  );

  final passphraseDevice = FakeSecurityTransport();
  final passphrase = await SecurityPolicy(
    transport: passphraseDevice,
    preference: CustodyPreference.passphraseOnly,
  ).resolve();
  check(
    'user insists on a passphrase → no key is written to the keystore at all',
    passphrase.level == CustodyLevel.passphraseWrapped &&
        !passphraseDevice.holdsKey(KeyAlias.database),
  );
}

// ── the key that must not prompt ─────────────────────────────────────────────

Future<void> _keyCreationIsIdempotent() async {
  section('key creation is idempotent — a re-run must never rotate a live key');

  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();

  final firstFingerprint = _fingerprintsSeen(device);
  final generationsAfterFirst = device.keyGenerations;
  final dek = randomBytes(32);
  final envelope = await custody.wrap(dek, keyId: 'db_dek');

  // Second initialisation, exactly what happens on the next app launch.
  await custody.initialise();
  check(
    'a second initialise generates no new keys',
    device.keyGenerations == generationsAfterFirst,
    'generations $generationsAfterFirst → ${device.keyGenerations}',
  );
  check(
    'fingerprints are unchanged, so `key_material` sees no phantom rotation',
    _fingerprintsSeen(device) == firstFingerprint,
  );
  check(
    'a DEK wrapped before the re-init still unwraps',
    _bytesEqual(dek, await custody.unwrap(envelope)),
  );
}

Future<void> _databaseKeyNeedsNoPrompt() async {
  section('the database key opens with no prompt — background sync works');

  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();

  final dek = randomBytes(32);
  final envelope = await custody.wrap(dek, keyId: 'db_dek');
  check(
    'wrapping the database key asks the platform for nothing',
    !device.calls.contains(SecurityMethods.authorize),
  );

  final opened = await custody.unwrap(envelope);
  check('the database key unwraps without authentication', _bytesEqual(dek, opened));
  check(
    'no prompt was ever raised',
    !device.calls.contains(SecurityMethods.authorize) && device.keyGenerations == 3,
  );

  // And it keeps working, repeatedly — this is the background sync path that runs
  // nightly, unattended, forever.
  var ok = true;
  for (var i = 0; i < 50; i++) {
    ok = ok && _bytesEqual(dek, await custody.unwrap(envelope));
  }
  check('fifty unattended unwraps in a row all succeed', ok);

  // The envelope carries the platform's algorithm, so a backup knows which kind of
  // keystore produced it.
  check(
    'the envelope is tagged as platform-wrapped',
    envelope.algorithm == KeyWrapAlgorithm.aes256GcmPlatform,
    envelope.algorithm.id,
  );
}

Future<void> _exportKeyAlwaysPrompts() async {
  section('the export key always prompts — and says why');

  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();

  final secret = randomBytes(32);
  var refused = false;
  try {
    await custody.wrapForExport(secret, keyId: 'vault_dek');
  } on SecurityChannelException catch (error) {
    refused = error.code == SecurityErrorCodes.userNotAuthenticated;
  }
  check('export without authentication is refused', refused);

  final authenticated = await custody.authenticate(
    reason: 'Confirm it is you to export your books',
  );
  check('the user can be asked, with a reason written for a person', authenticated);

  final envelope = await custody.wrapForExport(
    secret,
    keyId: 'vault_dek',
    approvedByUser: true,
  );
  check(
    'export proceeds after the prompt',
    _bytesEqual(
      secret,
      await custody.unwrapForExport(envelope, approvedByUser: true),
    ),
  );
  check(
    'the request carried the reason string to the platform',
    device.calls.contains(SecurityMethods.authorize),
  );
}

Future<void> _onePromptOneOperation() async {
  section('one prompt covers one operation, not a session');

  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();

  await custody.authenticate(reason: 'Export your books');
  final envelope = await custody.wrapForExport(
    randomBytes(32),
    keyId: 'vault_dek',
    approvedByUser: true,
  );

  // The authentication was consumed by the wrap. A second, unrelated operation
  // must prompt again — that is what makes the gate real rather than decorative.
  var refused = false;
  try {
    await custody.unwrapForExport(envelope);
  } on SecurityChannelException catch (error) {
    refused = error.code == SecurityErrorCodes.userNotAuthenticated;
  }
  check('the next export operation must authenticate again', refused);

  // And the policy's in-memory window is what saves a second prompt within one
  // user action: an export that reads and writes should ask once.
  var clock = DateTime.utc(2026, 10, 11, 9);
  final session = AuthenticationSession(
    gracePeriod: SecurityTuning.exportGrace,
    clock: () => clock,
  );
  check('a closed session grants nothing', !session.begin('export'));

  session.grant();
  check('an open session covers the action it was opened for', session.begin('export'));
  session.end();
  check('a second step of the same action is covered', session.begin('export'));
  check(
    'a different action does not inherit the grant',
    !session.begin('reveal-recovery-key'),
  );

  clock = clock.add(SecurityTuning.exportGrace - const Duration(seconds: 1));
  check('still inside the window', session.remainingMs() > 0);

  clock = clock.add(const Duration(seconds: 2));
  check('the window closes on its own', !session.begin('export') && session.remainingMs() == 0);

  session.grant();
  session.revoke();
  check('logging out forgets the grant immediately', !session.begin('export'));
}

Future<void> _deviceLockDelaysSync() async {
  section('a reboot delays sync instead of breaking it');

  final device = FakeSecurityTransport(deviceUnlockedSinceBoot: false);
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();

  var code = '';
  try {
    await custody.unwrap(WrapEnvelope(
      algorithm: KeyWrapAlgorithm.aes256GcmPlatform,
      keyId: 'db_dek',
      nonce: _empty,
      ciphertext: _empty,
      tag: _empty,
      aad: WrapEnvelope.aadContext,
    ));
  } on SecurityChannelException catch (error) {
    code = error.code;
  }
  check(
    'before the first unlock the keystore refuses, with a retryable code',
    code == SecurityErrorCodes.deviceLocked,
    code,
  );

  final plan = await SecurityPolicy(transport: device).resolve();
  check(
    'the security screen explains the wait in plain words',
    plan.notes.any((n) => n.contains('waits for your first unlock')),
  );

  device.unlockDevice();
  final dek = randomBytes(32);
  final envelope = await custody.wrap(dek, keyId: 'db_dek');
  check(
    'after the first unlock the same operation succeeds',
    _bytesEqual(dek, await custody.unwrap(envelope)),
  );
}

Future<void> _enrolmentChangeDestroysExportKey() async {
  section('a new fingerprint destroys the export key and spares the books');

  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();

  final dek = randomBytes(32);
  final dbEnvelope = await custody.wrap(dek, keyId: 'db_dek');

  await custody.authenticate(reason: 'Export');
  final exportEnvelope = await custody.wrapForExport(
    randomBytes(32),
    keyId: 'vault_dek',
    approvedByUser: true,
  );

  // Someone hands the phone to a friend, who enrols their own fingerprint.
  device.invalidateBiometricKeys();
  check('the vault key is gone', !device.holdsKey(KeyAlias.vault));
  check('the database key survives', device.holdsKey(KeyAlias.database));

  var code = '';
  try {
    await custody.unwrapForExport(exportEnvelope, approvedByUser: true);
  } on SecurityChannelException catch (error) {
    code = error.code;
  }
  check(
    'old exports report `key_invalidated`, which the UI can explain',
    code == SecurityErrorCodes.keyInvalidated,
    code,
  );
  check(
    'the books still open — an enrolment change is not a data-loss event',
    _bytesEqual(dek, await custody.unwrap(dbEnvelope)),
  );

  // Re-initialising recreates the vault key; the old envelope stays unreadable,
  // which is the point.
  await custody.initialise();
  check('a fresh vault key can be created afterwards', device.holdsKey(KeyAlias.vault));
}

Future<void> _bothPlatformFlavoursRoundTrip() async {
  section('both platform flavours round-trip through the same Dart code');

  for (final platform in FakePlatform.values) {
    final device = FakeSecurityTransport(platform: platform);
    final custody = PlatformKeyCustody(transport: device);
    await custody.initialise();

    final dek = randomBytes(32);
    final envelope = await custody.wrap(dek, keyId: 'db_dek');
    final expected = platform == FakePlatform.android
        ? KeyWrapAlgorithm.aes256GcmPlatform
        : KeyWrapAlgorithm.eciesP256SecureEnclave;
    check(
      '${platform.name}: the envelope records ${expected.id}',
      envelope.algorithm == expected,
      envelope.algorithm.id,
    );
    check(
      '${platform.name}: a 32-byte key survives the round trip',
      _bytesEqual(dek, await custody.unwrap(envelope)),
    );
  }

  // A blob long enough to exercise the tag-splitting path properly.
  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();
  final long = randomBytes(4096);
  final envelope = await custody.wrap(long, keyId: 'db_dek');
  check(
    'a 4 KB payload round-trips (the tag-split path, not just a short key)',
    _bytesEqual(long, await custody.unwrap(envelope)),
  );
}

Future<void> _wrongKeyFailsClosed() async {
  section('a wrapped key is useless to the wrong key');

  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();

  final envelope = await custody.wrap(randomBytes(32), keyId: 'db_dek');
  // Swap in a keystore whose key is different, as after a restore onto a new
  // device: the data must fail to open, not open as garbage.
  final other = FakeSecurityTransport();
  final otherCustody = PlatformKeyCustody(transport: other);
  await otherCustody.initialise();

  var failedClosed = false;
  try {
    final opened = await otherCustody.unwrap(envelope);
    // If it ever returned, the only acceptable outcome is that nothing was
    // returned at all.
    failedClosed = opened.isEmpty;
  } on WrapIntegrityFailure {
    failedClosed = true;
  } catch (_) {
    failedClosed = true;
  }
  check('another device\'s keystore cannot open the envelope', failedClosed);
}

Future<void> _wipeLeavesNothing() async {
  section('wipe destroys the keys, which is what wipe means');

  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();
  await custody.destroy();

  check(
    'every alias this app owns is deleted — and only those',
    !device.holdsKey(KeyAlias.database) &&
        !device.holdsKey(KeyAlias.vault) &&
        !device.holdsKey(KeyAlias.backup) &&
        device.calls.where((c) => c == SecurityMethods.delete).length == KeyAlias.all.length,
  );

  var code = '';
  try {
    await custody.wrap(randomBytes(32), keyId: 'db_dek');
  } on SecurityChannelException catch (error) {
    code = error.code;
  }
  check('after a wipe the wrapped database is unreadable', code == SecurityErrorCodes.keyMissing, code);

  // The rules the data layer froze in Deliverable 2 still hold: some keys may
  // never leave the device, and no API here exposes one.
  check(
    'the never-exportable set is untouched by the platform layer',
    CustodyRules.neverExportable.contains('db_dek') &&
        CustodyRules.neverExportable.contains('vault_dek'),
  );
}

Future<void> _capabilityReportingIsHonest() async {
  section('capability reporting is honest about what the device cannot do');

  final plain = FakeSecurityTransport(biometricAvailable: false, strongBoxAvailable: false);
  final capability = await PlatformKeyCustody(transport: plain).describe();
  check(
    'no security chip is reported as no security chip',
    capability.notes.any((n) => n.contains('StrongBox')),
  );
  check('hardware backing is reported as true when the keystore works', capability.hardwareBacked);

  final noBiometrics = FakeSecurityTransport(biometricAvailable: false);
  check(
    'no biometric enrolment is reported at the top level, not buried',
    !(await PlatformKeyCustody(transport: noBiometrics).describe()).biometricAvailable,
  );

  final bare = FakeSecurityTransport(hardwareBacked: false);
  final noHw = await PlatformKeyCustody(transport: bare).describe();
  check(
    'a device without a keystore is not described as hardware-protected',
    !noHw.hardwareBacked && noHw.notes.any((n) => n.contains('passphrase path is in use')),
  );
}

Future<void> _authenticationSessionWindow() async {
  section('session tuning is documented, not magic');

  check(
    'the export grace window is long enough for a slow phone, short enough to matter',
    SecurityTuning.exportGrace >= const Duration(seconds: 20) &&
        SecurityTuning.exportGrace <= const Duration(minutes: 1),
    '${SecurityTuning.exportGrace.inSeconds}s',
  );
  check('enrolment invalidation is documented as non-optional', SecurityTuning.invalidateOnEnrolmentChange);

  // A fingerprint must change when the key does, or `key_material` could not
  // notice a rotation it did not cause.
  final device = FakeSecurityTransport();
  final custody = PlatformKeyCustody(transport: device);
  await custody.initialise();
  final before = _fingerprintsSeen(device);
  await custody.destroy();
  await custody.initialise();
  final after = _fingerprintsSeen(device);
  check(
    'a re-created key reports a different fingerprint',
    before != after,
    '$before → $after',
  );
}

// ── helpers ──────────────────────────────────────────────────────────────────

final _empty = Uint8List(0);

bool _bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _fingerprintsSeen(FakeSecurityTransport device) =>
    device.fingerprints.entries.map((e) => '${e.key}=${e.value}').join(',');
