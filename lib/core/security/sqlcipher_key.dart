/// KhataPro · attaching the SQLCipher key to a raw connection.
///
/// This is the only place in the app that talks to SQLCipher's pragmas, and it
/// is deliberately small, ordered, and verified.
///
/// ## Why the key is passed as a raw key, not a passphrase
///
/// SQLCipher accepts two forms:
///
///   * `PRAGMA key = 'my passphrase'` — SQLCipher runs **PBKDF2-HMAC-SHA512,
///     256 000 iterations** on every single `sqlite3_open`. That is the
///     "expensive key derivation" that makes people believe SQLCipher is slow
///     and that repeatedly opening a connection is a performance disaster.
///   * `PRAGMA key = "x'<64 hex chars>'"` — a **raw 32-byte key**: the KDF is
///     skipped entirely. The expensive derivation has already been paid exactly
///     once, when the DEK was unwrapped from the keystore (see `key_custody.dart`).
///
/// KhataPro always uses the raw form. A consequence worth stating: even though
/// the connection is a strict singleton (see `database.dart`), the cost of a
/// *hypothetical* re-open is not a second KDF — it is a keystore unwrap plus
/// page-cache warm-up. Both are avoided by the singleton, and both are cheap
/// enough that a crash-recovery reopen does not punish the user.
///
/// ## Fail closed, never open
///
/// On a build without SQLCipher, `PRAGMA key` is an *unknown pragma*, which
/// SQLite ignores **silently**. The database would be created unencrypted and
/// nothing would look wrong until someone inspected the file. So [attachTo]
/// probes `cipher_version` and — unless the caller explicitly opts out — throws
/// [EncryptionUnavailable] rather than continuing in the clear. The opt-out
/// exists only for the verification harness, which runs against stock SQLite;
/// no production code path passes it.
library;

import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import 'hasher.dart';

/// What the linked SQLite library actually did.
enum EncryptionMode {
  /// SQLCipher is linked and the key was applied.
  sqlcipher('sqlcipher'),

  /// Stock SQLite: no encryption. Only reachable when a caller passes
  /// `requireEncryption: false` (the harness) — never on a device build.
  none('none');

  const EncryptionMode(this.id);
  final String id;
}

/// Raised when the app was asked to encrypt but the linked library cannot.
class EncryptionUnavailable implements Exception {
  EncryptionUnavailable(this.message);
  final String message;

  @override
  String toString() => 'EncryptionUnavailable: $message';
}

/// Raised when the key is wrong or the file is not a KhataPro database. SQLCipher
/// reports both as "file is not a database", which is intentional: it does not
/// tell an attacker which of the two it was.
class SqlCipherOpenFailure implements Exception {
  SqlCipherOpenFailure(this.message, {this.cause});
  final String message;
  final Object? cause;

  @override
  String toString() => 'SqlCipherOpenFailure: $message';
}

/// A key, in the form SQLCipher wants it.
final class SqlCipherKey {
  /// A raw 32-byte key (256-bit AES). This is the form this app always uses.
  SqlCipherKey.raw(Uint8List key)
      : _raw = Uint8List.fromList(key),
        _passphrase = null {
    if (key.length != 32) {
      throw ArgumentError.value(key.length, 'key.length',
          'SQLCipher raw keys are exactly 32 bytes (256-bit)');
    }
  }

  /// A passphrase. Supported for restoring a database that was created by an
  /// older build or by hand with a passphrase key; the app itself never creates
  /// one this way.
  SqlCipherKey.passphrase(String passphrase)
      : _raw = null,
        _passphrase = passphrase {
    if (passphrase.isEmpty) {
      throw ArgumentError.value(passphrase, 'passphrase', 'must not be empty');
    }
  }

  /// 32 fresh random bytes, for a brand-new database.
  static SqlCipherKey generate() => SqlCipherKey.raw(randomBytes(32));

  final Uint8List? _raw;
  final String? _passphrase;

  bool get isRawKey => _raw != null;

  /// The literal SQL value: `x'…'` or a quoted, escaped string.
  String get pragmaValue {
    final raw = _raw;
    if (raw != null) {
      return "x'${_hex(raw)}'";
    }
    // Single quotes are doubled per SQL string escaping. A passphrase
    // containing a quote must not be able to terminate the literal.
    final escaped = _passphrase!.replaceAll("'", "''");
    return "'$escaped'";
  }

  /// Never print the key. Any diagnostic that includes this object gets a red
  /// flag instead of a credential.
  @override
  String toString() =>
      isRawKey ? 'SqlCipherKey.raw(redacted)' : 'SqlCipherKey.passphrase(redacted)';

  /// Applies the key pragmas to a freshly opened connection and verifies the
  /// result.
  ///
  /// Order matters and is not arbitrary:
  ///   1. `key` first — before any other statement touches the file.
  ///   2. `cipher_page_size` before the first write on a new database, and it
  ///      must match the existing file otherwise.
  ///   3. `kdf_iter` / cipher algorithm pragmas only matter for passphrase
  ///      keys; they are skipped for raw keys (which bypass the KDF) and are
  ///      set explicitly for passphrase keys so a file written by a different
  ///      SQLCipher default still opens.
  ///   4. A probe statement — `SELECT count(*) FROM sqlite_master` — which is
  ///      what actually forces SQLCipher to verify the key. Without it, a wrong
  ///      key is not discovered until the first real query, far from the code
  ///      that could explain it.
  EncryptionMode attachTo(
    Database database, {
    bool requireEncryption = true,
    int pageSize = 4096,
    int kdfIterations = 256000,
    bool memorySecurity = true,
  }) {
    // ── Probe FIRST, before any cipher pragma is issued.
    //
    // On a stock SQLite build `PRAGMA key = x'…'` is not an unknown pragma that
    // gets ignored — the blob literal is a *syntax error*, so the statement
    // throws. Discovering that after attempting the key would mean guessing
    // whether the throw meant "no SQLCipher" or "wrong key". Asking
    // `cipher_version` first makes the two cases unambiguous, and it happens
    // before the file is touched at all.
    var mode = probe(database);

    if (mode == EncryptionMode.none) {
      if (requireEncryption) {
        throw EncryptionUnavailable(
          'the linked SQLite is not SQLCipher, so this database would be '
          'written UNENCRYPTED. Refusing to continue. Enable SQLCipher in '
          'pubspec.yaml under hooks: user_defines: sqlite3: source: sqlcipher, '
          'and rebuild. (requireEncryption: false exists only for the '
          'verification harness, which runs against stock SQLite.)',
        );
      }
      // Harness path: no cipher pragmas at all, so a stock build never sees a
      // statement it cannot parse.
      return EncryptionMode.none;
    }

    try {
      database.execute('PRAGMA key = $pragmaValue');
    } on SqliteException catch (error) {
      throw SqlCipherOpenFailure('PRAGMA key was rejected', cause: error);
    }

    database.execute('PRAGMA cipher_page_size = $pageSize');
    if (!isRawKey) {
      database.execute('PRAGMA kdf_iter = $kdfIterations');
      database.execute('PRAGMA cipher_hmac_algorithm = HMAC_SHA512');
      database.execute('PRAGMA cipher_kdf_algorithm = PBKDF2_HMAC_SHA512');
    }
    if (memorySecurity) {
      // Zeroes SQLCipher's internal key/plaintext buffers. A small CPU cost in
      // exchange for keys not lingering in freed heap memory — which matters
      // most on a device that will be sold on with its storage intact.
      database.execute('PRAGMA cipher_memory_security = ON');
    }

    // Force key validation here, while the error can still be explained: a wrong
    // key and a non-KhataPro file both report "file is not a database", and
    // nothing tells the user which.
    try {
      database.select('SELECT count(*) FROM sqlite_master');
    } on SqliteException catch (error) {
      throw SqlCipherOpenFailure(
        'the database could not be read with this key (wrong key, or the file '
        'is not a KhataPro database)',
        cause: error,
      );
    }

    mode = probe(database);
    return mode;
  }

  /// What the linked library supports. Empty result ⇒ stock SQLite.
  static EncryptionMode probe(Database database) {
    try {
      final rows = database.select('PRAGMA cipher_version');
      if (rows.isEmpty) return EncryptionMode.none;
      final value = rows.first.values.first;
      return (value is String && value.isNotEmpty)
          ? EncryptionMode.sqlcipher
          : EncryptionMode.none;
    } on SqliteException {
      // A build without the pragma at all throws in some configurations.
      return EncryptionMode.none;
    }
  }

  /// The SQLCipher version string, for the diagnostics bundle and Settings.
  static String? cipherVersion(Database database) {
    try {
      final rows = database.select('PRAGMA cipher_version');
      if (rows.isEmpty) return null;
      final value = rows.first.values.first;
      return value is String && value.isNotEmpty ? value : null;
    } on SqliteException {
      return null;
    }
  }
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
