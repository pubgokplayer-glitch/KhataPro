/// KhataPro · the database, as a strict singleton.
///
/// ## Why "strict singleton" is a correctness requirement, not a style choice
///
/// The brief is explicit: repeatedly opening and closing the connection must not
/// happen. Three separate costs make that true here:
///
///   1. **Key work.** Every open walks the key chain: read `key_material`,
///      unwrap the DEK through the keystore (a Keystore round-trip — on Android
///      a `KeyStore.getKey` can take tens of milliseconds), then attach the raw
///      key to the connection. SQLCipher's own PBKDF2 is *not* paid here because
///      the key is passed raw (see `sqlcipher_key.dart`) — but the keystore hop
///      alone is reason enough.
///   2. **Page cache.** 16 MiB of decrypted pages, warmed by the first queries
///      after open. Re-opening discards it, and every re-read pays a SQLCipher
///      page decrypt again.
///   3. **Prepared statements.** The hot paths' statements are prepared once and
///      cached (`cachePreparedStatements: true`). A new connection re-prepares
///      and re-plans all of them.
///
/// `NativeDatabase.createInBackground(..., readPool: 0)` is used **because it
/// means exactly one connection**: the connection lives in a background isolate,
/// the main isolate talks to it over a port, and there is no pool to grow. A
/// non-zero `readPool` spawns extra isolates that each need their own SQLCipher
/// key attached. It is therefore pinned to 0 in [KhataDb.open] and a request
/// asking for more is refused in release builds, not just asserted.
///
/// ## Two isolates, one object graph — and why that shapes this file
///
/// `setup:` runs **inside the database isolate**. `beforeOpen` and every DAO run
/// in the **main isolate**, sending statements across the port. So:
///
///   · `setup:` may only touch the raw connection it is handed (that is where the
///     key is attached — it must be the first statement on that connection).
///   · `beforeOpen` may only use drift statements (`customStatement`,
///     `customSelect`); it must never reach for a raw `sqlite3.Database`, and it
///     *can* safely assign to fields on this object, because this object lives in
///     the main isolate with it. That is how diagnostics get out of the boot
///     sequence without a custom port protocol.
///
/// ## Lifecycle
///
/// ```
///   KhataDb.open(request)  →  KhataDb.instance  →  …  →  KhataDb.close()
/// ```
///
/// `open` is idempotent for the same file: a second call while the first is in
/// flight awaits the same future rather than racing. Opening a *different* file
/// while one is open throws, because two live databases means two writers and,
/// in a ledger, two truths.
library;

import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import '../../core/crdt/hlc_service.dart';
import '../../core/errors/khata_exception.dart';
import '../../core/security/sqlcipher_key.dart';
import 'migration_runner.dart';

/// Everything `open` needs. Passed as one object so a newly required input
/// cannot be forgotten at a call site.
final class KhataOpenRequest {
  const KhataOpenRequest({
    required this.databaseFile,
    required this.key,
    required this.nodeId,
    required this.platform,
    required this.appVersion,
    required this.assetLoader,
    this.requireEncryption = true,
    this.readPool = 0,
    this.hlcPersistence,
  });

  final File databaseFile;

  /// The DEK, already unwrapped. Never logged, never persisted in this form.
  final SqlCipherKey key;

  /// This device's UUIDv7 (`nodes.node_id`) — the CRDT's final tie-breaker.
  final String nodeId;

  /// `android` | `ios` | `macos` | `windows` | `linux` (the CHECK in
  /// `nodes.platform`).
  final String platform;

  final String appVersion;

  /// Where `assets/sql/**` comes from: `rootBundle` on device, the filesystem in
  /// the harness.
  final SqlAssetLoader assetLoader;

  /// Production passes `true`. Only the verification harness passes `false`, so
  /// the whole layer can be exercised against stock SQLite.
  final bool requireEncryption;

  /// Pinned to 0 — see the class docs.
  final int readPool;

  /// `session_flags` by default (local-only, so a restored backup can never
  /// inherit another device's clock). Tests inject an in-memory implementation.
  final HlcPersistence? hlcPersistence;
}

/// A row of the boot-time health report, surfaced in Settings → Diagnostics.
final class BootDiagnostics {
  final List<String> notes = <String>[];
  String? cipherVersion;
  EncryptionMode encryptionMode = EncryptionMode.none;
  MigrationOutcome? migration;
  int? quickCheckErrors;
  List<IntegrityFinding> integrity = const <IntegrityFinding>[];
  int? openMillis;

  bool get hadDirtyOpen => notes.any((n) => n.startsWith('DIRTY_OPEN'));
  bool get hasCriticalFindings => integrity.any((f) => f.isCritical);

  @override
  String toString() => 'BootDiagnostics(${encryptionMode.id}, '
      '${migration ?? 'no migration pass'}, '
      '${integrity.length} findings, ${openMillis}ms)';
}

/// A critical/warning row from `v_integrity_report`.
final class IntegrityFinding {
  const IntegrityFinding({
    required this.severity,
    required this.kind,
    required this.detail,
    this.entityId,
  });

  /// **1 = critical, 2 = warning** — the convention `008_integrity.sql`
  /// documents at the top of its file, and the one `tool/verify_schema.sh`
  /// uses (`rows where severity = 1` are the critical ones). Getting this
  /// backwards means either ignoring a broken ledger or blocking a healthy one,
  /// so it is asserted in test/data/integrity_severity_test.dart rather than
  /// left to a comment.
  final int severity;
  final String kind;
  final String detail;
  final String? entityId;

  bool get isCritical => severity == 1;

  static IntegrityFinding fromRow(QueryRow row) => IntegrityFinding(
        severity: row.read<int>('severity'),
        kind: row.read<String>('kind'),
        detail: row.read<String>('detail'),
        entityId: row.read<String?>('entity_id'),
      );

  @override
  String toString() => '${isCritical ? 'CRITICAL' : 'warning'} $kind: $detail';
}

/// The drift handle: a `GeneratedDatabase` subclass **without** generated table
/// classes. The schema is owned by the `.sql` assets (45 tables, 18 views, 69
/// indexes, 33 triggers — proven by `tool/verify_schema.sh` and 35 SQL contract
/// tests); drift supplies the executor, transactions and statement plumbing.
final class KhataDatabase extends GeneratedDatabase {
  KhataDatabase(super.executor, {
    required this.assetLoader,
    required this.nodeId,
    required this.requireEncryption,
  });

  final SqlAssetLoader assetLoader;
  final String nodeId;
  final bool requireEncryption;

  /// No generated tables, deliberately: drift's schema tooling would otherwise
  /// try to reconcile generated Dart tables with the SQL-defined schema and
  /// report every view, index and trigger as unknown. docs/DB_SCHEMA.md is the
  /// contract that replaces drift codegen, and `tool/verify_schema.sh` counts
  /// the real objects at boot.
  ///
  /// `allSchemaEntities` intentionally inherits its default (`allTables`), so
  /// there is one empty list rather than two that could disagree.
  @override
  Iterable<TableInfo<Table, dynamic>> get allTables =>
      const <TableInfo<Table, dynamic>>[];

  @override
  int get schemaVersion => kLatestSchemaVersion;

  /// The last HLC emitted by this process. Initialised in the constructor so it
  /// exists for DAOs immediately; `beforeOpen` restores persisted logical time
  /// into it before the first user query.
  late final HlcService hlc = HlcService(
    nodeId: nodeId,
    persistence: hlcPersistence ?? DriftHlcPersistence(this),
  );

  /// Injectable for tests.
  HlcPersistence? hlcPersistence;

  /// Filled during `beforeOpen` — see the class docs on isolates.
  final BootDiagnostics diagnostics = BootDiagnostics();

  /// Set once `beforeOpen` has completed. Guarded so a DAO that somehow runs
  /// earlier fails with an explanation rather than a confusing SQL error.
  bool get isReady => _ready;
  bool _ready = false;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (Migrator m) async {
          // Intentionally empty. Table creation belongs to the SQL assets, not
          // to drift codegen — a schema defined twice eventually disagrees with
          // itself. The migration runner creates everything, including on a
          // brand-new file.
        },
        onUpgrade: (Migrator m, int from, int to) async {
          // Same reasoning: the runner owns this. See migration_runner.dart.
        },
        beforeOpen: (OpeningDetails details) async {
          // ── 0 · Which SQLite are we? A build without SQLCipher ignores
          // `PRAGMA key` silently, so this is checked before anything else and
          // is fatal when encryption was requested.
          final cipherRows = await customSelect('PRAGMA cipher_version').get();
          final cipherVersion = cipherRows.isEmpty
              ? null
              : cipherRows.first.data.values.first?.toString();
          diagnostics.cipherVersion =
              (cipherVersion == null || cipherVersion.isEmpty) ? null : cipherVersion;
          diagnostics.encryptionMode = diagnostics.cipherVersion == null
              ? EncryptionMode.none
              : EncryptionMode.sqlcipher;
          if (requireEncryption && diagnostics.encryptionMode == EncryptionMode.none) {
            throw EncryptionUnavailable(
              'this build linked a SQLite without SQLCipher, so the database '
              'would be written UNENCRYPTED. Enable SQLCipher in pubspec.yaml '
              '(hooks: user_defines: sqlite3: source: sqlcipher) and rebuild.',
            );
          }

          // ── 1 · Session pragmas, on every open, before any read or write.
          await customStatement(
              await assetLoader.load('assets/sql/ops/open_pragmas.sql'));

          // ── 2 · Migrations: verbatim SQL, one transaction per file. This runs
          // before the wreckage check because the check itself needs
          // `session_flags`, which does not exist on a brand-new file.
          diagnostics.migration = await _runMigrations();

          // ── 3 · Dirty-open detection. `dirty_open` is set below, once the boot
          // has succeeded, and cleared on a clean close — so finding it set means
          // the previous run died while the database was live.
          final dirty = await _sessionFlag('dirty_open') == '1';
          if (dirty) {
            diagnostics.notes.add(
              'DIRTY_OPEN: the previous run did not close cleanly; running '
              'quick_check and re-deriving the balance cache',
            );
            diagnostics.quickCheckErrors = await _quickCheck();
            await customStatement('BEGIN IMMEDIATE');
            await customStatement(
                await assetLoader.load('assets/sql/ops/rebuild_caches.sql'));
            await customStatement('COMMIT');
          }
          await _setSessionFlag('dirty_open', '1');

          // ── 4 · Logical time, restored before the first write can happen.
          await hlc.load();

          // ── 5 · Expensive statistics work only when the plan cache is cold.
          if (details.wasCreated || dirty) {
            await customStatement('PRAGMA optimize');
          }

          // ── 6 · Read the audited integrity report so the app knows up front
          // whether it may trust its own numbers (see OrderBook.commitChecked).
          diagnostics.integrity = await integrityReport();
          _ready = true;
        },
      );

  /// Applies pending migrations through the same statements drift uses, so the
  /// transaction boundaries are drift's and a failure rolls back cleanly.
  Future<MigrationOutcome> _runMigrations() async {
    final runner = SqlMigrationRunner(loader: assetLoader);
    final started = DateTime.now();

    // The runner reads `schema_meta` through drift here, then applies files.
    final versionRows =
        await customSelect("SELECT value FROM schema_meta WHERE key = 'schema_version'")
            .get()
            .catchError((Object _) => <QueryRow>[]);
    final from = versionRows.isEmpty
        ? 0
        : int.tryParse(versionRows.first.read<String>('value')) ?? 0;

    // Before applying anything: confirm that already-applied files are
    // unchanged, and that no shipped file is unregistered.
    await runner.verifyShippedSet();
    await runner.verifyAppliedChecksums({
      for (final entry in SqlMigrationRunner.knownMigrations.entries)
        if (entry.key <= from) entry.value: await _recordedChecksum(entry.value),
    }..removeWhere((_, checksum) => checksum.isEmpty));

    final applied = <String>[];
    for (final migration in await runner.pendingMigrations(from)) {
      final sql = await assetLoader.load(migration.assetPath);
      await customStatement('BEGIN IMMEDIATE');
      try {
        await customStatement(sql);
        await customStatement(
          "INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES "
          "('migration.${migration.fileName}.sha256', '${migration.checksum}', "
          '${DateTime.now().millisecondsSinceEpoch})',
        );
        await customStatement(
          "INSERT OR REPLACE INTO schema_meta (key, value, updated_at) VALUES "
          "('schema_version', '${migration.version}', "
          '${DateTime.now().millisecondsSinceEpoch})',
        );
        await customStatement('COMMIT');
      } on Object catch (error) {
        await customStatement('ROLLBACK');
        throw MigrationFailed(
          migrationFile: migration.fileName,
          version: migration.version,
          cause: error.toString(),
        );
      }
      applied.add(migration.fileName);
    }

    return MigrationOutcome(
      fromVersion: from,
      toVersion: kLatestSchemaVersion,
      applied: applied,
      durationMs: DateTime.now().difference(started).inMilliseconds,
    );
  }

  /// The audited report from `008_integrity.sql` — the same 15 critical and 6
  /// warning checks `tool/verify_schema.sh` runs, read from Dart so the app can
  /// refuse to trust its own numbers and say so.
  Future<List<IntegrityFinding>> integrityReport() async {
    final rows = await customSelect(
      'SELECT severity, kind, detail, entity_id FROM v_integrity_report',
    ).get();
    return rows.map(IntegrityFinding.fromRow).toList(growable: false);
  }

  /// Critical findings only — what blocks posting a journal entry.
  Future<List<IntegrityFinding>> criticalFindings() async {
    final all = await integrityReport();
    return all.where((f) => f.isCritical).toList(growable: false);
  }

  Future<String> _recordedChecksum(String fileName) async {
    final rows = await customSelect(
      "SELECT value FROM schema_meta WHERE key = 'migration.$fileName.sha256'",
    ).get();
    return rows.isEmpty ? '' : rows.first.read<String>('value');
  }

  Future<String?> _sessionFlag(String key) async {
    final rows = await customSelect(
      'SELECT value FROM session_flags WHERE key = ?',
      variables: [Variable<String>(key)],
    ).get();
    return rows.isEmpty ? null : rows.first.read<String?>('value');
  }

  Future<void> _setSessionFlag(String key, String value) => customStatement(
        'INSERT OR REPLACE INTO session_flags (key, value) VALUES (?, ?)',
        [key, value],
      );

  Future<int> _quickCheck() async {
    final rows = await customSelect('PRAGMA quick_check(1)').get();
    final value = rows.isEmpty ? 'ok' : rows.first.data.values.first?.toString();
    return value == 'ok' ? 0 : 1;
  }
}

/// The singleton owner: one instance per process, one connection per instance.
final class KhataDb {
  KhataDb._(this.db, this._request);

  static KhataDb? _instance;
  static Future<KhataDb>? _opening;

  /// The drift handle every DAO uses.
  final KhataDatabase db;
  final KhataOpenRequest _request;

  BootDiagnostics get diagnostics => db.diagnostics;

  static KhataDb? get maybeInstance => _instance;
  static bool get isOpen => _instance != null;

  /// The open database. Throws if [open] has not completed — a loud failure
  /// beats a lazily-created second connection.
  static KhataDb get instance {
    final instance = _instance;
    if (instance == null) {
      throw StateError(
        'KhataDb.open() has not completed. DAOs must not be constructed before '
        'the database is open — see lib/data/db/database_init.dart.',
      );
    }
    return instance;
  }

  /// Opens the database, or returns the already-open one.
  ///
  /// Two callers racing (a warm-up in `main` and a provider) share one future.
  /// Two callers asking for *different* files is an error: two live databases
  /// means two writers and, in a ledger, two truths.
  static Future<KhataDb> open(KhataOpenRequest request) {
    final existing = _instance;
    if (existing != null) {
      if (existing._request.databaseFile.path != request.databaseFile.path) {
        throw StateError(
          'a KhataPro database is already open at '
          '${existing._request.databaseFile.path}; refusing to open a second '
          'one at ${request.databaseFile.path}. Close the first, or switch '
          'books inside the open database (ledgers table).',
        );
      }
      return Future<KhataDb>.value(existing);
    }
    return _opening ??= _openInternal(request);
  }

  static Future<KhataDb> _openInternal(KhataOpenRequest request) async {
    try {
      return await _openInternalImpl(request);
    } on Object {
      // A failed attempt must not be cached: without this, the first failure
      // (a wrong passphrase, a locked keystore, a refused read pool) would be
      // returned to every later caller as the same completed-with-error future,
      // and "try again" could never work.
      _opening = null;
      rethrow;
    }
  }

  static Future<KhataDb> _openInternalImpl(KhataOpenRequest request) async {
    final started = DateTime.now();
    final file = request.databaseFile;

    if (request.readPool != 0) {
      // Not an `assert`: this must fail in release builds too. A read pool means
      // extra isolates, each needing its own connection and its own key.
      throw const StorageException(
        message: 'readPool must be 0 (exactly one connection). Opening the '
            'database repeatedly is the thing this class exists to prevent.',
        recoverable: false,
      );
    }

    final parent = file.parent;
    if (!parent.existsSync()) {
      parent.createSync(recursive: true);
    }

    final handle = KhataDatabase(
      // One connection, in a background isolate, with the key attached in
      // `setup` — which runs on the connection before anything else touches it.
      NativeDatabase.createInBackground(
        file,
        readPool: 0,
        cachePreparedStatements: true,
        setup: (connection) {
          // The key must be the very first statement on this connection. If the
          // linked SQLite cannot encrypt, this throws inside the isolate and the
          // first query below fails with a message that says so.
          request.key.attachTo(connection, requireEncryption: request.requireEncryption);
        },
        isolateSetup: () {
          // Deliberately empty: SQLCipher arrives through the pubspec `hooks:`
          // block, so the old `open.overrideFor(...)` / 
          // `applyWorkaroundToOpenSqlite3OnOldAndroidVersions()` ritual is gone
          // (see docs/THIRD_PARTY.md).
        },
      ),
      assetLoader: request.assetLoader,
      nodeId: request.nodeId,
      requireEncryption: request.requireEncryption,
    );
    handle.hlcPersistence = request.hlcPersistence;

    final instance = KhataDb._(handle, request);
    try {
      // This is what runs `beforeOpen`: pragmas, migrations, HLC restore,
      // dirty-open recovery, integrity read.
      await handle.customSelect('SELECT 1').get();
    } on Object catch (error, stackTrace) {
      try {
        await handle.close();
      } on Object {
        // Nothing useful to do; the original error is the story.
      }
      _opening = null;
      Error.throwWithStackTrace(
        StorageException(
          message: 'the database could not be opened: $error',
          cause: error,
          recoverable: false,
        ),
        stackTrace,
      );
    }

    handle.diagnostics.openMillis =
        DateTime.now().difference(started).inMilliseconds;
    _instance = instance;
    _opening = null;
    return instance;
  }

  /// Closes the database — the counterpart to [open], and the only other place
  /// connection state changes.
  ///
  /// Flushes logical time, clears the dirty-open flag (a clean close is what
  /// makes the *next* open cheap), checkpoints the WAL, then disposes. Safe to
  /// call twice, and safe to call when the database never opened.
  Future<void> close() async {
    if (identical(_instance, this)) {
      _instance = null;
      _opening = null;
    }
    try {
      await db.hlc.flush();
      await db.customStatement(
        "INSERT OR REPLACE INTO session_flags (key, value) VALUES ('dirty_open', '0')",
      );
      await db.customStatement(
        "INSERT OR REPLACE INTO session_flags (key, value) VALUES "
        "('last_close_at', '${DateTime.now().millisecondsSinceEpoch}')",
      );
      await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } on Object {
      // A close-time failure must never mask why the app was closing.
    }
    await db.close();
  }

  @override
  String toString() => 'KhataDb(${_request.databaseFile.path})';
}

/// Persists logical time in `session_flags` — local-only, so a database restored
/// from a backup file can never inherit another device's clock.
final class DriftHlcPersistence implements HlcPersistence {
  DriftHlcPersistence(this._db);

  final KhataDatabase _db;
  static const String _key = 'last_hlc';

  @override
  Future<String?> readLastHlc() async {
    final rows = await _db.customSelect(
      'SELECT value FROM session_flags WHERE key = ?',
      variables: const [Variable<String>(_key)],
    ).get();
    return rows.isEmpty ? null : rows.first.read<String?>('value');
  }

  @override
  Future<void> writeLastHlc(String hlc) => _db.customStatement(
        'INSERT OR REPLACE INTO session_flags (key, value) VALUES (?, ?)',
        [_key, hlc],
      );
}

/// A read-only view of `v_session`, bound once per open instead of being
/// re-queried by every screen that needs "what is today, in this book's
/// timezone?".
final class LedgerClock {
  const LedgerClock({
    required this.sessionId,
    required this.writeMode,
    required this.todayEpochDay,
  });

  final String sessionId;
  final String writeMode;
  final int todayEpochDay;

  static LedgerClock? fromRow(QueryRow row) => LedgerClock(
        sessionId: row.read<String>('session_id'),
        writeMode: row.read<String>('write_mode'),
        todayEpochDay: row.read<int>('today_epoch_day'),
      );
}
