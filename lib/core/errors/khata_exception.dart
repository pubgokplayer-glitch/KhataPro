/// KhataPro · typed errors that carry the database's own invariant codes.
///
/// The SQL layer (005_triggers.sql, 008_integrity.sql) refuses bad writes with
/// messages that begin with a stable code: `INT-5b:`, `DOC-3:`, `FIN-1:`,
/// `INTEGRITY GATE:`. Those codes are part of the public contract of the
/// database — this file is the one place that translates them into typed Dart
/// exceptions the UI can act on ("this period is locked" → offer to unlock;
/// "not balanced" → highlight the offending line).
///
/// Practical benefit: the UI never has to string-match. If a trigger message
/// changes, exactly one file needs updating, and `test/unit/exception_test.dart`
/// fails loudly if a code appears in SQL that has no mapping here.
library;

/// Base type for every error this app raises deliberately.
///
/// Deliberately **not** `sealed`: domain libraries (money, CRDT, sync) define
/// their own subtypes, and `sealed` would forbid that outside this file. It is
/// also concrete so a one-off failure can be thrown without inventing a class;
/// pre-declared subtypes are preferred wherever a caller might want to catch a
/// specific failure.
///
/// [code] is a stable, greppable identifier (used in logs and crash reports);
/// [message] is human-readable and safe to show to a non-technical shopkeeper
/// once the UI has mapped it to a localized string.
class KhataException implements Exception {
  const KhataException({
    required this.code,
    required this.message,
    this.cause,
    this.stackTrace,
  });

  final String code;
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  /// SQLite's own error text, when we have it — invaluable in a bug report.
  String? get sqliteMessage =>
      cause is Exception && cause.toString().contains('SqliteException')
          ? cause.toString()
          : null;

  KhataException withContext({Object? cause, StackTrace? stackTrace}) => KhataException(
        code: code,
        message: message,
        cause: cause ?? this.cause,
        stackTrace: stackTrace ?? this.stackTrace,
      );

  @override
  String toString() => '$runtimeType($code): $message'
      '${cause == null ? '' : ' | cause: $cause'}';
}

// ─────────────────────────────────────────────────────────────────────────────
//  Integrity violations — raised by the database's own triggers
// ─────────────────────────────────────────────────────────────────────────────

/// A write was refused by one of the schema's guards.
///
/// These are *good* failures: the database caught something the application
/// layer should never have attempted. The UI's job is to explain it, never to
/// retry it blindly.
final class InvariantViolation extends KhataException {
  const InvariantViolation({
    required this.invariantCode,
    required super.message,
    super.cause,
    super.stackTrace,
  }) : super(code: 'INVARIANT_VIOLATION');

  /// The code from the SQL trigger, e.g. `INT-5b`, `DOC-3`, `FIN-1`, `GATE`.
  final String invariantCode;

  /// Includes the invariant code: a log line that says only
  /// `InvariantViolation(INVARIANT_VIOLATION)` tells an engineer nothing, while
  /// `... [FIN-2]` points straight at the trigger or call site that refused.
  @override
  String toString() => '$runtimeType($code) [$invariantCode]: $message'
      '${cause == null ? '' : ' | cause: $cause'}';

  /// Which user-facing category this belongs to, for error UX.
  InvariantKind get kind => switch (invariantCode.split('-').first) {
        'INT' => InvariantKind.accounting,
        'DOC' => InvariantKind.document,
        'FIN' => InvariantKind.period,
        'GATE' => InvariantKind.corruption,
        _ => InvariantKind.unknown,
      };

  /// Parses SQLite's `SqliteException` message. Returns `null` when the error
  /// is not one of ours (so callers can distinguish "our guard fired" from
  /// "the disk is full").
  static InvariantViolation? tryParse(Object error) {
    final text = error.toString();
    return _parseMessage(text, error);
  }

  static InvariantViolation? _parseMessage(String text, Object? error) {
    if (text.contains('KhataPro INTEGRITY GATE') || text.contains('INTEGRITY GATE:')) {
      return InvariantViolation(
        invariantCode: 'GATE',
        message: 'A data-integrity check failed and the change was rolled back. '
            'Your books are unchanged. Run Settings → Verify my books for details.',
        cause: error,
      );
    }

    // Trigger codes are emitted as "INT-5b: explanation".
    final match = RegExp(r'\b(INT|DOC|FIN)-([A-Z0-9]+)\s*:\s*([^"\u0000]*)').firstMatch(text);
    if (match != null) {
      final code = '${match.group(1)}-${match.group(2)}';
      final detail = match.group(3)?.trim() ?? '';
      return InvariantViolation(
        invariantCode: code,
        message: detail.isEmpty ? 'Refused by the ledger guard $code.' : detail,
        cause: error,
      );
    }

    // SQLite's own constraints, which guard the same rules at a lower level.
    if (text.contains('UNIQUE constraint failed')) {
      return InvariantViolation(
        invariantCode: 'SQL-UNIQUE',
        message: 'That value already exists (for example a duplicate document '
            'number or party account).',
        cause: error,
      );
    }
    if (text.contains('FOREIGN KEY constraint failed')) {
      return InvariantViolation(
        invariantCode: 'SQL-FK',
        message: 'The record refers to something that no longer exists, or to '
            'another ledger.',
        cause: error,
      );
    }
    if (text.contains('CHECK constraint failed')) {
      return InvariantViolation(
        invariantCode: 'SQL-CHECK',
        message: 'The value is outside the range this ledger allows.',
        cause: error,
      );
    }
    return null;
  }
}

enum InvariantKind { accounting, document, period, corruption, unknown }

// ─────────────────────────────────────────────────────────────────────────────
//  Domain-level refusals — caught BEFORE SQL, with better messages
// ─────────────────────────────────────────────────────────────────────────────

/// An entry the app refused to post because its lines do not balance.
///
/// Raised by `OrderBook.post` as a pre-flight check so the user gets a precise,
/// actionable message (with the exact imbalance) instead of a trigger's text.
/// The database still refuses it independently — this is defence in depth, not
/// a replacement for the trigger.
final class UnbalancedEntryException extends KhataException {
  UnbalancedEntryException({
    required this.debitTotal,
    required this.creditTotal,
    required this.entryId,
    this.lineCount = 0,
  }) : super(
          code: 'ENTRY_UNBALANCED',
          message: 'Entry $entryId is out of balance by ${debitTotal - creditTotal} '
              'minor units ($debitTotal Dr vs $creditTotal Cr)${lineCount < 2 ? ' — an entry needs at least two lines' : ''}.',
        );

  final int debitTotal;
  final int creditTotal;
  final String entryId;
  final int lineCount;
}

/// Posting into a period the owner has locked.
final class PeriodLockedException extends KhataException {
  const PeriodLockedException({required this.lockedThroughEpochDay, required this.entryDate})
      : super(
          code: 'PERIOD_LOCKED',
          message: 'The accounting period is locked through day $lockedThroughEpochDay; '
              'this entry is dated $entryDate. Unlock the period in Settings, or change the date.',
        );

  final int lockedThroughEpochDay;
  final int entryDate;
}

/// A document that has already been posted is being edited in a way that would
/// rewrite history. Correct behaviour is a credit/debit note.
final class ImmutableDocumentException extends KhataException {
  const ImmutableDocumentException({required this.documentNo, required this.field})
      : super(
          code: 'DOCUMENT_IMMUTABLE',
          message: 'Document $documentNo is posted; $field cannot be changed. '
              'Issue a credit note (sales return) or debit note (purchase return) instead.',
        );

  final String documentNo;
  final String field;
}

// ─────────────────────────────────────────────────────────────────────────────
//  Infrastructure failures
// ─────────────────────────────────────────────────────────────────────────────

class MigrationException extends KhataException {
  const MigrationException({
    required this.migrationFile,
    required super.message,
    super.cause,
    super.code = 'MIGRATION_FAILED',
  });

  final String migrationFile;
}

/// A migration file failed to apply. The transaction for that file was rolled
/// back whole, so the database is exactly as it was before the attempt.
final class MigrationFailed extends MigrationException {
  MigrationFailed({
    required super.migrationFile,
    required this.version,
    required String cause,
  }) : super(
          message: 'migration $migrationFile (v$version) failed and was rolled '
              'back: $cause',
          cause: cause,
          code: 'MIGRATION_FAILED',
        );

  final int version;
}

/// The database says it is newer than this build understands.
///
/// Refusing to open is the safe choice: an older build running against a newer
/// schema can still *read*, but a write it thinks is valid can violate a
/// constraint added later — and in a ledger, silently mis-posting an entry is
/// worse than asking the user to update the app.
final class SchemaTooNew extends MigrationException {
  SchemaTooNew({required this.databaseVersion, required this.appVersion})
      : super(
          migrationFile: '(none)',
          message: 'this database was written by a newer version of KhataPro '
              '(schema v$databaseVersion; this app understands v$appVersion). '
              'Update the app to open it.',
          code: 'SCHEMA_TOO_NEW',
        );

  final int databaseVersion;
  final int appVersion;
}

/// A migration file was applied and then edited.
///
/// Two phones that ran the same version must have byte-identical schemas, or a
/// CRDT merge can produce rows that are valid on neither. Detecting the edit at
/// boot is far cheaper than diagnosing the divergence later.
final class MigrationChecksumMismatch extends MigrationException {
  MigrationChecksumMismatch({
    required super.migrationFile,
    required this.recorded,
    required this.actual,
  }) : super(
          message: '$migrationFile was modified after it was applied '
              '(recorded ${recorded.substring(0, 12)}…, now '
              '${actual.substring(0, 12)}…). Revert the file, or add a new '
              'migration instead of editing an applied one.',
          code: 'MIGRATION_CHECKSUM',
        );

  final String recorded;
  final String actual;
}

/// Anything to do with the key hierarchy: Keystore/Keychain unavailable, a
/// wrapped key that fails its authentication tag, a wrong recovery phrase.
final class KeyCustodyException extends KhataException {
  const KeyCustodyException({
    required super.code,
    required super.message,
    super.cause,
    this.recoverable = false,
  });

  /// True when the user can retry (wrong passphrase) rather than having hit a
  /// hardware fault.
  final bool recoverable;
}

final class StorageException extends KhataException {
  const StorageException({required super.message, super.cause, this.recoverable = true})
      : super(code: 'STORAGE');

  /// True when retrying could plausibly succeed (transient I/O) rather than
  /// indicating a corrupted or full volume.
  final bool recoverable;
}

/// An amount that would not fit in SQLite's 64-bit INTEGER. Raised by
/// `MoneyMinor.guardOverflow` — the alternative is silent wrapping, which would
/// corrupt a balance instead of failing a save.
final class MoneyOverflowException extends KhataException {
  const MoneyOverflowException({required this.value, required this.scale})
      : super(
          code: 'MONEY_OVERFLOW',
          message: 'Amount $value minor units (scale $scale) overflows the 64-bit range.',
        );

  final int value;
  final int scale;
}

/// The sync transport refused a batch. Carries which invariant failed so the
/// peer can be told to upgrade or to send a repair.
final class SyncRejectedException extends KhataException {
  const SyncRejectedException({
    required super.message,
    this.remoteNodeId,
    this.invariant,
    super.cause,
  }) : super(code: 'SYNC_REJECTED');

  final String? remoteNodeId;
  final InvariantViolation? invariant;
}

/// The local database failed its own health check on open. Distinct from a
/// migration failure: the schema is fine, the *data* is suspect.
final class DatabaseHealthException extends KhataException {
  const DatabaseHealthException({
    required this.findings,
    required super.message,
    super.cause,
  }) : super(code: 'DATABASE_HEALTH');

  /// `kind: detail` strings straight from `v_integrity_report`.
  final List<String> findings;
}
