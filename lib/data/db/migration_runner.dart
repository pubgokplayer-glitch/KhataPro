/// KhataPro · the migration runner.
///
/// Drift's migration machinery (`onCreate` / `onUpgrade` with a `Migrator`) is
/// built for generated Dart table classes. This app's schema is SQL-first — 45
/// tables, 18 views, 69 indexes and 33 triggers written as `.sql` assets, proven
/// by `tool/verify_schema.sh` and 35 SQL contract tests — so migrations apply
/// those files **verbatim**. That is the point: the exact text the contract
/// tests exercised against SQLite is the text that runs on the phone.
///
/// The runner is a **planner**, not an executor. It decides *what* to apply and
/// *whether that is safe*; `database.dart` executes the statements through drift
/// so that transaction boundaries, error handling and the isolate hop stay in
/// one place. Two things that do SQL directly would be one thing too many.
///
/// Guarantees:
///
///   · **One file, one transaction** (enforced by the caller). A crash mid-
///     migration rolls that file back whole — never a table present with its
///     triggers missing.
///   · **The version lives in `schema_meta`**, not `PRAGMA user_version`.
///     `schema_meta` is readable by the app and by a future CLI without
///     special-casing pragmas, and it is already where the DDL records facts
///     like `money_encoding`. Drift writes `user_version` on its own; a
///     divergence is reported, not silently tolerated.
///   · **A checksum per file.** A migration that was applied and then *edited*
///     (a real accident on a multi-person schema) is detected at boot, instead
///     of producing two phones whose schemas differ and whose CRDT merge then
///     creates rows valid on neither.
///   · **Forward only.** There is no `down`. Un-applying a schema change cannot
///     un-apply the data change that came with it; restoring a backup is the
///     only honest rollback, and it is the one users can be told about.
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as raw_sqlite;

import '../../core/errors/khata_exception.dart';
import '../../core/security/hasher.dart';

/// The highest `NNN_*.sql` this build ships. Bump when adding a file.
const int kLatestSchemaVersion = 11;

/// Where the SQL files come from. Flutter reads them from `rootBundle`, the
/// harness reads them from disk — same runner either way, which is why this file
/// has no `package:flutter` import.
abstract interface class SqlAssetLoader {
  /// Returns the text of e.g. `assets/sql/migrations/002_ledger.sql`.
  Future<String> load(String assetPath);

  /// Asset paths under a directory, sorted. Needed so a build *shipping* a
  /// file that the runner does not know about is a boot-time error rather than
  /// a silently skipped migration.
  Future<List<String>> list(String directory);
}

/// Filesystem loader: the harness, and any future desktop/CLI tool.
final class FileSystemAssetLoader implements SqlAssetLoader {
  const FileSystemAssetLoader([this.root = '.']);

  final String root;

  @override
  Future<String> load(String assetPath) async {
    final file = File('$root/$assetPath');
    if (!file.existsSync()) {
      throw StorageException(message: 'SQL asset missing: ${file.path}');
    }
    return file.readAsStringSync();
  }

  @override
  Future<List<String>> list(String directory) async {
    final dir = Directory('$root/$directory');
    if (!dir.existsSync()) return const [];
    final names = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.sql'))
        .toList()
      ..sort();
    return names.map((name) => '$directory/$name').toList(growable: false);
  }
}

/// One migration that has not been applied yet, with its checksum already
/// computed so the caller can record it in the same transaction.
final class PendingMigration {
  const PendingMigration({
    required this.version,
    required this.fileName,
    required this.assetPath,
    required this.checksum,
  });

  final int version;
  final String fileName;
  final String assetPath;

  /// SHA-256 of the file with line endings normalised, so the same file has one
  /// checksum on every platform.
  final String checksum;
}

/// Outcome of a migration pass, for logs and the diagnostics bundle.
final class MigrationOutcome {
  const MigrationOutcome({
    required this.fromVersion,
    required this.toVersion,
    required this.applied,
    required this.durationMs,
    this.warnings = const [],
  });

  final int fromVersion;
  final int toVersion;
  final List<String> applied;
  final int durationMs;
  final List<String> warnings;

  bool get didSomething => applied.isNotEmpty;

  @override
  String toString() => applied.isEmpty
      ? 'schema v$toVersion (nothing to apply, ${durationMs}ms)'
      : 'schema v$fromVersion → v$toVersion in ${durationMs}ms '
          '(${applied.length} files: ${applied.join(', ')})';
}

/// Decides what to apply. See the library docs for why this does not execute.
final class SqlMigrationRunner {
  const SqlMigrationRunner({
    required this.loader,
    this.migrationsDirectory = 'assets/sql/migrations',
  });

  final SqlAssetLoader loader;
  final String migrationsDirectory;

  /// The shipped migration files, in order.
  ///
  /// Written out explicitly rather than globbed at runtime: a migration that
  /// fails to ship must be a **build-time** error, never a version that silently
  /// never runs. `verifyShippedSet` cross-checks this list against the
  /// directory, so the explicitness costs one assertion and buys certainty.
  static const Map<int, String> knownMigrations = {
    1: '001_core.sql',
    2: '002_ledger.sql',
    3: '003_crdt_sync.sql',
    4: '004_views.sql',
    5: '005_triggers.sql',
    6: '006_search.sql',
    7: '007_seed.sql',
    8: '008_integrity.sql',
    9: '009_conflict_receipts.sql',
    10: '010_integrity_report_fix.sql',
    11: '011_dashboard_party_rollup.sql',
  };

  /// Parses the `schema_version` value out of `schema_meta`.
  static int versionFromMeta(String? value) => int.tryParse(value ?? '') ?? 0;

  /// Reads the applied version through a raw connection. Used by tooling (the
  /// harness, a future CLI); the app reads it through drift.
  int readVersion(raw_sqlite.Database db) {
    final hasTable = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'schema_meta'",
    );
    if (hasTable.isEmpty) return 0;
    final rows = db.select("SELECT value FROM schema_meta WHERE key = 'schema_version'");
    return rows.isEmpty ? 0 : versionFromMeta(rows.first.values.first?.toString());
  }

  /// Every migration newer than [fromVersion], with checksums computed.
  ///
  /// Throws [SchemaTooNew] if the database is ahead of this build. Refusing is
  /// the safe choice: an older build can still *read* a newer schema, but a
  /// write it believes is valid may violate a constraint added later — and in a
  /// ledger, silently mis-posting is worse than asking the user to update.
  Future<List<PendingMigration>> pendingMigrations(int fromVersion) async {
    if (fromVersion > kLatestSchemaVersion) {
      throw SchemaTooNew(
        databaseVersion: fromVersion,
        appVersion: kLatestSchemaVersion,
      );
    }

    final pending = <PendingMigration>[];
    for (var version = fromVersion + 1; version <= kLatestSchemaVersion; version++) {
      final fileName = knownMigrations[version];
      if (fileName == null) {
        throw StorageException(
          message: 'no migration registered for schema version $version; the '
              'build is inconsistent and will not open this database',
          recoverable: false,
        );
      }
      final assetPath = '$migrationsDirectory/$fileName';
      pending.add(PendingMigration(
        version: version,
        fileName: fileName,
        assetPath: assetPath,
        checksum: checksumOf(await loader.load(assetPath)),
      ));
    }
    return pending;
  }

  /// Re-checks the checksums of already-applied migrations.
  ///
  /// [recorded] maps file name (`001_core.sql`) to the hash stored when it was
  /// applied. A file that changed after being applied means two installs of the
  /// same app version can now have different schemas — a divergence that a CRDT
  /// merge would faithfully replicate into new, invalid rows.
  Future<void> verifyAppliedChecksums(Map<String, String> recorded) async {
    for (final entry in recorded.entries) {
      final actual = checksumOf(await loader.load('$migrationsDirectory/${entry.key}'));
      if (actual != entry.value) {
        throw MigrationChecksumMismatch(
          migrationFile: entry.key,
          recorded: entry.value,
          actual: actual,
        );
      }
    }
  }

  /// Fails the boot when the directory contains a `.sql` file the runner does
  /// not know about — the "added a migration, forgot to register it" accident.
  Future<void> verifyShippedSet() async {
    final shipped = await loader.list(migrationsDirectory);
    for (final path in shipped) {
      final name = path.split('/').last;
      if (!knownMigrations.containsValue(name)) {
        throw StorageException(
          message: '$name ships in $migrationsDirectory but is not registered in '
              'SqlMigrationRunner.knownMigrations — it would never run. Add it '
              'to the map (and bump kLatestSchemaVersion).',
          recoverable: false,
        );
      }
    }
    for (final name in knownMigrations.values) {
      if (!shipped.any((path) => path.endsWith('/$name'))) {
        throw StorageException(
          message: '$name is registered in SqlMigrationRunner.knownMigrations '
              'but does not ship in $migrationsDirectory.',
          recoverable: false,
        );
      }
    }
  }

  /// SHA-256 with line endings and trailing whitespace normalised: a schema file
  /// that is byte-identical on Linux, macOS and Windows has one checksum
  /// everywhere.
  static String checksumOf(String sql) =>
      sha256Hex(_normalise(sql).codeUnits);

  static String _normalise(String sql) => sql
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((line) => line.trimRight())
      .join('\n')
      .trim();

  /// True when `PRAGMA user_version` and `schema_meta` disagree — reported by the
  /// caller, because drift rewrites `user_version` on open and correcting it here
  /// would fight drift for no benefit.
  static bool userVersionDiverges(int userVersion, int metaVersion) =>
      userVersion != 0 && userVersion != metaVersion;
}
