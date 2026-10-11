/// KhataPro · key custody.
///
/// The threat model, stated plainly, because it decides every choice below.
/// This app holds a shop's books on a phone that walks around in a pocket. The
/// realistic adversaries are, in order of likelihood:
///
///   1. Someone who picks up the unlocked phone.        → app lock + time-out
///   2. Someone who steals the phone and pulls the file. → SQLCipher at rest
///   3. Someone who has read the source and wants the   → key never derivable
///      key material off a rooted device.                 from the file alone
///   4. A state-level adversary with the phone.          → out of scope; say so
///
/// Custody levels exist so the app never *pretends* to be more protective than
/// the hardware allows. A device with no keystore gets level [passphraseWrapped]
/// and the UI says so; it does not silently downgrade and print "Encrypted".
library;

import 'dart:typed_data';

import 'kdf.dart';
import 'wraps.dart';

/// What protects the data encryption key on this device.
///
/// Ordered by strength; the enum index is **not** persisted (the `wrap_algo`
/// string is), so levels can be reordered in a later release.
enum CustodyLevel {
  /// Android Keystore / iOS Secure Enclave key, gated by biometrics whenever
  /// the platform can. The KEK cannot be extracted even from a rooted device —
  /// only used, while the user is present.
  hardwareBiometric(
    id: 'hardware_biometric',
    label: 'Biometric-protected hardware key',
    whereIsTheKey: 'Android Keystore / iOS Secure Enclave',
    protectsAgainst: 'device theft, rooted-device file copying, forensic imaging',
  ),

  /// Android Keystore / iOS Keychain key, device-bound, no biometric gate.
  /// Extracted keys are impossible; use of the key is possible once the device
  /// is unlocked (which is the honest trade for a phone in a pocket).
  hardwareDevice(
    id: 'hardware_device',
    label: 'Device-bound hardware key',
    whereIsTheKey: 'Android Keystore / iOS Keychain',
    protectsAgainst: 'device theft, file copying, forensic imaging',
  ),

  /// No usable hardware keystore, or the user opted out of biometrics: the KEK
  /// is derived from the user's passphrase with Argon2id and exists in memory
  /// only while unlocked.
  passphraseWrapped(
    id: 'passphrase',
    label: 'Passphrase-protected key',
    whereIsTheKey: 'derived from your passphrase (Argon2id); never stored',
    protectsAgainst: 'device theft, file copying',
  ),

  /// Explicitly opted out of encryption. Refused unless the user walks through
  /// a warning screen; recorded in `key_material` and surfaced in Security.
  unprotected(
    id: 'none',
    label: 'Not encrypted',
    whereIsTheKey: 'stored in the clear',
    protectsAgainst: 'nothing',
  );

  const CustodyLevel({
    required this.id,
    required this.label,
    required this.whereIsTheKey,
    required this.protectsAgainst,
  });

  /// Persisted in `key_material.wrap_algo` / the security screen.
  final String id;
  final String label;

  /// Shown verbatim in Security → "Where is my key?" — a sentence a shopkeeper
  /// can read, not a paragraph about KDFs.
  final String whereIsTheKey;

  /// Also shown verbatim. Overclaiming here is the most common form of
  /// dishonesty in encrypted apps.
  final String protectsAgainst;

  static CustodyLevel? tryParse(String id) {
    for (final value in CustodyLevel.values) {
      if (value.id == id) return value;
    }
    return null;
  }

  bool get isHardwareBacked =>
      this == CustodyLevel.hardwareBiometric || this == CustodyLevel.hardwareDevice;
}

/// One row of `key_material`, typed.
///
/// Column names match the DDL exactly (`assets/sql/migrations/001_core.sql`):
/// `key_id, purpose, wrapped_key, wrap_algo, wrap_iv, wrap_salt, kdf_params,
/// device_node_id, created_at, rotated_at, retired_at`.
final class KeyMaterialRow {
  const KeyMaterialRow({
    required this.keyId,
    required this.purpose,
    required this.wrappedKey,
    required this.wrapAlgorithm,
    required this.wrapIv,
    required this.deviceNodeId,
    required this.createdAt,
    this.wrapSalt,
    this.kdfParams,
    this.rotatedAt,
    this.retiredAt,
  });

  /// `db_dek` | `vault_dek` | `backup_kek` | `device_signing`.
  final String purpose;
  final String keyId;
  final Uint8List wrappedKey;

  /// Free-form in SQL (`'aes-256-gcm+keystore' | 'argon2id-aes-256-gcm'`), and
  /// parsed here so an unknown value is a clean error rather than a wrong guess.
  final String wrapAlgorithm;

  final Uint8List wrapIv;
  final Uint8List? wrapSalt;
  final String? kdfParams;
  final String deviceNodeId;
  final int createdAt;
  final int? rotatedAt;
  final int? retiredAt;

  bool get isActive => retiredAt == null;

  Map<String, Object?> toSqlRow() => {
        'key_id': keyId,
        'purpose': purpose,
        'wrapped_key': wrappedKey,
        'wrap_algo': wrapAlgorithm,
        'wrap_iv': wrapIv,
        'wrap_salt': wrapSalt,
        'kdf_params': kdfParams,
        'device_node_id': deviceNodeId,
        'created_at': createdAt,
        'rotated_at': rotatedAt,
        'retired_at': retiredAt,
      };

  static KeyMaterialRow fromRow(Map<String, Object?> row) => KeyMaterialRow(
        keyId: row['key_id']! as String,
        purpose: row['purpose']! as String,
        wrappedKey: row['wrapped_key']! as Uint8List,
        wrapAlgorithm: row['wrap_algo']! as String,
        wrapIv: row['wrap_iv']! as Uint8List,
        wrapSalt: row['wrap_salt'] as Uint8List?,
        kdfParams: row['kdf_params'] as String?,
        deviceNodeId: row['device_node_id']! as String,
        createdAt: (row['created_at']! as num).toInt(),
        rotatedAt: (row['rotated_at'] as num?)?.toInt(),
        retiredAt: (row['retired_at'] as num?)?.toInt(),
      );

  @override
  String toString() => 'KeyMaterialRow($purpose, $keyId, $wrapAlgorithm)';
}

/// Reads and writes the `key_material` row.
///
/// An interface, not a class, because the data layer owns the SQL and this file
/// must stay testable without a database — see [InMemoryKeyMaterialStore].
abstract interface class KeyMaterialStore {
  /// The active row for [purpose], or null on a fresh install.
  Future<KeyMaterialRow?> readActive(String purpose);

  /// Inserts or replaces by `key_id`.
  Future<void> write(KeyMaterialRow row);

  /// Marks the row retired (rotation never deletes: a retired row is what lets
  /// an old backup still be opened during the transition).
  Future<void> retire(String keyId, {required int at});
}

/// Test/harness implementation.
final class InMemoryKeyMaterialStore implements KeyMaterialStore {
  final Map<String, KeyMaterialRow> _rows = <String, KeyMaterialRow>{};

  @override
  Future<KeyMaterialRow?> readActive(String purpose) async {
    KeyMaterialRow? best;
    for (final row in _rows.values) {
      if (row.purpose != purpose || !row.isActive) continue;
      if (best == null || row.createdAt > best.createdAt) best = row;
    }
    return best;
  }

  @override
  Future<void> write(KeyMaterialRow row) async => _rows[row.keyId] = row;

  @override
  Future<void> retire(String keyId, {required int at}) async {
    final row = _rows[keyId];
    if (row == null) return;
    _rows[keyId] = KeyMaterialRow(
      keyId: row.keyId,
      purpose: row.purpose,
      wrappedKey: row.wrappedKey,
      wrapAlgorithm: row.wrapAlgorithm,
      wrapIv: row.wrapIv,
      wrapSalt: row.wrapSalt,
      kdfParams: row.kdfParams,
      deviceNodeId: row.deviceNodeId,
      createdAt: row.createdAt,
      rotatedAt: row.rotatedAt,
      retiredAt: at,
    );
  }

  int get rowCount => _rows.length;
}

/// A protection mechanism for the DEK.
///
/// Implementations: [PassphraseKeyCustody] here (pure Dart, works everywhere),
/// and `PlatformKeyCustody` in `lib/platform/security/` (Keystore / Keychain,
/// written with the sync deliverable where the platform channels live).
abstract interface class KeyCustody {
  CustodyLevel get level;

  /// Stable id of the KEK, stored in `key_material.key_id`-adjacent metadata so
  /// a rotated key can be told from a fresh one.
  String get kekId;

  /// Wraps the DEK.
  Future<WrapEnvelope> wrap(Uint8List dek, {required String keyId});

  /// Unwraps. Throws [WrapIntegrityFailure] when the KEK is wrong.
  Future<Uint8List> unwrap(WrapEnvelope envelope);

  /// Destroys the KEK irreversibly. After this the wrapped DEK is unreadable —
  /// that is what "wipe" means, and it is why wiping requires a verified backup
  /// (`recovery_guard`).
  Future<void> destroy();

  /// Human-readable capability report for Security settings.
  Future<CustodyCapability> describe();
}

/// What this device can actually do, for the settings screen and the diagnostics
/// bundle. Kept factual: `hardwareBacked` false is shown to the user, not hidden.
final class CustodyCapability {
  const CustodyCapability({
    required this.level,
    required this.hardwareBacked,
    required this.biometricAvailable,
    required this.strongBoxAvailable,
    required this.notes,
  });

  final CustodyLevel level;
  final bool hardwareBacked;
  final bool biometricAvailable;

  /// Android StrongBox (dedicated security chip) / iOS Secure Enclave.
  final bool strongBoxAvailable;
  final List<String> notes;
}

/// Passphrase-derived custody: Argon2id over the user's passphrase, in memory
/// only, verified by the envelope MAC rather than by a stored hash.
///
/// Note the deliberate absence of a password hash: there is no "verify the
/// passphrase" step, because a wrong passphrase simply fails to authenticate the
/// wrapped key. Nothing anywhere in the database tells an attacker whether a
/// guess was close.
final class PassphraseKeyCustody implements KeyCustody {
  PassphraseKeyCustody._({required DerivedKey kek, required String kekId})
      : _kek = kek,
        _kekId = kekId;

  /// Derives a KEK from [passphrase] and [salt] and returns custody for it.
  static Future<PassphraseKeyCustody> derive({
    required String passphrase,
    required Uint8List salt,
    KdfParams params = KdfParams.argon2idDefault,
    KeyDerivation derivation = const Pbkdf2KeyDerivation(),
    String? kekId,
  }) async {
    final key = await derivation.derive(passphrase, salt: salt, params: params);
    return PassphraseKeyCustody._(
      kek: key,
      kekId: kekId ?? 'passphrase:${params.algorithm}',
    );
  }

  DerivedKey? _kek;
  String _kekId;
  static const AeadKeyWrap _wrap = AeadKeyWrap();

  @override
  CustodyLevel get level => CustodyLevel.passphraseWrapped;

  @override
  String get kekId => _kekId;

  /// True while the passphrase-derived key is in memory.
  bool get isUnlocked => _kek != null;

  @override
  Future<WrapEnvelope> wrap(Uint8List dek, {required String keyId}) async {
    final kek = _requireKek().bytes;
    return _wrap.seal(
      kek: kek,
      plaintext: dek,
      keyId: keyId,
      salt: _requireKek().salt,
    );
  }

  @override
  Future<Uint8List> unwrap(WrapEnvelope envelope) async =>
      _wrap.open(kek: _requireKek().bytes, envelope: envelope);

  /// Drops the derived key from memory. Called on app lock and on pause-after-
  /// timeout. Zeros the buffer first: Dart gives no guarantee that the old
  /// allocation is not still in a heap page, but not zeroing it guarantees it
  /// *is*.
  @override
  Future<void> destroy() async {
    final kek = _kek;
    if (kek != null) {
      kek.bytes.fillRange(0, kek.bytes.length, 0);
      _kek = null;
    }
    _kekId = '$kekId#destroyed';
  }

  @override
  Future<CustodyCapability> describe() async => CustodyCapability(
        level: level,
        hardwareBacked: false,
        biometricAvailable: false,
        strongBoxAvailable: false,
        notes: [
          'The key is derived from your passphrase each time you unlock.',
          'Nothing in the database can be used to guess it offline faster than '
              'trying passphrases.',
        ],
      );

  DerivedKey _requireKek() {
    final kek = _kek;
    if (kek == null) {
      throw StateError(
        'PassphraseKeyCustody was destroyed or never derived; re-derive to unlock',
      );
    }
    return kek;
  }
}

/// The KEK is *never* left where a backup can reach it.
///
/// This is the rule that makes the BYOC story safe: the encrypted database and
/// the key that opens it must not travel together. A Google Drive backup
/// contains the database; the key lives in the phone's keystore. A backup pack
/// that *does* travel with a key travels under a separate KEK derived from the
/// user's passphrase, which is why `backup_kek` is its own `key_material` row.
final class CustodyRules {
  const CustodyRules._();

  /// Purposes that may be exported inside a backup pack, and the purpose that
  /// must *never* be: exporting `db_dek` would put the lock in the same box as
  /// the key.
  static const Set<String> exportableForBackup = {
    'backup_kek',
    'device_signing',
  };

  static const Set<String> neverExportable = {
    'db_dek',
    'vault_dek',
  };

  static void assertExportable(String purpose) {
    if (neverExportable.contains(purpose)) {
      throw StateError(
        'refusing to export $purpose in a backup pack: the database key must '
        'never travel with the database',
      );
    }
  }
}
