/// KhataPro · key derivation.
///
/// Two algorithms, on purpose:
///
///   1. **Argon2id** — the passphrase → key path. Memory-hard, GPU-hostile,
///      the 2026 default (RFC 9106). Used for the SQLCipher key and for the
///      recovery phrase. Implemented natively (the `argon2` package / platform
///      crypto) because a pure-Dart Argon2id would take seconds.
///
///   2. **PBKDF2-HMAC-SHA256** — the *backup-pack* and *legacy-key* path, and
///      the fallback if native Argon2id is unavailable. Implemented here in
///      pure Dart (no packages) so that:
///        · the backup format can be read by any tool, forever,
///        · a restore never depends on a specific native build,
///        · and the harness can verify the implementation against known
///          vectors without a toolchain.
///
/// Security note on the pure-Dart PBKDF2: it is *not* used to derive the
/// database key on a device that has a native implementation. It is a
/// compatibility/portability path, and its iteration counts are set
/// accordingly ([Pbkdf2KeyDerivation.recommendedIterations]).
///
/// Pure Dart, no `package:` imports.
library;

import 'dart:typed_data';

import 'hasher.dart';

/// Parameters recorded alongside a wrapped key, so a build released later can
/// re-derive without guessing what the current build happens to do.
final class KdfParams {
  const KdfParams({
    required this.algorithm,
    required this.iterations,
    this.memoryKib = 0,
    this.parallelism = 1,
    this.saltBytes = 16,
    this.keyBytes = 32,
    this.version = 1,
  });

  /// `argon2id` | `pbkdf2-hmac-sha256`
  final String algorithm;
  final int iterations;

  /// Argon2id memory cost in KiB (65536 = 64 MiB).
  final int memoryKib;

  /// Argon2id lanes. Kept at 1: more lanes help a server, not a phone.
  final int parallelism;

  final int saltBytes;
  final int keyBytes;
  final int version;

  /// The 2026 mobile default: 64 MiB, t=3, p=1. ~0.4 s on a mid-range phone,
  /// ~0.15 s on a flagship — slow enough to make offline guessing expensive,
  /// fast enough that the user sees a spinner they understand.
  static const KdfParams argon2idDefault = KdfParams(
    algorithm: 'argon2id',
    iterations: 3,
    memoryKib: 65536,
    parallelism: 1,
  );

  /// An older or cheaper device can be re-tuned without a migration: the
  /// parameters live in `key_material.kdf_params`, so the same wrapped key
  /// stays readable.
  static const KdfParams argon2idLite = KdfParams(
    algorithm: 'argon2id',
    iterations: 3,
    memoryKib: 19456, // 19 MiB — RFC 9106's second recommended profile
    parallelism: 1,
  );

  Map<String, Object?> toJson() => {
        'algorithm': algorithm,
        'iterations': iterations,
        'memory_kib': memoryKib,
        'parallelism': parallelism,
        'salt_bytes': saltBytes,
        'key_bytes': keyBytes,
        'version': version,
      };

  static KdfParams fromJson(Map<String, Object?> json) => KdfParams(
        algorithm: json['algorithm']! as String,
        iterations: (json['iterations']! as num).toInt(),
        memoryKib: (json['memory_kib'] as num?)?.toInt() ?? 0,
        parallelism: (json['parallelism'] as num?)?.toInt() ?? 1,
        saltBytes: (json['salt_bytes'] as num?)?.toInt() ?? 16,
        keyBytes: (json['key_bytes'] as num?)?.toInt() ?? 32,
        version: (json['version'] as num?)?.toInt() ?? 1,
      );

  @override
  String toString() => '$algorithm(m=$memoryKib KiB,t=$iterations,p=$parallelism,'
      'v$version,key=$keyBytes B)';
}

/// A derived key: secret bytes plus the parameters that produced them.
final class DerivedKey {
  const DerivedKey({required this.bytes, required this.params, required this.salt});

  final Uint8List bytes;
  final KdfParams params;
  final Uint8List salt;

  int get length => bytes.length;
}

/// What the app needs from a KDF. Swappable so tests use a fast, deterministic
/// implementation while production uses Argon2id.
abstract interface class KeyDerivation {
  /// Derive [params.keyBytes] bytes from [passphrase] and [salt].
  Future<DerivedKey> derive(
    String passphrase, {
    required Uint8List salt,
    required KdfParams params,
  });

  /// Fresh random salt of [params.saltBytes].
  Uint8List newSalt([KdfParams? params]);

  /// Constant-time comparison — the only way two key materials may be compared.
  bool constantTimeEquals(List<int> a, List<int> b);
}

/// PBKDF2-HMAC-SHA256, pure Dart.
///
/// Written from RFC 8018 / RFC 2898 §5.2. Implemented here rather than pulled
/// in as a dependency because it is ~40 lines, has published test vectors, and
/// is on the critical path of "can this user still open their books in five
/// years on a device we have never seen".
final class Pbkdf2KeyDerivation implements KeyDerivation {
  const Pbkdf2KeyDerivation();

  /// Iterations for a *portable* derivation (backup packs, legacy import).
  /// Not a substitute for Argon2id on the primary path: PBKDF2 is GPU-friendly,
  /// so it needs many more iterations for equivalent resistance, and each one
  /// costs the user's battery.
  static const int recommendedIterations = 600000;

  /// Soft cap for the pure-Dart implementation: 10 000 iterations is roughly
  /// 1 s on a mid-range phone. Above this, use the native path.
  static const int portableIterations = 10000;

  static const KdfParams portableParams = KdfParams(
    algorithm: 'pbkdf2-hmac-sha256',
    iterations: portableIterations,
  );

  @override
  Uint8List newSalt([KdfParams? params]) =>
      randomBytes((params ?? portableParams).saltBytes);

  @override
  Future<DerivedKey> derive(
    String passphrase, {
    required Uint8List salt,
    required KdfParams params,
  }) async {
    if (params.algorithm != 'pbkdf2-hmac-sha256') {
      throw UnsupportedError('Pbkdf2KeyDerivation cannot run ${params.algorithm}');
    }
    if (params.iterations < 1) {
      throw ArgumentError.value(params.iterations, 'iterations', 'must be >= 1');
    }
    final bytes = pbkdf2(
      password: passphrase,
      salt: salt,
      iterations: params.iterations,
      keyLength: params.keyBytes,
    );
    return DerivedKey(bytes: bytes, params: params, salt: salt);
  }

  @override
  bool constantTimeEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }
}

/// PBKDF2-HMAC-SHA256, exposed as a free function so the vector tests can call
/// it directly.
Uint8List pbkdf2({
  required String password,
  required Uint8List salt,
  required int iterations,
  required int keyLength,
  bool utf8Password = true,
}) {
  final prf = HmacSha256(key: utf8Password ? utf8Encode(password) : _latin1(password));
  final blockCount = (keyLength + 31) ~/ 32;
  final output = Uint8List(blockCount * 32);

  final block = Uint8List(4);
  for (var i = 1; i <= blockCount; i++) {
    block[0] = (i >> 24) & 0xFF;
    block[1] = (i >> 16) & 0xFF;
    block[2] = (i >> 8) & 0xFF;
    block[3] = i & 0xFF;

    // U1 = PRF(password, salt ‖ INT_BE(i));  Uc = PRF(password, U(c-1))
    var u = prf.compute(_concat(salt, block));
    final accumulator = Uint8List.fromList(u);
    for (var c = 1; c < iterations; c++) {
      u = prf.compute(u);
      for (var k = 0; k < 32; k++) {
        accumulator[k] ^= u[k];
      }
    }
    output.setRange((i - 1) * 32, i * 32, accumulator);
  }
  return Uint8List.sublistView(output, 0, keyLength);
}

Uint8List _latin1(String value) {
  final out = Uint8List(value.length);
  for (var i = 0; i < value.length; i++) {
    out[i] = value.codeUnitAt(i) & 0xFF;
  }
  return out;
}

Uint8List _concat(List<int> a, List<int> b) {
  final out = Uint8List(a.length + b.length)
    ..setRange(0, a.length, a)
    ..setRange(a.length, a.length + b.length, b);
  return out;
}

/// HKDF-SHA256 (RFC 5869) — how one master key becomes several independent
/// keys: the database key, the attachment-vault key and the backup-pack key
/// are three HKDF expansions of the same DEK with different `info` strings.
/// That is why compromising a backup pack cannot decrypt the live database.
/// `info` is raw BYTES, not a string: RFC 5869 treats it as opaque context
/// data, and round-tripping it through UTF-8 would silently change any info
/// value that is not ASCII. (This was caught by the RFC vectors — a String
/// parameter mangled the 0xf0…f9 info of test case 1.) Callers with a human
/// label use [deriveSubkey], which encodes it.
Uint8List hkdfSha256({
  required Uint8List ikm,
  required List<int> info,
  Uint8List? salt,
  int length = 32,
}) {
  // RFC 5869 §2.2: an absent salt is HashLen zero bytes. (An explicitly empty
  // salt hashes identically, because HMAC pads any key below the block size
  // with zeros — so this is a clarity choice, not a behavioural one.)
  final actualSalt = salt ?? Uint8List(32);
  final prk = HmacSha256(key: actualSalt).compute(ikm);

  final output = Uint8List(length);
  var previous = const <int>[];
  var offset = 0;
  var counter = 1;
  while (offset < length) {
    final input = _concat(_concat(previous, info), [counter]);
    previous = HmacSha256(key: prk).compute(input);
    final take = (length - offset) < previous.length ? (length - offset) : previous.length;
    output.setRange(offset, offset + take, previous);
    offset += take;
    counter++;
  }
  return output;
}

/// `hkdfSha256` with a human-readable purpose, so the three derivations can
/// never be accidentally swapped.
enum KeyPurpose {
  database('khata-pro/db/v1'),
  attachments('khata-pro/vault/v1'),
  backupPacks('khata-pro/backup/v1'),
  peerIdentity('khata-pro/peer-ed25519/v1');

  const KeyPurpose(this.info);
  final String info;
}

Uint8List deriveSubkey(Uint8List masterKey, KeyPurpose purpose, {int length = 32}) =>
    hkdfSha256(ikm: masterKey, info: utf8Encode(purpose.info), length: length);
