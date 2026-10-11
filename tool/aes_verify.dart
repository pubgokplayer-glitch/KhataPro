/// KhataPro · differential test for the hand-written AES-256 / CTR.
///
/// Vectors come from OpenSSL 3.5.7 and NIST SP 800-38A. This matters more than
/// it looks: a subtly wrong S-box or key schedule still produces output that
/// looks random, still decrypts correctly against itself, and would therefore
/// pass every round-trip test the app can perform on its own. Only an external
/// oracle detects it — and if it were wrong, the user's key would be wrapped
/// under a cipher nobody else can open, discovered only on restore day.
///
///   dart run tool/aes_verify.dart
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../lib/core/security/aes.dart';

int _passed = 0;
final List<String> _failures = <String>[];

void main(List<String> args) {
  final path = args.firstWhere((a) => !a.startsWith('--'),
      orElse: () => 'assets/testdata/aes_vectors.json');
  final vectors = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  print('');
  print('  KhataPro · AES-256 vs OpenSSL 3.5.7 / NIST SP 800-38A');
  print('  ${'─' * 72}');

  print('\n  AES-256 single block (key schedule + rounds + MixColumns)');
  for (final case_ in (vectors['ecb'] as List).cast<Map<String, dynamic>>()) {
    final key = _unhex(case_['key'] as String);
    final block = _unhex(case_['plain'] as String);
    Aes256(key).encryptBlock(block);
    final actual = _hex(block);
    final label = (case_['note'] as String?) ?? 'random key/block';
    _check(label, actual == case_['cipher'],
        detail: actual == case_['cipher'] ? null : '$actual != ${case_['cipher']}');
  }

  print('\n  AES-256-CTR (keystream generation, counter carries, refills)');
  for (final case_ in (vectors['ctr'] as List).cast<Map<String, dynamic>>()) {
    final key = _unhex(case_['key'] as String);
    final iv = _unhex(case_['iv'] as String);
    final length = case_['length'] as int;

    if (case_.containsKey('plain')) {
      final plain = _unhex(case_['plain'] as String);
      final cipher = Uint8List.fromList(plain);
      AesCtr(key: key, iv: iv).apply(cipher);
      _check('${case_['note'] ?? '$length B message'} · ciphertext', _hex(cipher) == case_['cipher'],
          detail: _hex(cipher) == case_['cipher'] ? null : '${_hex(cipher)} != ${case_['cipher']}');
      // and back again
      final roundTrip = Uint8List.fromList(cipher);
      AesCtr(key: key, iv: iv).apply(roundTrip);
      _check('${case_['note'] ?? '$length B message'} · decrypts to the original',
          _hex(roundTrip) == case_['plain']);
    } else {
      // The reference input was all zeros, so the output IS the keystream.
      final zeros = Uint8List(length);
      AesCtr(key: key, iv: iv).apply(zeros);
      _check('$length-byte keystream from IV ${case_['iv']}',
          _hex(zeros) == case_['keystream'],
          detail: _hex(zeros) == case_['keystream'] ? null : 'mismatch');
    }
  }

  print('\n  Properties the wrapping codec depends on');
  final key = Uint8List.fromList(List.generate(32, (i) => (i * 11 + 3) & 0xFF));
  final iv = Uint8List.fromList(List.generate(16, (i) => (i * 7 + 1) & 0xFF));
  final message = Uint8List.fromList(List.generate(500, (i) => (i * 13 + 5) & 0xFF));

  // Chunked application must equal whole-message application: the codec streams
  // rows out of SQLite in whatever sizes the page cache hands it.
  final whole = Uint8List.fromList(message);
  AesCtr(key: key, iv: iv).apply(whole);
  final chunked = Uint8List.fromList(message);
  final ctr = AesCtr(key: key, iv: iv);
  for (var i = 0; i < chunked.length; i += 17) {
    ctr.apply(Uint8List.sublistView(chunked, i, (i + 17).clamp(0, chunked.length)));
  }
  _check('CTR is streaming-invariant (17-byte chunks == whole buffer)',
      _hex(chunked) == _hex(whole));

  // A different counter block must give entirely different keystream.
  final other = Uint8List.fromList(message);
  final otherIv = Uint8List.fromList(iv)..[15] ^= 0x01;
  AesCtr(key: key, iv: otherIv).apply(other);
  var differing = 0;
  for (var i = 0; i < 16; i++) {
    if (other[i] != whole[i]) differing++;
  }
  _check('one-bit IV change scrambles the whole first block ($differing/16 bytes differ)',
      differing >= 12);

  // The S-box is generated from its definition; check it against its known rows.
  final sBox = Aes256.sBox;
  _check('S-box row 0 matches FIPS-197 (63 7c 77 7b f2 6b 6f c5)',
      _hex(Uint8List.fromList(sBox.sublist(0, 8))) == '637c777bf26b6fc5');
  _check('S-box row 5 matches FIPS-197 (53 d1 00 ed 20 fc b1 5b)',
      _hex(Uint8List.fromList(sBox.sublist(0x50, 0x58))) == '53d100ed20fcb15b');
  _check('S-box is a permutation (all 256 values present)', () {
    final seen = List.filled(256, false);
    for (final value in sBox) {
      if (seen[value]) return false;
      seen[value] = true;
    }
    return seen.every((s) => s);
  }());

  print('');
  if (_failures.isEmpty) {
    print('  ✓ all $_passed checks passed');
    print('');
  } else {
    print('  ✗ ${_failures.length} of ${_passed + _failures.length} checks FAILED');
    for (final failure in _failures) {
      print('      · $failure');
    }
    print('');
    exitCode = 1;
  }
}

void _check(String what, bool condition, {String? detail}) {
  if (condition) {
    _passed++;
    print('    ✓ $what');
  } else {
    _failures.add(what);
    print('    ✗ $what${detail == null ? '' : ' — $detail'}');
  }
}

Uint8List _unhex(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
