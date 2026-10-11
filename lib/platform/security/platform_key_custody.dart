/// KhataPro · the platform custody implementation: Android Keystore / iOS
/// Keychain + Secure Enclave.
///
/// ## The design question this file answers
///
/// *"Background sync must be able to open the database without a biometric prompt
/// every single time — but the key must still be hardware-bound."*
///
/// Those two requirements are only in tension if one key does both jobs. So there
/// are **two**, with different lifetimes and different gates:
///
/// | alias | key | gate | who uses it |
/// | --- | --- | --- | --- |
/// | `khata/db` | hardware key, non-biometric | device unlocked at least once since boot (`AfterFirstUnlock` on iOS; `setUserAuthenticationRequired(false)` on Android) | opening the SQLCipher database, including from a background sync worker |
/// | `khata/vault` | hardware key, **biometric** | fresh biometric per use, invalidated when enrolment changes | export/share, "show recovery key", anything that carries the user's books *out* of the app |
///
/// The shopkeeper is asked for a fingerprint when they export their books, not
/// every time the app syncs in the background. That is the honest trade, and it is
/// the opposite of the usual mistake — putting the whole database behind a
/// per-launch prompt, then disabling the prompt because it annoyed people.
///
/// ## What this class does *not* do
///
/// It never returns key material to Dart. The only operations are `wrap` and
/// `unwrap`; the platform holds the KEK and applies it. A stolen `key_material`
/// row is therefore useless without the device, and a compromised Dart isolate
/// cannot ask for the KEK — only for a decryption the hardware may refuse.
library;

import 'dart:typed_data';

import '../../core/errors/khata_exception.dart';
import '../../core/security/key_custody.dart';
import '../../core/security/wraps.dart';
import 'security_transport.dart';

/// Alias naming: one namespace, an explicit purpose in the name. The suffix is
/// load-bearing — a device that once had `khata/db` must find it again after an
/// update, so these strings are as stable as the schema.
abstract final class KeyAlias {
  /// Non-biometric, `AfterFirstUnlock`. The database DEK is wrapped with this.
  static const String database = 'khata/db/v1';

  /// Biometric, invalidated on enrolment change. Used for export-class work.
  static const String vault = 'khata/vault/v1';

  /// Non-biometric. Wraps the key used to encrypt backup packs bound for the
  /// user's Drive/iCloud — a background upload must not need a fingerprint.
  static const String backup = 'khata/backup/v1';

  /// The aliases this app owns, for wipe (`deleteAll` must not touch other apps,
  /// which the platform enforces anyway, but it must not miss one either).
  static const List<String> all = [database, vault, backup];
}

/// Which gate a wrap/unwrap needs.
enum KeyGate {
  /// Usable whenever the device has been unlocked since boot.
  afterFirstUnlock,

  /// Requires a fresh user authentication for every use.
  biometricPerUse,
}

/// What the device reported about itself. Deliberately factual — the Security
/// screen shows these verbatim, including the unflattering ones.
final class SecurityCapabilities {
  const SecurityCapabilities({
    required this.hardwareBacked,
    required this.biometricAvailable,
    required this.strongBoxAvailable,
    required this.deviceUnlockedSinceBoot,
    required this.presentAliases,
    this.notes = const <String>[],
  });

  final bool hardwareBacked;
  final bool biometricAvailable;

  /// Android StrongBox (a dedicated security chip) or the iOS Secure Enclave.
  final bool strongBoxAvailable;

  final bool deviceUnlockedSinceBoot;
  final Set<String> presentAliases;
  final List<String> notes;

  static SecurityCapabilities fromMap(Map<String, Object?> map) =>
      SecurityCapabilities(
        hardwareBacked: map['hardwareBacked'] == true,
        biometricAvailable: map['biometricAvailable'] == true,
        strongBoxAvailable: map['strongBoxAvailable'] == true,
        deviceUnlockedSinceBoot: map['deviceUnlockedSinceBoot'] != false,
        presentAliases: {
          for (final alias in (map['presentAliases'] as List?) ?? const [])
            '$alias',
        },
        notes: [for (final note in (map['notes'] as List?) ?? const []) '$note'],
      );
}

/// Hardware-backed custody, over the platform channel.
///
/// Usable in three states, and it says which one it is in:
///  * **ready** — keys ensured, wrapping works;
///  * **needsAuthentication** — the vault alias exists but requires a prompt;
///  * **unavailable** — no hardware keystore: the ladder must fall back to
///    [PassphraseKeyCustody], and `describe()` reports that honestly rather than
///    pretending the books are hardware-protected.
final class PlatformKeyCustody implements KeyCustody {
  PlatformKeyCustody({
    required SecurityTransport transport,
    this.preferStrongBox = true,
  }) : _transport = transport;

  final SecurityTransport _transport;

  /// Try the dedicated security chip first, then a TEE key. Never fail because
  /// StrongBox is absent — it is absent on most mid-range phones.
  final bool preferStrongBox;

  CustodyLevel _level = CustodyLevel.hardwareDevice;
  String _kekId = KeyAlias.database;
  SecurityCapabilities? _capabilities;
  var _initialised = false;

  /// True once [initialise] has run and the database alias exists.
  bool get isReady => _initialised;

  SecurityCapabilities? get capabilities => _capabilities;

  @override
  CustodyLevel get level => _level;

  @override
  String get kekId => _kekId;

  /// Probes the device, then creates any missing alias. Idempotent: a second call
  /// on a configured device must not rotate keys that the database is already
  /// wrapped with — the harness asserts exactly that.
  Future<void> initialise({bool requireBiometricForVault = true}) async {
    final probe = SecurityCapabilities.fromMap(
      await _transport.invoke(SecurityMethods.capabilities),
    );
    _capabilities = probe;

    if (!probe.hardwareBacked) {
      _level = CustodyLevel.passphraseWrapped;
      _initialised = false;
      return;
    }

    // Database + backup aliases: no prompt, so a background worker can unwrap.
    for (final alias in [KeyAlias.database, KeyAlias.backup]) {
      await _ensure(alias, gate: KeyGate.afterFirstUnlock);
    }
    // Vault alias: prompt per use. Skipped when the device has no enrolment —
    // creating a biometric-bound key without biometrics would produce a key
    // nothing can ever unlock.
    if (requireBiometricForVault && probe.biometricAvailable) {
      await _ensure(KeyAlias.vault, gate: KeyGate.biometricPerUse);
      _level = CustodyLevel.hardwareBiometric;
    } else {
      _level = CustodyLevel.hardwareDevice;
    }

    _kekId = KeyAlias.database;
    _initialised = true;
  }

  Future<String> _ensure(String alias, {required KeyGate gate}) async {
    final result = await _transport.invoke(SecurityMethods.ensureKey, {
      'alias': alias,
      'requireBiometric': gate == KeyGate.biometricPerUse,
      'preferStrongBox': preferStrongBox,
    });
    final fingerprint = '${result['fingerprint'] ?? ''}';
    if (fingerprint.isEmpty) {
      throw InvariantViolation(
        invariantCode: 'SEC-4',
        message: 'the platform created $alias but reported no fingerprint, so a '
            'key rotation would go unnoticed',
      );
    }
    return fingerprint;
  }

  /// Wraps with the **database** alias by default: the caller that needs the
  /// vault gate passes [gate].
  ///
  /// The envelope is a [WrapEnvelope] with [KeyWrapAlgorithm.aes256GcmPlatform] —
  /// the algorithm id reserved for exactly this path — carrying the platform's IV
  /// and ciphertext, with the GCM tag appended to the ciphertext (the platform
  /// side returns `iv || ciphertext || tag` split out here, so the envelope layout
  /// stays identical to the software path and a backup can be restored on a device
  /// that uses a different custody backend).
  @override
  Future<WrapEnvelope> wrap(
    Uint8List dek, {
    required String keyId,
    KeyGate gate = KeyGate.afterFirstUnlock,
    String? alias,
    bool approvedByUser = false,
  }) async {
    final target = alias ?? _aliasFor(gate);
    final result = await _transport.invoke(SecurityMethods.wrap, {
      'alias': target,
      'plaintext': SecurityBytes.toBase64(dek),
      // Only meaningful for a biometric alias: it tells the platform that this
      // operation belongs to a flow the user just authenticated, so one export
      // prompts once instead of once per operation.
      'alreadyAuthorized': approvedByUser,
    });

    final algorithm =
        '${result['algorithm'] ?? ''}' == KeyWrapAlgorithm.eciesP256SecureEnclave.id
            ? KeyWrapAlgorithm.eciesP256SecureEnclave
            : KeyWrapAlgorithm.aes256GcmPlatform;
    final iv = SecurityBytes.fromBase64(result['iv']);
    final sealed = SecurityBytes.fromBase64(result['ciphertext']);
    if (algorithm == KeyWrapAlgorithm.aes256GcmPlatform && sealed.length < 16) {
      throw InvariantViolation(
        invariantCode: 'SEC-5',
        message: 'the platform returned ${sealed.length} bytes for a wrapped key; '
            'an AES-GCM ciphertext cannot be shorter than its tag',
      );
    }
    // Android returns ciphertext||tag and the tag is split off so the envelope
    // layout matches the software path. iOS returns a self-contained ECIES blob
    // (ephemeral public key included), which needs no splitting: its scheme is
    // recorded in `algorithm` and the whole blob stays in `ciphertext`.
    final Uint8List tag;
    final Uint8List ciphertext;
    if (algorithm == KeyWrapAlgorithm.aes256GcmPlatform) {
      tag = Uint8List.sublistView(sealed, sealed.length - 16);
      ciphertext = Uint8List.sublistView(sealed, 0, sealed.length - 16);
    } else {
      tag = Uint8List(0);
      ciphertext = sealed;
    }

    return WrapEnvelope(
      algorithm: algorithm,
      keyId: keyId,
      nonce: iv,
      ciphertext: ciphertext,
      tag: tag,
      aad: WrapEnvelope.aadContext,
    );
  }

  @override
  Future<Uint8List> unwrap(
    WrapEnvelope envelope, {
    KeyGate? gate,
    String? alias,
    bool approvedByUser = false,
  }) async {
    // Both platform algorithms mean "the keystore holds this key":
    //   · aes256GcmPlatform — Android Keystore AES-GCM
    //   · eciesP256SecureEnclave — iOS Secure Enclave EC P-256 + ECIES
    // Anything else was wrapped by a software KEK and the platform keystore has
    // no way to open it, however tempting it is to try.
    const platformAlgorithms = {
      KeyWrapAlgorithm.aes256GcmPlatform,
      KeyWrapAlgorithm.eciesP256SecureEnclave,
    };
    if (!platformAlgorithms.contains(envelope.algorithm)) {
      throw InvariantViolation(
        invariantCode: 'SEC-6',
        message: 'this envelope was wrapped by ${envelope.algorithm.id}, which '
            'the platform keystore cannot open. Restore it with the custody that '
            'created it (a passphrase), or re-wrap it on this device.',
      );
    }

    final target = alias ?? _aliasFor(gate ?? KeyGate.afterFirstUnlock);
    final sealed = Uint8List(envelope.ciphertext.length + envelope.tag.length)
      ..setRange(0, envelope.ciphertext.length, envelope.ciphertext)
      ..setRange(envelope.ciphertext.length, envelope.ciphertext.length + envelope.tag.length,
          envelope.tag);

    final result = await _transport.invoke(SecurityMethods.unwrap, {
      'alias': target,
      'iv': SecurityBytes.toBase64(envelope.nonce),
      'ciphertext': SecurityBytes.toBase64(sealed),
      // The platform shows its own prompt when the key demands one; this flag
      // only tells a *biometric* alias whether the caller already authenticated
      // in this session, so a single export does not prompt twice.
      'alreadyAuthorized': approvedByUser,
    });
    return SecurityBytes.fromBase64(result['plaintext']);
  }

  /// Wraps with the vault alias and requires a fresh authentication — call
  /// [authenticate] first, and pass `approvedByUser: true` so the prompt the user
  /// just answered covers this operation.
  Future<WrapEnvelope> wrapForExport(
    Uint8List payload, {
    required String keyId,
    bool approvedByUser = false,
  }) =>
      wrap(payload,
          keyId: keyId,
          gate: KeyGate.biometricPerUse,
          alias: KeyAlias.vault,
          approvedByUser: approvedByUser);

  /// Unwraps with the vault alias, refusing when the user has not authenticated.
  Future<Uint8List> unwrapForExport(WrapEnvelope envelope, {bool approvedByUser = false}) =>
      unwrap(envelope, gate: KeyGate.biometricPerUse, alias: KeyAlias.vault,
          approvedByUser: approvedByUser);

  /// Asks the platform to authenticate the user now (a prompt the *policy* asked
  /// for, with a reason string written for a shopkeeper, not for a developer).
  Future<bool> authenticate({required String reason}) async {
    try {
      final result = await _transport.invoke(SecurityMethods.authorize, {
        'alias': KeyAlias.vault,
        'reason': reason,
      });
      return result['authenticated'] != false;
    } on SecurityChannelException catch (error) {
      if (error.isLockedOrPrompt) return false;
      rethrow;
    }
  }

  @override
  Future<void> destroy() async {
    // Wipe means wipe: every alias this app owns, on both platforms. The
    // database's own rows are irrelevant after this — its DEK is unreadable.
    for (final alias in KeyAlias.all) {
      await _transport.invoke(SecurityMethods.delete, {'alias': alias});
    }
    _initialised = false;
    _capabilities = null;
  }

  @override
  Future<CustodyCapability> describe() async {
    final probe = _capabilities ??
        SecurityCapabilities.fromMap(
          await _transport.invoke(SecurityMethods.capabilities),
        );
    final notes = [...probe.notes];
    if (!probe.hardwareBacked) {
      notes.add('No hardware keystore on this device — the passphrase path is in use.');
    } else if (!probe.strongBoxAvailable) {
      notes.add('No dedicated security chip (StrongBox/Secure Enclave); keys live in '
          'the device TEE, which is still not extractable.');
    }
    if (!probe.deviceUnlockedSinceBoot) {
      notes.add('Background sync waits for the first unlock after a restart — that is '
          'the trade for not asking for a fingerprint every time.');
    }
    if (!probe.biometricAvailable) {
      notes.add('No biometrics enrolled, so export is protected by the passphrase.');
    }
    return CustodyCapability(
      level: _level,
      hardwareBacked: probe.hardwareBacked,
      biometricAvailable: probe.biometricAvailable,
      strongBoxAvailable: probe.strongBoxAvailable,
      notes: notes,
    );
  }

  String _aliasFor(KeyGate gate) =>
      gate == KeyGate.biometricPerUse ? KeyAlias.vault : KeyAlias.database;
}
