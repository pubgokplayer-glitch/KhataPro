/// KhataPro · the boot path: keystore → DEK → SQLCipher → `KhataDb.open`.
///
/// `database.dart` has always said "see lib/data/db/database_init.dart" for how a real
/// app gets a `KhataDatabase`. This is that file. It is the only place in the project that
/// is allowed to:
///
///  * read the app documents directory,
///  * talk to the platform keystore at startup,
///  * decide what this device's `node_id` is,
///  * build a [SqlCipherKey] and hand it to [KhataDb.open].
///
/// ## The chicken-and-egg, and how it is resolved
///
/// The database is encrypted with a random 256-bit **DEK**. The DEK is wrapped by a KEK
/// that lives in the Android Keystore / iOS Secure Enclave and cannot be exported. A
/// wrapped key has to be *stored* somewhere, and `key_material` — the table that describes
/// wrapped DEKs — is **inside the database the DEK decrypts**. So:
///
///  * the wrapped DEK lives in a sidecar file next to the database, `khata_pro.key.json`,
///    whose fields are named after `key_material`'s columns on purpose
///    (`wrapped_key`, `wrap_iv`, `wrap_algo`, …), because it *is* the same record — it
///    exists before the database can be opened, which is the only reason it is a file;
///  * the sidecar is ciphertext bound to a non-exportable KEK: copying it to another
///    device yields a file nothing can open, and the same is true of copying the database;
///  * the node id lives in `device.json` for the same reason — [KhataOpenRequest] needs it
///    *before* the open, and every replicated row carries it.
///
/// Nothing here is secret except the passphrase-derived KEK, which never leaves memory.
///
/// ## First run vs. every other run
///
/// First run: generate the DEK, wrap it, write the sidecar, open (SQLCipher creates the
/// file), migrate. Later runs: unwrap the sidecar; **do not** regenerate anything. The
/// expensive part (Argon2id, or the keystore round trip) happens once per process, and the
/// unwrapped DEK is not cached to disk anywhere — see `docs/SYNC.md` §1 for why a
/// background sync can still reach the database without a biometric prompt: the *database*
/// alias is gated `afterFirstUnlock`, only the *vault* alias is `biometricPerUse`.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show AssetManifest, rootBundle;

import '../../core/security/hasher.dart' show randomBytes;
import '../../core/security/kdf.dart';
import '../../core/security/key_custody.dart';
import '../../core/security/sqlcipher_key.dart';
import '../../core/security/wraps.dart';
import '../../platform/security/method_channel_security_transport.dart';
import '../../platform/security/security_policy.dart';
import '../../platform/security/security_transport.dart';
import 'dao/base_dao.dart' show newUuidV7;
import 'database.dart';
import 'migration_runner.dart';

/// Mirrors `pubspec.yaml`'s `version:`. Bumped in the same commit as the pubspec; recorded
/// on every open so a support bundle can tell which build wrote which row.
const String kAppVersion = '1.0.0+1';

/// Wraps the migration files out of the shipped bundle.
///
/// The runner asks for a *directory listing* rather than a hard-coded file list: a build
/// that ships an unknown `NNN_*.sql` must fail loudly at boot, not silently skip it.
final class BundleSqlAssetLoader implements SqlAssetLoader {
  const BundleSqlAssetLoader();

  @override
  Future<String> load(String assetPath) => rootBundle.loadString(assetPath);

  @override
  Future<List<String>> list(String directory) async {
    final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
    final prefix = directory.endsWith('/') ? directory : '$directory/';
    final names = <String>[];
    for (final key in manifest.listAssets()) {
      if (!key.startsWith(prefix)) continue;
      final name = key.substring(prefix.length);
      if (name.endsWith('.sql')) names.add(name);
    }
    names.sort();
    return names;
  }
}

/// This device's identity: the UUIDv7 that every replicated row is stamped with.
final class DeviceIdentity {
  const DeviceIdentity({required this.nodeId, required this.createdAt});

  final String nodeId;
  final DateTime createdAt;

  static const String fileName = 'device.json';

  static File fileIn(Directory dir) => File('${dir.path}/$fileName');

  /// Reads the id, or mints one. Never regenerates an existing id: a new node id looks
  /// like a *new device* to every peer, which would silently fork the CRDT's tie-breaking.
  static Future<DeviceIdentity> loadOrCreate(Directory dir) async {
    final file = fileIn(dir);
    if (file.existsSync()) {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?>) {
        final id = decoded['node_id'];
        if (id is String && id.length == 36) {
          final created = decoded['created_at'];
          return DeviceIdentity(
            nodeId: id,
            createdAt: created is int
                ? DateTime.fromMillisecondsSinceEpoch(created)
                : DateTime.now(),
          );
        }
      }
      // A corrupt identity file is not worth guessing about: renaming it aside and
      // minting a new one keeps the app bootable, and the old id stays on disk for
      // support. The database itself is unaffected — its rows keep their own stamps.
      file.renameSync('${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}');
    }

    final identity = DeviceIdentity(nodeId: newUuidV7(), createdAt: DateTime.now());
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert({
        'node_id': identity.nodeId,
        'created_at': identity.createdAt.millisecondsSinceEpoch,
        'app_version': kAppVersion,
      }),
      flush: true,
    );
    return identity;
  }
}

/// The wrapped DEK, on disk, before the database exists.
///
/// Field names follow `key_material` deliberately (see the library comment); the JSON is
/// versioned so a future format change is detectable rather than a crash.
final class KeyEnvelopeStore {
  const KeyEnvelopeStore(this.dir);

  final Directory dir;

  static const String fileName = 'khata_pro.key.json';
  static const int formatVersion = 1;

  /// The `key_material.key_id` this envelope belongs to.
  static const String dekKeyId = 'db_dek';

  File get file => File('${dir.path}/$fileName');
  bool get exists => file.existsSync();

  /// Returns null when this is a first run.
  Future<WrapEnvelope?> read() async {
    final handle = file;
    if (!handle.existsSync()) return null;
    final decoded = jsonDecode(await handle.readAsString());
    if (decoded is! Map<String, Object?>) {
      throw KhataUnlockFailure(
        reason: UnlockFailureReason.envelopeUnreadable,
        message: '${handle.path} is not a key envelope. Restore the app from a '
            'verified backup, or wipe and start a new book.',
      );
    }
    final version = decoded['format_version'];
    if (version != formatVersion) {
      throw KhataUnlockFailure(
        reason: UnlockFailureReason.envelopeUnreadable,
        message: 'the key envelope is format $version; this build understands '
            '$formatVersion',
      );
    }
    final algorithm = KeyWrapAlgorithm.tryParse('${decoded['wrap_algo']}');
    if (algorithm == null) {
      throw KhataUnlockFailure(
        reason: UnlockFailureReason.envelopeUnreadable,
        message: 'the key envelope names a wrapping algorithm this build does not '
            'know ("${decoded['wrap_algo']}")',
      );
    }
    return WrapEnvelope(
      version: WrapEnvelope.formatVersion,
      algorithm: algorithm,
      keyId: '${decoded['key_id']}',
      nonce: _bytes(decoded['wrap_iv']),
      ciphertext: _bytes(decoded['wrapped_key']),
      tag: _bytes(decoded['wrap_tag']),
      aad: '${decoded['aad']}',
      salt: decoded['wrap_salt'] == null ? null : _bytes(decoded['wrap_salt']),
    );
  }

  /// Written atomically and flushed: a half-written envelope is an unbootable app.
  Future<void> write(WrapEnvelope envelope, {String? kdfParams}) async {
    final payload = const JsonEncoder.withIndent('  ').convert({
      'format_version': formatVersion,
      'key_id': envelope.keyId,
      'purpose': 'db_dek',
      'wrapped_key': base64Encode(envelope.ciphertext),
      'wrap_algo': envelope.algorithm.id,
      'wrap_iv': base64Encode(envelope.nonce),
      'wrap_tag': base64Encode(envelope.tag),
      'wrap_salt': envelope.salt == null ? null : base64Encode(envelope.salt!),
      'aad': envelope.aad,
      'kdf_params': kdfParams,
      'device_node_id': null,
      'written_at': DateTime.now().millisecondsSinceEpoch,
    });
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(payload, flush: true);
    // rename() replaces atomically on POSIX; on Windows it would need delete-then-rename,
    // and this app ships to Android and iOS only.
    await temp.rename(file.path);
  }

  static Uint8List _bytes(Object? value) {
    if (value is! String) {
      throw KhataUnlockFailure(
        reason: UnlockFailureReason.envelopeUnreadable,
        message: 'the key envelope is missing a field (expected base64)',
      );
    }
    return base64Decode(value);
  }
}

/// Why the app could not open the book. Every variant has a different next action for the
/// user, which is the point of not throwing a bare `StateError`.
enum UnlockFailureReason {
  /// No hardware keystore *and* no passphrase supplied: the unlock screen must ask.
  passphraseRequired,

  /// The unlocked key does not match the envelope: wrong passphrase, or the keystore was
  /// re-created by an enrolment change or an app reinstall without restore.
  envelopeNotReadable,

  /// The envelope file itself is damaged or from a newer build.
  envelopeUnreadable,

  /// SQLCipher refused the key: the file is not the database this envelope belongs to.
  databaseKeyRejected,
}

final class KhataUnlockFailure implements Exception {
  const KhataUnlockFailure({required this.reason, required this.message});

  final UnlockFailureReason reason;
  final String message;

  @override
  String toString() => 'KhataUnlockFailure(${reason.name}): $message';
}

/// What a successful boot produced, for the app (and the unlock screen) to hold on to.
final class KhataBoot {
  const KhataBoot({
    required this.khata,
    required this.identity,
    required this.custody,
    required this.plan,
    required this.diagnostics,
    this.createdNow = false,
  });

  final KhataDb khata;
  final DeviceIdentity identity;

  /// The custody actually in use — `null` only when the platform had no keystore and the
  /// caller supplied a passphrase, in which case [plan]'s notes say so.
  final KeyCustody? custody;

  final CustodyPlan plan;
  final BootDiagnostics diagnostics;

  /// True on the run that created the database file. Drives onboarding.
  final bool createdNow;

  /// The database handle every provider is overridden with.
  KhataDatabase get db => khata.db;
}

/// Opens the book.
///
/// Every dependency is injectable so the path can be exercised without a phone, and so
/// the *fake* transport from `lib/platform/security/fake_security_transport.dart` can be
/// used in tests: pass [transport], pass [appDir], and the same code runs.
///
/// [requireEncryption] must stay `true` on a real device. It is settable only because the
/// workspace harness has no SQLCipher build and asserts the fail-closed path instead.
Future<KhataBoot> openKhataDatabase({
  required Directory appDir,
  SecurityTransport? transport,
  SqlAssetLoader assetLoader = const BundleSqlAssetLoader(),
  String? passphrase,
  bool requireEncryption = true,
  bool preferStrongBox = true,
  String platform = '',
  String appVersion = kAppVersion,
}) async {
  final identity = await DeviceIdentity.loadOrCreate(appDir);
  final envelopeStore = KeyEnvelopeStore(appDir);
  final existing = await envelopeStore.read();

  // ── custody ───────────────────────────────────────────────────────────────
  // The ladder lives in SecurityPolicy (and is asserted by security_verify): hardware
  // keystore if the device has one, otherwise the user's passphrase. There is no third
  // option and no silent weakening — `plan.notes` carries the honest sentence the
  // Security screen shows, so the app can never claim "hardware-protected" on a phone
  // that had no keystore.
  final securityTransport = transport ?? MethodChannelSecurityTransport();
  final CustodyPlan plan;
  try {
    plan = await SecurityPolicy(transport: securityTransport).resolve();
  } on SecurityChannelException catch (error) {
    // A *broken* keystore must not be downgraded to "no keystore" (the policy is explicit
    // about this too). It is a bug or a tampered device, not an old phone.
    throw KhataUnlockFailure(
      reason: UnlockFailureReason.envelopeNotReadable,
      message: 'the device keystore failed with ${error.code}. This is not the same '
          'as a phone without a keystore — reinstall the app only after exporting a '
          'backup, because re-creating the app also re-creates the key.',
    );
  }

  // The policy hands back its backend for the hardware path, and `null` when the caller
  // must supply a passphrase-derived one — see `CustodyPlan.backend`'s own documentation.
  KeyCustody? custody = plan.backend;
  var kdfParams = '';
  Uint8List? passphraseSalt;
  if (custody == null) {
    if (passphrase == null || passphrase.isEmpty) {
      throw const KhataUnlockFailure(
        reason: UnlockFailureReason.passphraseRequired,
        message: 'this device has no hardware keystore, so the book is protected by a '
            'passphrase. Enter it to unlock.',
      );
    }
    // The salt is stored in the envelope, so the second run derives the same KEK. On a
    // first run there is no envelope yet: mint the salt now and put it in the envelope
    // written below, or the key would be unrecoverable after a restart.
    const params = KdfParams.argon2idDefault;
    passphraseSalt = existing?.salt ?? const Pbkdf2KeyDerivation().newSalt(params);
    custody = await PassphraseKeyCustody.derive(
      passphrase: passphrase,
      salt: passphraseSalt,
      params: params,
      kekId: KeyEnvelopeStore.dekKeyId,
    );
    kdfParams = jsonEncode(params.toJson());
  }

  // ── the DEK ───────────────────────────────────────────────────────────────
  final Uint8List dek;
  final bool createdNow;
  if (existing == null) {
    dek = randomBytes(32);
    createdNow = true;
    final wrapped = await custody.wrap(dek, keyId: KeyEnvelopeStore.dekKeyId);
    // The salt has to live in the envelope for the passphrase path: without it the next
    // boot derives a different KEK and the database becomes unreadable. `wrap()` cannot
    // fill it in (the KEK is already derived by then), so it is attached here.
    await envelopeStore.write(
      wrapped.salt == null && passphraseSalt != null
          ? _withSalt(wrapped, passphraseSalt)
          : wrapped,
      kdfParams: kdfParams.isEmpty ? null : kdfParams,
    );
  } else {
    createdNow = false;
    try {
      dek = await custody.unwrap(existing);
    } on WrapIntegrityFailure catch (error) {
      throw KhataUnlockFailure(
        reason: UnlockFailureReason.envelopeNotReadable,
        message: 'the stored key could not be opened ($error). If this phone was '
            'reinstalled or its screen lock changed, the keystore key is gone — '
            'restore from a verified backup instead of wiping.',
      );
    }
  }

  // ── open ──────────────────────────────────────────────────────────────────
  final KhataDb khata;
  try {
    khata = await KhataDb.open(KhataOpenRequest(
      databaseFile: File('${appDir.path}/${KhataPaths.databaseFileName}'),
      key: SqlCipherKey.raw(dek),
      nodeId: identity.nodeId,
      platform: platform.isEmpty ? Platform.operatingSystem : platform,
      appVersion: appVersion,
      assetLoader: assetLoader,
      requireEncryption: requireEncryption,
    ));
  } on EncryptionUnavailable catch (error) {
    throw KhataUnlockFailure(
      reason: UnlockFailureReason.databaseKeyRejected,
      message: 'this build cannot open an encrypted database ($error). A release '
          'build must link SQLCipher — see pubspec.yaml `hooks:`.',
    );
  } on SqlCipherOpenFailure catch (error) {
    throw KhataUnlockFailure(
      reason: UnlockFailureReason.databaseKeyRejected,
      message: 'SQLCipher rejected the key for this file ($error). That means the '
          'envelope and the database do not belong together — most often a restore '
          'of one without the other.',
    );
  }

  return KhataBoot(
    khata: khata,
    identity: identity,
    custody: custody,
    plan: plan,
    diagnostics: khata.diagnostics,
    createdNow: createdNow,
  );
}

/// A copy of [envelope] carrying [salt]. [WrapEnvelope] is immutable by design — every
/// field of it is authenticated — so the salt is attached by reconstruction rather than
/// mutation, which also keeps the MAC context (`aad`) identical.
WrapEnvelope _withSalt(WrapEnvelope envelope, Uint8List salt) => WrapEnvelope(
      version: envelope.version,
      algorithm: envelope.algorithm,
      keyId: envelope.keyId,
      nonce: envelope.nonce,
      ciphertext: envelope.ciphertext,
      tag: envelope.tag,
      aad: envelope.aad,
      salt: salt,
    );

/// Where the files live. One place, so the harness and the app cannot disagree.
abstract final class KhataPaths {
  static const String databaseFileName = 'khata_pro.sqlite';
  static const String keyFileName = KeyEnvelopeStore.fileName;
  static const String deviceFileName = DeviceIdentity.fileName;
}
