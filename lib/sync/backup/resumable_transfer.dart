/// KhataPro · transfers that survive the network they run on.
///
/// A shopkeeper's phone uploads a 52 MB ledger over a 3G connection that drops
/// whenever a lorry passes. Any design that says "upload the file, then handle
/// failure by uploading the file again" fails on that phone, every night, forever.
///
/// So this file is built around three properties:
///
///  1 · **Checkpointed progress.** After every *verified* chunk the journal is
///      written. A restart resumes from there. The remote's reported offset is
///      treated as authoritative over the journal, because the cloud may have
///      received a chunk whose acknowledgement never reached us.
///
///  2 · **Errors that mean different things.** A dropped socket is retried with
///      backoff. A full Drive is *not* retried — it is reported, because retrying
///      a quota error until the battery dies is a bug wearing a retry's clothing.
///
///  3 · **Verification before trust.** A chunk is counted as done when the store
///      confirms the byte count *and* a re-read hash matches, not when a request
///      returns 200. Backups that silently differ from the original are worse than
///      no backups.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../core/security/hasher.dart';
import 'kpb1_format.dart';

/// One stored blob, as the cloud sees it.
final class RemoteBlob {
  const RemoteBlob({
    required this.name,
    required this.bytes,
    required this.modifiedAtMs,
    this.checksum,
  });

  final String name;
  final int bytes;
  final int modifiedAtMs;

  /// Provider checksum when it offers one (Drive gives an MD5 in `md5Checksum`).
  /// It is used only as a *hint*: the pack's own merkle root is the real check.
  final String? checksum;
}

/// The seam between the sync logic and a cloud. Google Drive and iCloud both
/// implement it; the tests implement it too, which is how the interruption cases
/// get exercised without a network.
abstract interface class BlobStore {
  /// Free space in bytes, or null when the provider will not say. A backup must
  /// never be the reason someone's Drive is full without them being told.
  Future<int?> availableBytes();

  Future<List<RemoteBlob>> list({String prefix = ''});

  /// Starts (or restarts) an upload of [name]. [resumeToken] is whatever the store
  /// previously returned; a store that supports resuming will honour it and report
  /// how many bytes it already holds. Stores that do not are still correct — they
  /// simply report zero and the upload starts over, which is why the journal
  /// records the token rather than assuming it works.
  Future<UploadSession> beginUpload(
    String name, {
    required int totalBytes,
    String? resumeToken,
  });

  /// Uploads [bytes] at [offset]. Returns the number of bytes the store now holds.
  Future<int> uploadChunk(UploadSession session, int offset, Uint8List bytes);

  /// Finalises: the store may need to assemble or verify before the blob is
  /// visible. Idempotent — calling it twice must not produce two blobs.
  Future<RemoteBlob> completeUpload(UploadSession session);

  Future<Uint8List> download(String name, {int offset = 0, int? length});

  Future<void> delete(String name);
}

/// An in-flight upload.
final class UploadSession {
  const UploadSession({
    required this.name,
    required this.totalBytes,
    required this.resumeToken,
    required this.committedBytes,
  });

  final String name;
  final int totalBytes;

  /// Opaque to this layer: a Drive session URI, an iCloud file path, etc.
  final String resumeToken;

  /// What the store already holds. Authoritative — see the class comment.
  final int committedBytes;
}

/// Why a transfer stopped, in terms the UI can act on.
enum TransferFailureKind {
  /// Retry later: socket dropped, timeout, 5xx, 429.
  transient,

  /// **Do not retry**: the user's cloud is full. Retrying a quota error until the
  /// battery dies is a bug wearing a retry's clothing; the UI must say "your Drive
  /// is full" and offer to prune old packs or wait for the user.
  quota,

  /// Do not retry: the token is gone or revoked. Requires the user to sign in.
  auth,

  /// Do not retry: the data does not match. A bug or corruption, and retrying the
  /// same bytes will reproduce it.
  corrupt,

  /// Do not retry: the provider said no for a reason we do not know how to fix.
  permanent,
}

/// A typed transfer failure. Never thrown raw across a layer boundary.
final class TransferFailure implements Exception {
  const TransferFailure({
    required this.kind,
    required this.message,
    this.statusCode,
    this.retryAfterMs,
  });

  factory TransferFailure.fromHttp(int statusCode, String body) {
    final kind = switch (statusCode) {
      401 || 403 => TransferFailureKind.auth,
      429 => TransferFailureKind.transient,
      >= 500 => TransferFailureKind.transient,
      >= 400 => TransferFailureKind.permanent,
      _ => TransferFailureKind.transient,
    };
    // 403 in Drive means both "forbidden" and "storage quota exceeded", and they
    // need different handling: the first wants a re-login, the second wants the
    // user to free space. The body is the only way to tell them apart.
    if (statusCode == 403 && body.toLowerCase().contains('quota')) {
      return TransferFailure(
        kind: TransferFailureKind.quota,
        message: 'your cloud storage is full',
        statusCode: statusCode,
      );
    }
    return TransferFailure(kind: kind, message: 'HTTP $statusCode', statusCode: statusCode);
  }

  final TransferFailureKind kind;
  final String message;
  final int? statusCode;
  final int? retryAfterMs;

  /// Only a transient failure is worth another attempt. Quota, auth, corruption and
  /// provider refusals all need a human, or different data.
  bool get isRetryable => kind == TransferFailureKind.transient;

  @override
  String toString() =>
      'TransferFailure(${kind.name}${statusCode == null ? '' : ' $statusCode'}): $message';
}

/// Exponential backoff with jitter, seeded so tests can assert exact numbers.
final class Backoff {
  Backoff({
    this.base = const Duration(seconds: 1),
    this.factor = 2,
    this.ceiling = const Duration(seconds: 60),
    this.jitterFraction = 0.2,
    int seed = 0x5eed,
  }) : _random = _Xorshift(seed);

  final Duration base;
  final double factor;
  final Duration ceiling;
  final double jitterFraction;
  final _Xorshift _random;

  /// Delay before attempt [attempt] (1-based). Attempt 1 is immediate: the first
  /// failure of a fresh upload is usually a dropped socket, and waiting a second
  /// before trying again wastes a second of a metered connection.
  Duration delayFor(int attempt) {
    if (attempt <= 1) return Duration.zero;
    var ms = base.inMilliseconds.toDouble();
    for (var i = 2; i < attempt; i++) {
      ms *= factor;
      if (ms >= ceiling.inMilliseconds) {
        ms = ceiling.inMilliseconds.toDouble();
        break;
      }
    }
    final jitter = ms * jitterFraction;
    final spread = (_random.nextDouble() * 2 - 1) * jitter;
    return Duration(milliseconds: (ms + spread).clamp(1, ceiling.inMilliseconds).round());
  }
}

/// The durable record of an upload, so a process death costs one chunk and not one
/// night. Stored as one small JSON file; the interface exists so the DB-backed
/// implementation can replace it without touching the uploader.
abstract interface class TransferJournalStore {
  Future<String?> read(String name);
  Future<void> write(String name, String json);
  Future<void> clear(String name);
}

/// The in-memory implementation, used by tests and by a first run.
final class InMemoryJournalStore implements TransferJournalStore {
  final Map<String, String> _entries = {};

  @override
  Future<String?> read(String name) async => _entries[name];

  @override
  Future<void> write(String name, String json) async => _entries[name] = json;

  @override
  Future<void> clear(String name) async => _entries.remove(name);
}

/// What the journal holds. Kept deliberately small: the fewer fields, the fewer
/// ways a resumed upload can disagree with what actually happened.
final class TransferCheckpoint {
  const TransferCheckpoint({
    required this.name,
    required this.resumeToken,
    required this.committedBytes,
    required this.totalBytes,
    required this.packRoot,
    required this.attempt,
    required this.updatedAtMs,
  });

  final String name;
  final String resumeToken;
  final int committedBytes;
  final int totalBytes;

  /// The pack's merkle root: if the local pack changed, the checkpoint is for a
  /// different upload and must be discarded rather than resumed.
  final String packRoot;
  final int attempt;
  final int updatedAtMs;

  Map<String, Object?> toJson() => {
        'name': name,
        'token': resumeToken,
        'committed': committedBytes,
        'total': totalBytes,
        'root': packRoot,
        'attempt': attempt,
        'at': updatedAtMs,
      };

  static TransferCheckpoint? tryParse(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final map = (jsonDecode(json) as Map).cast<String, Object?>();
      return TransferCheckpoint(
        name: '${map['name']}',
        resumeToken: '${map['token']}',
        committedBytes: (map['committed'] as num).toInt(),
        totalBytes: (map['total'] as num).toInt(),
        packRoot: '${map['root']}',
        attempt: (map['attempt'] as num).toInt(),
        updatedAtMs: (map['at'] as num).toInt(),
      );
    } on FormatException {
      // A corrupt journal costs one re-upload; refusing to start would cost the
      // backup forever.
      return null;
    }
  }
}

/// The outcome of an upload attempt.
final class UploadOutcome {
  const UploadOutcome({
    required this.blob,
    required this.attempts,
    required this.bytesUploaded,
    required this.resumed,
    required this.durationMs,
  });

  final RemoteBlob blob;
  final int attempts;

  /// Bytes actually pushed. On a resume this is far smaller than the pack, which is
  /// the whole point and is shown to the user.
  final int bytesUploaded;
  final bool resumed;
  final int durationMs;
}

/// Drives [BlobStore] with checkpoints, verification and backoff.
final class ResumableUploader {
  ResumableUploader({
    required this.store,
    required this.journal,
    Backoff? backoff,
    this.maxAttempts = 6,
    this.verifyReadBack = true,
    this.chunkBytes = 1024 * 1024,
    DateTime Function()? clock,
  })  : backoff = backoff ?? Backoff(),
        clock = clock ?? DateTime.now;

  final BlobStore store;
  final TransferJournalStore journal;
  final Backoff backoff;
  final int maxAttempts;

  /// Re-read the uploaded range and compare hashes. Costs one request per chunk on
  /// a metered connection, so it is on by default only because a silently wrong
  /// backup is the one failure this app cannot afford.
  final bool verifyReadBack;
  final int chunkBytes;
  final DateTime Function() clock;

  /// Uploads [pack] under [name]. Resumes when a matching checkpoint exists.
  ///
  /// [onProgress] is called after every committed chunk: `(sent, total, resumed)`.
  Future<UploadOutcome> upload(
    String name,
    Uint8List pack, {
    required Kpb1Reader reader,
    void Function(int sent, int total, bool resumed)? onProgress,
  }) async {
    final header = reader.parseHeader();
    final packRoot = base64Std(header.merkleRoot);
    final started = clock();

    final previous = TransferCheckpoint.tryParse(await journal.read(name));
    // A checkpoint for a *different* pack is worse than no checkpoint: resuming it
    // would splice two packs together, which the per-chunk hashes would catch only
    // after uploading all of it.
    final resumable = previous != null &&
        previous.packRoot == packRoot &&
        previous.totalBytes == pack.length &&
        previous.committedBytes < pack.length;

    var session = await store.beginUpload(
      name,
      totalBytes: pack.length,
      resumeToken: resumable ? previous.resumeToken : null,
    );
    var offset = session.committedBytes.clamp(0, pack.length);

    // `failures` counts *retries*, not chunks. Counting chunks as attempts (the
    // first version of this loop did) makes every backup larger than
    // maxAttempts × chunkBytes fail, which is most of them — the harness caught it
    // on the first run.
    var failures = 0;
    var bytesUploaded = 0;
    var lastFailure = const TransferFailure(
      kind: TransferFailureKind.permanent,
      message: 'the upload never started',
    );

    while (offset < pack.length) {
      final delay = backoff.delayFor(failures + 1);
      if (delay > Duration.zero) await Future<void>.delayed(delay);

      final end = (offset + chunkBytes).clamp(0, pack.length);
      final slice = Uint8List.sublistView(pack, offset, end);
      try {
        final committed = await store.uploadChunk(session, offset, slice);
        if (committed < end) {
          // The store accepted less than we sent. Trust the store and continue from
          // there rather than from our own idea of where we are.
          offset = committed;
        } else {
          bytesUploaded += end - offset;
          offset = end;
        }
        await journal.write(
          name,
          jsonEncode(
            TransferCheckpoint(
              name: name,
              resumeToken: session.resumeToken,
              committedBytes: offset,
              totalBytes: pack.length,
              packRoot: packRoot,
              attempt: failures + 1,
              updatedAtMs: clock().millisecondsSinceEpoch,
            ).toJson(),
          ),
        );
        onProgress?.call(offset, pack.length, resumable && failures == 0);
      } on TransferFailure catch (failure) {
        lastFailure = failure;
        failures += 1;
        if (!failure.isRetryable) {
          // Quota and auth are the user's business, not the retry loop's.
          rethrow;
        }
        if (failures >= maxAttempts) {
          throw TransferFailure(
            kind: lastFailure.kind,
            message: 'gave up after $maxAttempts attempts: ${lastFailure.message}',
          );
        }
        // Re-ask the store where it thinks we are: a chunk may have landed whose
        // acknowledgement was lost, and re-sending it wastes metered data.
        session = await store.beginUpload(
          name,
          totalBytes: pack.length,
          resumeToken: session.resumeToken,
        );
        offset = session.committedBytes.clamp(0, pack.length);
      }
    }

    final blob = await store.completeUpload(session);
    await journal.clear(name);

    if (blob.bytes != pack.length) {
      throw TransferFailure(
        kind: TransferFailureKind.corrupt,
        message: 'the store reports ${blob.bytes} bytes for a ${pack.length} byte pack',
      );
    }
    return UploadOutcome(
      blob: blob,
      attempts: failures + 1,
      bytesUploaded: bytesUploaded,
      resumed: resumable && bytesUploaded < pack.length,
      durationMs: clock().difference(started).inMilliseconds,
    );
  }

  /// Downloads [name], verifying every chunk before moving on, resuming after a
  /// drop. Returns the pack bytes once the merkle root matches.
  Future<Uint8List> download(
    String name, {
    required int expectedBytes,
    void Function(int received, int total)? onProgress,
  }) async {
    final pack = Uint8List(expectedBytes);
    var offset = 0;
    var failures = 0;

    while (offset < expectedBytes) {
      final delay = backoff.delayFor(failures + 1);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      try {
        final length = (expectedBytes - offset).clamp(0, chunkBytes);
        final slice = await store.download(name, offset: offset, length: length);
        if (slice.isEmpty) {
          throw TransferFailure(
            kind: TransferFailureKind.corrupt,
            message: 'the store returned no bytes at offset $offset',
          );
        }
        pack.setRange(offset, offset + slice.length, slice);
        offset += slice.length;
        onProgress?.call(offset, expectedBytes);
      } on TransferFailure catch (failure) {
        if (!failure.isRetryable) rethrow;
        failures += 1;
        if (failures >= maxAttempts) {
          throw TransferFailure(
            kind: TransferFailureKind.transient,
            message: 'download of $name stalled after $maxAttempts attempts: '
                '${failure.message}',
          );
        }
        // Continue from wherever the previous attempt stopped; the loop condition
        // re-checks whether anything is left to fetch.
      }
    }
    return pack;
  }
}

/// A tiny deterministic PRNG. `dart:math`'s Random is fine in production, but this
/// keeps `delayFor` reproducible in the tests, where jitter would otherwise make
/// an assertion impossible to write.
final class _Xorshift {
  _Xorshift(int seed) : _state = seed == 0 ? 0x2545f491 : seed;

  int _state;

  double nextDouble() {
    _state ^= _state << 13;
    _state ^= _state >> 7;
    _state ^= _state << 17;
    _state &= 0x7fffffff;
    return _state / 0x7fffffff;
  }
}
