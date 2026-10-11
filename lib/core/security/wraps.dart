/// KhataPro · authenticated key wrapping.
///
/// The data encryption key (DEK) never exists on disk in the clear. It is
/// wrapped by a key-encryption key (KEK) that lives in the platform keystore
/// (Android Keystore / iOS Secure Enclave, when available) or is derived from
/// the user's passphrase (the no-hardware case). This file defines the wrap
/// FORMAT and the software implementation of it.
///
/// Construction: **AES-256-CTR + HMAC-SHA256, encrypt-then-MAC.** The MAC is
/// computed over the envelope header *and* the ciphertext *and* the caller's
/// associated data, and is verified before a single byte is decrypted. That
/// ordering matters: decrypt-then-verify hands an attacker a decryption oracle
/// and is the classic way AEAD gets broken in practice.
///
/// Why not AES-GCM here? On Android and iOS the *platform* performs the wrap
/// (Keystore `AES/GCM/NoPadding`, CryptoKit `AES.GCM`), and this app records
/// `wrap_algo = 'aes-256-gcm+keystore'` and lets the platform do it. The
/// software path exists for: devices with no usable keystore, the passphrase
/// custody level, backup packs, and every non-Flutter tool (restore CLI, the
/// verification harness). It is written to the same interface so the two are
/// interchangeable and testable together.
library;

import 'dart:typed_data';

import 'aes.dart';
import 'hasher.dart';
import 'kdf.dart';

/// How a key was wrapped. Stored verbatim in `key_material.wrap_algo`, so a
/// build released later can always tell how to unwrap what an older build
/// wrote — the difference between "your backup restores" and "your backup is
/// a blob".
enum KeyWrapAlgorithm {
  /// No envelope: the caller holds the raw key (used only by the platform
  /// custody path, where the KEK *is* the keystore entry and SQLCipher receives
  /// a raw key derived from `Keystore.getKey()`).
  none('none'),

  /// Platform-native AEAD: Android Keystore `AES/GCM/NoPadding`, iOS
  /// `AES.GCM` via CryptoKit. Hardware-backed when the device supports it.
  aes256GcmPlatform('aes-256-gcm+keystore'),

  /// The software path defined in this file.
  aes256CtrHmac('aes256-ctr-hmac-sha256'),

  /// AES-256-GCM in pure software, for platforms whose native crypto we do not
  /// link. Kept in the enum so a future revision can populate it without a
  /// format break.
  aes256GcmSoftware('aes-256-gcm');

  const KeyWrapAlgorithm(this.id);

  /// The exact string stored in `key_material.wrap_algo`.
  final String id;

  static KeyWrapAlgorithm? tryParse(String id) {
    for (final value in KeyWrapAlgorithm.values) {
      if (value.id == id) return value;
    }
    return null;
  }
}

/// A wrapped key, as stored in `key_material`: ciphertext + iv + tag + salt,
/// with enough metadata to unwrap on another device or in another language.
final class WrapEnvelope {
  const WrapEnvelope({
    required this.algorithm,
    required this.keyId,
    required this.nonce,
    required this.ciphertext,
    required this.tag,
    required this.aad,
    this.version = formatVersion,
    this.salt,
  });

  /// Bumped only for a breaking layout change; readers must reject unknown
  /// versions rather than guess.
  static const int formatVersion = 1;

  /// Domain separator. Every envelope in this app is bound to this string, so a
  /// wrapped key can never be replayed as a wrapped *backup* or a wrapped
  /// attachment key.
  static const String aadContext = 'khata-pro/dek-wrap/v1';

  final int version;
  final KeyWrapAlgorithm algorithm;

  /// `key_material.key_id` — the row this envelope belongs to.
  final String keyId;

  /// 16 random bytes: the AES-CTR initial counter block.
  final Uint8List nonce;

  /// The wrapped key bytes (32 for a DEK).
  final Uint8List ciphertext;

  /// 32-byte HMAC tag over (header ‖ aad ‖ nonce ‖ ciphertext).
  final Uint8List tag;

  /// Caller-supplied context, always [aadContext] in this app.
  final String aad;

  /// Argon2id salt, when the KEK is passphrase-derived. Also mirrored into
  /// `key_material.wrap_salt` so the SQL row remains self-describing.
  final Uint8List? salt;

  bool get isSoftwareWrapped => algorithm == KeyWrapAlgorithm.aes256CtrHmac;

  /// Canonical bytes covered by the MAC. Field order is fixed and the lengths
  /// are length-prefixed, so no two distinct envelopes can produce the same
  /// authenticated bytes (the classic concatenation ambiguity bug).
  Uint8List macInput(Uint8List ciphertext, Uint8List nonce) {
    final header = utf8Encode(
      '$version|${algorithm.id}|$keyId|$aad|${nonce.length}|${ciphertext.length}',
    );
    return _join([header, nonce, ciphertext]);
  }

  @override
  String toString() => 'WrapEnvelope(${algorithm.id}, key=$keyId, '
      'ct=${ciphertext.length} B, v$version)';
}

/// The software AEAD used for the wrap, for backup packs, and for the
/// attachment vault. One implementation, three callers, one format.
final class AeadKeyWrap {
  const AeadKeyWrap();

  /// MAC key derived from the KEK with a distinct `info` string, so an attacker
  /// who learns the MAC key learns nothing about the encryption key (and the
  /// two can never be confused).
  static const String _macInfo = 'khata-pro/wrap-mac/v1';

  static Uint8List macKeyFor(Uint8List kek) =>
      hkdfSha256(ikm: kek, info: utf8Encode(_macInfo), length: 32);

  /// Wraps [plaintext] under [kek].
  ///
  /// [aad] is authenticated but not encrypted; pass [WrapEnvelope.aadContext]
  /// unless you have a reason, and know that changing it invalidates every
  /// envelope written before the change.
  WrapEnvelope seal({
    required Uint8List kek,
    required Uint8List plaintext,
    required String keyId,
    String aad = WrapEnvelope.aadContext,
    Uint8List? nonce,
    Uint8List? salt,
    KeyWrapAlgorithm algorithm = KeyWrapAlgorithm.aes256CtrHmac,
  }) {
    if (kek.length != 32) {
      throw ArgumentError.value(kek.length, 'kek.length', 'must be 32 bytes');
    }
    final actualNonce = nonce ?? randomBytes(16);
    if (actualNonce.length != 16) {
      throw ArgumentError.value(actualNonce.length, 'nonce.length', 'must be 16 bytes');
    }

    final envelopeForMac = WrapEnvelope(
      algorithm: algorithm,
      keyId: keyId,
      nonce: actualNonce,
      ciphertext: Uint8List(plaintext.length),
      tag: Uint8List(0),
      aad: aad,
      salt: salt,
    );

    final ciphertext = Uint8List.fromList(plaintext);
    _ctr(kek, actualNonce).apply(ciphertext);

    final tag = HmacSha256(key: macKeyFor(kek))
        .compute(envelopeForMac.macInput(ciphertext, actualNonce));

    return WrapEnvelope(
      algorithm: algorithm,
      keyId: keyId,
      nonce: actualNonce,
      ciphertext: ciphertext,
      tag: tag,
      aad: aad,
      salt: salt,
    );
  }

  /// Verifies and unwraps. Throws [WrapIntegrityFailure] if the envelope was
  /// tampered with, truncated, or belongs to a different context — before any
  /// decryption happens.
  Uint8List open({required Uint8List kek, required WrapEnvelope envelope}) {
    if (kek.length != 32) {
      throw ArgumentError.value(kek.length, 'kek.length', 'must be 32 bytes');
    }
    if (envelope.version != WrapEnvelope.formatVersion) {
      throw WrapIntegrityFailure(
        'unsupported wrap format v${envelope.version} '
        '(this build understands v${WrapEnvelope.formatVersion})',
      );
    }
    if (envelope.algorithm != KeyWrapAlgorithm.aes256CtrHmac) {
      throw WrapIntegrityFailure(
        'envelope is ${envelope.algorithm.id}; the software codec only opens '
        '${KeyWrapAlgorithm.aes256CtrHmac.id}',
      );
    }
    if (envelope.tag.length != 32) {
      throw const WrapIntegrityFailure('tag is not 32 bytes: envelope is corrupt');
    }
    if (envelope.nonce.length != 16) {
      throw const WrapIntegrityFailure('nonce is not 16 bytes: envelope is corrupt');
    }

    final expected = HmacSha256(key: macKeyFor(kek))
        .compute(envelope.macInput(envelope.ciphertext, envelope.nonce));
    if (!constantTimeEquals(expected, envelope.tag)) {
      throw const WrapIntegrityFailure(
        'authentication failed — the wrapped key, its metadata or the passphrase '
        'is wrong',
      );
    }

    final plaintext = Uint8List.fromList(envelope.ciphertext);
    _ctr(kek, envelope.nonce).apply(plaintext);
    return plaintext;
  }
}

/// Raised when a wrapped key does not authenticate. Deliberately one exception
/// for "wrong passphrase", "corrupt row" and "tampered file": telling them
/// apart is information an attacker can use, and the user's action (retry, then
/// restore from backup) is the same in all three cases.
class WrapIntegrityFailure implements Exception {
  const WrapIntegrityFailure(this.message);
  final String message;

  @override
  String toString() => 'WrapIntegrityFailure: $message';
}

/// AES-256-CTR with the envelope nonce as the initial counter block.
AesCtr _ctr(Uint8List key, Uint8List nonce) => AesCtr(key: key, iv: nonce);

Uint8List _join(List<List<int>> parts) {
  var total = 0;
  for (final part in parts) {
    total += part.length;
  }
  final out = Uint8List(total);
  var offset = 0;
  for (final part in parts) {
    out.setRange(offset, offset + part.length, part);
    offset += part.length;
  }
  return out;
}
