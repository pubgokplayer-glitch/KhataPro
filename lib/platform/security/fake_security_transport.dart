/// KhataPro · a fake platform keystore with the *real* semantics.
///
/// This is a test double, but not a stub: it refuses, invalidates and locks in the
/// same situations the real Keystore and Keychain do, because those behaviours are
/// exactly what the custody policy has to survive. A double that always succeeds
/// would let a broken ladder pass its tests and then lock a shopkeeper out of his
/// own books on a real phone.
///
/// Modelled, faithfully:
///
///  * **Opaque handles** — a caller can ask for a wrap or an unwrap, never for the
///    key. There is no getter, mirroring `CustodyRules.neverExportable`.
///  * **Idempotent `ensureKey`** — an existing alias keeps its key and its
///    fingerprint; a second call never rotates it out from under a wrapped DEK.
///  * **Device lock** — before the first unlock after a reboot, every
///    after-first-unlock operation fails with `device_locked`, then works.
///  * **Authentication** — a biometric alias fails `user_not_authenticated` until
///    `authorize` has been called, and its authorisation is consumed by one
///    operation unless `alreadyAuthorized` is passed.
///  * **Enrolment invalidation** — `invalidateBiometricKey()` reproduces "a new
///    fingerprint was enrolled": the vault key is destroyed and later unwraps fail
///    `key_invalidated`. The database key is untouched, which is the whole point of
///    having two.
///  * **Two platform flavours** — Android returns `iv + ciphertext||tag` under the
///    GCM algorithm; iOS returns a self-contained ECIES blob with an empty IV. Both
///    must round-trip through the same Dart code.
///  * **No hardware** — `hardwareBacked: false` makes the ladder step down.
///
/// The sealing itself uses the repository's software AEAD, because a fake needs
/// *a* cipher, not the platform's; what is being tested is the policy around it.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/security/hasher.dart';
import '../../core/security/wraps.dart';
import 'security_transport.dart';

/// Which platform the fake is pretending to be.
enum FakePlatform {
  android,
  ios;

  String get wrapAlgorithmId => switch (this) {
        FakePlatform.android => KeyWrapAlgorithm.aes256GcmPlatform.id,
        FakePlatform.ios => KeyWrapAlgorithm.eciesP256SecureEnclave.id,
      };
}

/// The fake device.
final class FakeSecurityTransport implements SecurityTransport {
  FakeSecurityTransport({
    this.platform = FakePlatform.android,
    this.hardwareBacked = true,
    this.biometricAvailable = true,
    this.strongBoxAvailable = false,
    this.deviceUnlockedSinceBoot = true,
  });

  FakePlatform platform;
  bool hardwareBacked;
  bool biometricAvailable;
  bool strongBoxAvailable;
  bool deviceUnlockedSinceBoot;

  /// One random-but-stable KEK per alias. Never handed to a caller: the map is
  /// private and no method returns a key.
  final Map<String, Uint8List> _keks = {};
  final Map<String, String> _fingerprints = {};
  final Set<String> _requiresBiometric = {};

  /// Aliases destroyed by an enrolment change. Kept as tombstones because the real
  /// platform reports `key_invalidated` for those, not `key_missing` — and the
  /// difference is the user's whole recovery story: "your fingerprint changed" is a
  /// different message from "this backup belongs to another device".
  final Set<String> _invalidated = {};

  /// Authorisations granted by [authorize], consumed by the next operation unless
  /// the caller passes `alreadyAuthorized`.
  final Map<String, bool> _authorised = {};

  /// Every method call, for assertions about *how* the policy behaved rather than
  /// only what it returned.
  final List<String> calls = [];

  /// Number of times a key was actually generated. The idempotence test reads it:
  /// a second `ensureKey` must not increase this.
  int keyGenerations = 0;

  @override
  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    calls.add(method);
    final alias = '${args?['alias'] ?? ''}';

    switch (method) {
      case SecurityMethods.capabilities:
        return {
          'hardwareBacked': hardwareBacked,
          'biometricAvailable': biometricAvailable,
          'strongBoxAvailable': strongBoxAvailable,
          'deviceUnlockedSinceBoot': deviceUnlockedSinceBoot,
          'presentAliases': _keks.keys.toList(),
          'notes': const <String>[],
        };

      case SecurityMethods.hasKey:
        return {'present': _keks.containsKey(alias)};

      case SecurityMethods.ensureKey:
        if (!hardwareBacked) {
          throw SecurityChannelException(
            SecurityErrorCodes.hardwareUnavailable,
            'this fake device has no keystore',
          );
        }
        final requireBiometric = args?['requireBiometric'] == true;
        if (requireBiometric && !biometricAvailable) {
          // Creating a biometric-bound key with nothing enrolled would make a key
          // nothing can unlock; a real device refuses, and so does this one.
          throw SecurityChannelException(
            SecurityErrorCodes.hardwareUnavailable,
            'no biometrics enrolled',
          );
        }
        if (!_keks.containsKey(alias)) {
          _keks[alias] = randomBytes(32);
          _fingerprints[alias] = _fingerprintOf(alias);
          keyGenerations += 1;
        }
        if (requireBiometric) _requiresBiometric.add(alias);
        _invalidated.remove(alias);
        return {
          'fingerprint': _fingerprints[alias],
          'created': false,
          'strongBox': false,
        };

      case SecurityMethods.delete:
        _keks.remove(alias);
        _fingerprints.remove(alias);
        _requiresBiometric.remove(alias);
        _authorised.remove(alias);
        return const <String, Object?>{};

      case SecurityMethods.wrap:
        return _wrap(alias, args);

      case SecurityMethods.unwrap:
        return _unwrap(alias, args);

      case SecurityMethods.authorize:
        if (args?['reason'] == null) {
          throw SecurityChannelException(
            SecurityErrorCodes.unimplemented,
            'a prompt without a reason would be a prompt nobody can read',
          );
        }
        _authorised[alias] = true;
        return {'authenticated': true};

      default:
        throw SecurityChannelException(
          SecurityErrorCodes.unimplemented,
          'the fake device does not implement $method',
        );
    }
  }

  // ── simulated device events ──────────────────────────────────────────────

  /// The user set a passcode for the first time, or unlocked after a reboot.
  void unlockDevice() => deviceUnlockedSinceBoot = true;

  /// A reboot, or the state right after one.
  void lockDeviceUntilFirstUnlock() => deviceUnlockedSinceBoot = false;

  /// "A new fingerprint was enrolled." On Android the biometric keys are destroyed
  /// outright; on iOS they are invalidated the same way. The database key survives,
  /// which is exactly why the two-key design exists.
  void invalidateBiometricKeys() {
    for (final alias in _requiresBiometric.toList()) {
      _keks.remove(alias);
      _fingerprints.remove(alias);
      _authorised.remove(alias);
      _invalidated.add(alias);
      // The *enrolment* requirement is gone with the key; a re-created key is what
      // the caller must ask for, and it will be created biometric-bound again.
      _requiresBiometric.remove(alias);
    }
  }

  /// True when the alias still holds a usable key.
  bool holdsKey(String alias) => _keks.containsKey(alias);

  /// True when the alias was destroyed by an enrolment change and has not been
  /// re-created since.
  bool isInvalidated(String alias) => _invalidated.contains(alias);

  /// Alias → fingerprint, for tests that assert a key was *not* rotated.
  Map<String, String> get fingerprints => Map.unmodifiable(_fingerprints);

  // ── internals ────────────────────────────────────────────────────────────

  Map<String, Object?> _wrap(String alias, Map<String, Object?>? args) {
    _checkUsable(alias);
    final kek = _keks[alias];
    if (kek == null) {
      throw SecurityChannelException(SecurityErrorCodes.keyMissing, 'no key for $alias');
    }
    _requireAuthentication(alias, args);
    final plaintext = SecurityBytes.fromBase64(args?['plaintext']);

    final envelope = const AeadKeyWrap().seal(
      kek: kek,
      plaintext: plaintext,
      keyId: alias,
    );

    // The tag is a 32-byte HMAC here; the Dart side splits a trailing tag only for
    // the GCM flavour and re-joins it on the way back, so the byte string survives
    // the round trip byte for byte.
    final sealed = Uint8List.fromList([...envelope.ciphertext, ...envelope.tag]);
    final blob = Uint8List.fromList([...envelope.nonce, ...sealed]);

    return switch (platform) {
      FakePlatform.android => {
          'iv': SecurityBytes.toBase64(envelope.nonce),
          'ciphertext': SecurityBytes.toBase64(sealed),
          'algorithm': platform.wrapAlgorithmId,
        },
      FakePlatform.ios => {
          'iv': '',
          'ciphertext': SecurityBytes.toBase64(blob),
          'algorithm': platform.wrapAlgorithmId,
        },
    };
  }

  Map<String, Object?> _unwrap(String alias, Map<String, Object?>? args) {
    _checkUsable(alias);
    final kek = _keks[alias];
    if (kek == null) {
      throw SecurityChannelException(SecurityErrorCodes.keyMissing, 'no key for $alias');
    }

    Uint8List nonce;
    Uint8List sealed;
    switch (platform) {
      case FakePlatform.android:
        nonce = SecurityBytes.fromBase64(args?['iv']);
        sealed = SecurityBytes.fromBase64(args?['ciphertext']);
      case FakePlatform.ios:
        final blob = SecurityBytes.fromBase64(args?['ciphertext']);
        nonce = Uint8List.sublistView(blob, 0, 16);
        sealed = Uint8List.sublistView(blob, 16);
    }
    if (sealed.length <= 32) {
      throw SecurityChannelException(
        SecurityErrorCodes.keyMissing,
        'the wrapped blob is too short to authenticate',
      );
    }
    final ciphertext = Uint8List.sublistView(sealed, 0, sealed.length - 32);
    final tag = Uint8List.sublistView(sealed, sealed.length - 32);

    final envelope = WrapEnvelope(
      algorithm: KeyWrapAlgorithm.aes256CtrHmac,
      keyId: alias,
      nonce: nonce,
      ciphertext: ciphertext,
      tag: tag,
      aad: WrapEnvelope.aadContext,
    );

    final plaintext = const AeadKeyWrap().open(kek: kek, envelope: envelope);

    _requireAuthentication(alias, args);
    return {'plaintext': SecurityBytes.toBase64(plaintext)};
  }

  /// A biometric key's authorisation is good for one operation on Android
  /// (`setUserAuthenticationParameters(0, …)` means *every* use) and per operation
  /// on iOS. The fake enforces the stricter of the two, so the policy cannot pass
  /// its tests on the strength of a laxer double than the real device.
  void _requireAuthentication(String alias, Map<String, Object?>? args) {
    if (!_requiresBiometric.contains(alias)) return;
    if (args?['alreadyAuthorized'] == true) {
      _authorised.remove(alias);
      return;
    }
    if (_authorised.remove(alias) == true) return;
    throw SecurityChannelException(
      SecurityErrorCodes.userNotAuthenticated,
      'the vault key needs a fresh authentication',
    );
  }

  /// Reproduces the refusals a real device makes before it makes any others.
  void _checkUsable(String alias) {
    if (_invalidated.contains(alias)) {
      throw SecurityChannelException(
        SecurityErrorCodes.keyInvalidated,
        'the biometric enrolment changed, which destroyed $alias',
      );
    }
    if (!deviceUnlockedSinceBoot) {
      throw SecurityChannelException(
        SecurityErrorCodes.deviceLocked,
        'the device has not been unlocked since it started, so $alias is not usable yet',
      );
    }
  }

  String _fingerprintOf(String alias) {
    // Derived from the key so it changes exactly when the key does — a fingerprint
    // that stayed constant across a rotation would defeat its own purpose.
    final kek = _keks[alias]!;
    return base64Url.encode(kek.sublist(0, 8));
  }
}
