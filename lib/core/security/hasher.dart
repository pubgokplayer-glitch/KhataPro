/// KhataPro · SHA-256, HMAC-SHA256, and cryptographically strong randomness.
///
/// Hand-written, pure Dart, zero dependencies. That is a deliberate choice with
/// a cost (an auditable surface) and a benefit (the key-derivation and
/// key-storage paths compile and run anywhere — including the verification
/// harness and a future CLI restore tool on a machine with no Flutter).
///
/// The implementation follows FIPS 180-4 for SHA-256 and RFC 2104 for HMAC, and
/// is checked against published vectors plus a differential test against
/// Python's `hashlib`/`hmac` in `tool/crypto_verify.dart`.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// One-shot SHA-256 over arbitrary bytes.
Uint8List sha256(List<int> input) => Sha256().digest(input);

/// Hex digest, lowercase — the form stored in `attachments.sha256_hex`, the
/// audit hash chain and merkle roots.
String sha256Hex(List<int> input) {
  final digest = sha256(input);
  final buffer = StringBuffer();
  for (final byte in digest) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}

/// Streaming SHA-256, so a 200 MB backup pack can be hashed without holding it
/// in memory. Feed with [update], finish with [digest]; an instance is single
/// use after [digest] (which is the only safe contract for a hash in progress).
final class Sha256 {
  Sha256();

  static const List<int> _initialState = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  static const List<int> _roundConstants = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ];

  final Uint32List _state = Uint32List.fromList(_initialState);
  final Uint8List _block = Uint8List(64);
  int _blockLength = 0;
  int _totalLength = 0;
  bool _finalised = false;

  /// Feed more data.
  Sha256 update(List<int> data) {
    if (_finalised) throw StateError('Sha256 has already been finalised');
    _totalLength += data.length;
    var offset = 0;
    while (offset < data.length) {
      final take = math.min(64 - _blockLength, data.length - offset);
      _block.setRange(_blockLength, _blockLength + take, data, offset);
      _blockLength += take;
      offset += take;
      if (_blockLength == 64) {
        _compress(_block);
        _blockLength = 0;
      }
    }
    return this;
  }

  /// Finalises and returns the 32-byte digest. Optionally absorbs [tail] first.
  Uint8List digest([List<int>? tail]) {
    if (tail != null) update(tail);
    if (_finalised) throw StateError('Sha256 has already been finalised');
    _finalised = true;

    final bitLength = _totalLength * 8;

    // Padding: 0x80, then zeros until the block is 56 bytes long, then the
    // 64-bit big-endian bit length — absorbed WITHOUT counting toward the
    // message length (they are padding, not data).
    _block[_blockLength++] = 0x80;
    if (_blockLength > 56) {
      while (_blockLength < 64) {
        _block[_blockLength++] = 0;
      }
      _compress(_block);
      _blockLength = 0;
    }
    while (_blockLength < 56) {
      _block[_blockLength++] = 0;
    }
    for (var i = 0; i < 8; i++) {
      _block[56 + i] = (bitLength >> (56 - 8 * i)) & 0xFF;
    }
    _compress(_block);

    final out = Uint8List(32);
    for (var i = 0; i < 8; i++) {
      out[i * 4] = (_state[i] >> 24) & 0xFF;
      out[i * 4 + 1] = (_state[i] >> 16) & 0xFF;
      out[i * 4 + 2] = (_state[i] >> 8) & 0xFF;
      out[i * 4 + 3] = _state[i] & 0xFF;
    }
    return out;
  }

  void _compress(Uint8List block) {
    final w = Uint32List(64);
    for (var i = 0; i < 16; i++) {
      w[i] = (block[i * 4] << 24) |
          (block[i * 4 + 1] << 16) |
          (block[i * 4 + 2] << 8) |
          block[i * 4 + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }

    var a = _state[0], b = _state[1], c = _state[2], d = _state[3];
    var e = _state[4], f = _state[5], g = _state[6], h = _state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final temp1 = (h + s1 + ch + _roundConstants[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xFFFFFFFF;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xFFFFFFFF;
    }

    _state[0] = (_state[0] + a) & 0xFFFFFFFF;
    _state[1] = (_state[1] + b) & 0xFFFFFFFF;
    _state[2] = (_state[2] + c) & 0xFFFFFFFF;
    _state[3] = (_state[3] + d) & 0xFFFFFFFF;
    _state[4] = (_state[4] + e) & 0xFFFFFFFF;
    _state[5] = (_state[5] + f) & 0xFFFFFFFF;
    _state[6] = (_state[6] + g) & 0xFFFFFFFF;
    _state[7] = (_state[7] + h) & 0xFFFFFFFF;
  }

  static int _rotr(int value, int bits) =>
      ((value >> bits) | (value << (32 - bits))) & 0xFFFFFFFF;
}

/// HMAC-SHA256 (RFC 2104), reusable across many messages — which is what makes
/// PBKDF2's millions of invocations tolerable: the key pads are hashed once.
final class HmacSha256 {
  HmacSha256({required List<int> key}) {
    var actualKey = Uint8List.fromList(key);
    if (actualKey.length > 64) actualKey = sha256(actualKey);
    final padded = Uint8List(64)..setRange(0, actualKey.length, actualKey);
    _innerPad = Uint8List(64);
    _outerPad = Uint8List(64);
    for (var i = 0; i < 64; i++) {
      _innerPad[i] = padded[i] ^ 0x36;
      _outerPad[i] = padded[i] ^ 0x5c;
    }
  }

  late final Uint8List _innerPad;
  late final Uint8List _outerPad;

  Uint8List compute(List<int> message) {
    final innerDigest = (Sha256()
          ..update(_innerPad)
          ..update(message))
        .digest();
    return (Sha256()
          ..update(_outerPad)
          ..update(innerDigest))
        .digest();
  }

  /// Streaming variant for large messages (attachments, backup packs).
  Uint8List computeStreaming(Iterable<List<int>> chunks) {
    final inner = Sha256()..update(_innerPad);
    for (final chunk in chunks) {
      inner.update(chunk);
    }
    return (Sha256()
          ..update(_outerPad)
          ..update(inner.digest()))
        .digest();
  }
}

/// True when `a` and `b` are equal, without leaking where they differ.
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Randomness
// ─────────────────────────────────────────────────────────────────────────────

/// A cryptographically secure random source.
///
/// Key material may **only** come from here. In Flutter, [math.Random.secure]
/// is backed by the platform CSPRNG (`/dev/urandom`, `SecRandomCopyBytes`,
/// `RAND_bytes`). The injectable indirection exists so tests are deterministic
/// and so a hardware-backed source (Keystore `generateRandom`) can be dropped
/// in without touching a single call site.
abstract interface class RandomBytesSource {
  Uint8List next(int length);
}

final class SecureRandomBytesSource implements RandomBytesSource {
  SecureRandomBytesSource() : _random = math.Random.secure();
  final math.Random _random;

  @override
  Uint8List next(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }
}

/// Deterministic source for tests. The constructor throws in release builds
/// (via `assert(false)`) so a predictable key can never ship by accident.
final class DeterministicBytesSource implements RandomBytesSource {
  DeterministicBytesSource(int seed) : _random = math.Random(seed) {
    assert(() {
      throw StateError(
        'DeterministicBytesSource must never be used outside tests: '
        'it would make salts and keys predictable.',
      );
    }());
  }
  final math.Random _random;

  @override
  Uint8List next(int length) {
    final out = Uint8List(length);
    for (var i = 0; i < length; i++) {
      out[i] = _random.nextInt(256);
    }
    return out;
  }
}

RandomBytesSource _randomSource = SecureRandomBytesSource();

/// Overrides the random source (tests only — see [DeterministicBytesSource]).
void setRandomBytesSource(RandomBytesSource source) => _randomSource = source;

/// [length] cryptographically strong random bytes.
Uint8List randomBytes(int length) {
  if (length < 0) throw ArgumentError.value(length, 'length', 'must be >= 0');
  return _randomSource.next(length);
}

// ─────────────────────────────────────────────────────────────────────────────
//  Encodings used by key storage
// ─────────────────────────────────────────────────────────────────────────────

/// Base64url without padding — how keys are written into `key_material` JSON.
String base64UrlNoPad(List<int> bytes) => _base64(bytes, urlSafe: true, padding: false);

/// Standard base64 with padding — how they appear inside backup manifests.
String base64Std(List<int> bytes) => _base64(bytes, urlSafe: false, padding: true);

String _base64(List<int> bytes, {required bool urlSafe, required bool padding}) {
  const stdAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const urlAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  final alphabet = urlSafe ? urlAlphabet : stdAlphabet;
  final buffer = StringBuffer();
  for (var i = 0; i < bytes.length; i += 3) {
    final remaining = bytes.length - i;
    final b0 = bytes[i] & 0xFF;
    final b1 = remaining > 1 ? bytes[i + 1] & 0xFF : 0;
    final b2 = remaining > 2 ? bytes[i + 2] & 0xFF : 0;
    buffer.write(alphabet[b0 >> 2]);
    buffer.write(alphabet[((b0 & 0x03) << 4) | (b1 >> 4)]);
    if (remaining > 1) {
      buffer.write(alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)]);
    } else if (padding) {
      buffer.write('=');
    }
    if (remaining > 2) {
      buffer.write(alphabet[b2 & 0x3F]);
    } else if (padding) {
      buffer.write('=');
    }
  }
  return buffer.toString();
}

/// UTF-8 encoding without `dart:convert`, so this file stays dependency-free.
/// Deliberately strict: lone surrogates are rejected rather than silently
/// replaced, because a mangled passphrase would derive a key that cannot be
/// reproduced on another platform — i.e. an unlocked vault that is permanently
/// unreadable.
Uint8List utf8Encode(String value) {
  final out = Uint8List(4 * value.length);
  var length = 0;
  for (var i = 0; i < value.length; i++) {
    var codePoint = value.codeUnitAt(i);
    if (codePoint >= 0xD800 && codePoint <= 0xDBFF) {
      if (i + 1 >= value.length) {
        throw ArgumentError('utf8Encode: lone high surrogate at index $i');
      }
      final low = value.codeUnitAt(i + 1);
      if (low < 0xDC00 || low > 0xDFFF) {
        throw ArgumentError('utf8Encode: unpaired high surrogate at index $i');
      }
      codePoint = 0x10000 + ((codePoint - 0xD800) << 10) + (low - 0xDC00);
      i++;
    } else if (codePoint >= 0xDC00 && codePoint <= 0xDFFF) {
      throw ArgumentError('utf8Encode: lone low surrogate at index $i');
    }

    if (codePoint < 0x80) {
      out[length++] = codePoint;
    } else if (codePoint < 0x800) {
      out[length++] = 0xC0 | (codePoint >> 6);
      out[length++] = 0x80 | (codePoint & 0x3F);
    } else if (codePoint < 0x10000) {
      out[length++] = 0xE0 | (codePoint >> 12);
      out[length++] = 0x80 | ((codePoint >> 6) & 0x3F);
      out[length++] = 0x80 | (codePoint & 0x3F);
    } else {
      out[length++] = 0xF0 | (codePoint >> 18);
      out[length++] = 0x80 | ((codePoint >> 12) & 0x3F);
      out[length++] = 0x80 | ((codePoint >> 6) & 0x3F);
      out[length++] = 0x80 | (codePoint & 0x3F);
    }
  }
  return Uint8List.sublistView(out, 0, length);
}
