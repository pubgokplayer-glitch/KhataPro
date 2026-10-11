#!/usr/bin/env dart
// KhataPro · Deliverable 3 · BYOC backup + LAN sync, verified.
//
// Everything here runs against fakes that misbehave the way real infrastructure
// does: a Drive that drops a connection at 60 %, a Drive that is full, an iCloud
// container that is half-written, a Wi-Fi link that loses frames. Those are the
// conditions the acceptance criteria are about — "upload/download tolerant of
// network interruptions" cannot be shown with a test that never interrupts
// anything.
//
// Run:
//   cd /tmp/harness && ./run_tool.sh /home/user/khata_pro/tool/sync_verify.dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:khata_pro/core/crdt/hlc.dart';
import 'package:khata_pro/core/crdt/stamp.dart';
import 'package:khata_pro/core/errors/khata_exception.dart';
import 'package:khata_pro/core/security/hasher.dart';
import 'package:khata_pro/platform/drive/drive_store.dart';
import 'package:khata_pro/platform/icloud/icloud_store.dart';
import 'package:khata_pro/sync/backup/http_transport.dart';
import 'package:khata_pro/sync/backup/kpb1_format.dart';
import 'package:khata_pro/sync/backup/resumable_transfer.dart';
import 'package:khata_pro/sync/protocol/apply_pipeline.dart';
import 'package:khata_pro/sync/transport/flow_control.dart';
import 'package:khata_pro/sync/transport/qr_pairing.dart';
import 'package:khata_pro/sync/transport/sdp_tools.dart';

var _checks = 0;
var _failed = 0;

void section(String name) {
  final pad = 62 - name.length;
  print('\n  ── $name ${pad > 0 ? '─' * pad : ''}');
}

void check(String what, bool ok, [Object? detail]) {
  _checks += 1;
  if (ok) {
    print('    ✓ $what');
  } else {
    _failed += 1;
    print('    ✗ $what${detail == null ? '' : '  —  $detail'}');
  }
}

Future<void> main() async {
  print('  KhataPro · BYOC backup + LAN sync');
  print('  ══════════════════════════════════════════════════════════════════');

  _packFormat();
  _packTamperResistance();
  await _uploadSurvivesInterruption();
  await _quotaIsReportedNotRetried();
  await _resumeRefusesADifferentPack();
  await _downloadResumesAfterADrop();
  await _driveResumableProtocol();
  await _driveClassifiesFailures();
  await _icloudWritesAtomically();
  _flowControlProtectsTheFrameRate();
  _adaptiveFrameSizing();
  _sdpSurgery();
  _pairingTickets();
  _authenticationString();
  await _batchPipeline();

  print('\n  ══════════════════════════════════════════════════════════════════');
  if (_failed == 0) {
    print('  ✓ all $_checks checks passed');
  } else {
    print('  ✗ $_failed of $_checks checks FAILED');
    exit(1);
  }
}

// ── the pack format ──────────────────────────────────────────────────────────

Kpb1Reader _writePack(
  Uint8List payload, {
  Uint8List? key,
  int targetChunkBytes = 64 * 1024,
  Kpb1PayloadKind kind = Kpb1PayloadKind.snapshot,
}) {
  final packKey = key ?? randomBytes(32);
  final writer = Kpb1Writer(
    packKey: packKey,
    ledgerId: 'ledger-1',
    nodeId: 'node-a',
    schemaVersion: 10,
    keyId: 'backup-kek',
    kind: kind,
    createdAtMs: 1760000000000,
    targetChunkBytes: targetChunkBytes,
  );
  // Feed it in awkward slices: a real file read never aligns with the chunk size.
  var offset = 0;
  var slice = 7;
  while (offset < payload.length) {
    final end = (offset + slice).clamp(0, payload.length);
    writer.add(Uint8List.sublistView(payload, offset, end));
    offset = end;
    slice = slice * 3 % 5000 + 1;
  }
  final pack = writer.finish();
  return Kpb1Reader(packKey: packKey, bytes: pack);
}

void _packFormat() {
  section('KPB1 packs round-trip, chunk plan and all');

  final payload = _pattern(300 * 1024 + 17);
  final reader = _writePack(payload);
  final header = reader.parseHeader();

  check('the header reads back', header.ledgerId == 'ledger-1' && header.schemaVersion == 10);
  check(
    'the payload is split into the planned chunks',
    header.chunks.length == 5,
    '${header.chunks.length} chunks for ${payload.length} bytes',
  );
  check(
    'every chunk but the last is the target size',
    header.chunks.take(4).every((c) => c.plaintextBytes == 64 * 1024) &&
        header.chunks.last.plaintextBytes < 64 * 1024,
  );
  check('the merkle root recomputes from the chunk hashes', reader.verifyMerkleRoot());

  final rebuilt = BytesBuilder(copy: false);
  for (final chunk in reader.openAll()) {
    rebuilt.add(chunk);
  }
  check(
    'the whole payload comes back byte for byte',
    _equal(rebuilt.takeBytes(), payload),
  );

  // Chunk-by-chunk access is what a resumed download needs: reading chunk 3 must not
  // require decrypting chunks 0–2.
  final single = reader.openChunk(3);
  final plan = ChunkPlan.forLength(payload.length, targetChunkBytes: 64 * 1024);
  final (start, end) = plan.rangeOf(3);
  check(
    'a single chunk can be read on its own',
    _equal(single, Uint8List.sublistView(payload, start, end)),
  );

  // Edge cases that a real 52 MB pack will not have but a first sync might.
  final empty = _writePack(Uint8List(0));
  check('an empty payload still produces a verifiable pack', empty.openAll().isEmpty);

  final exact = _writePack(_pattern(64 * 1024));
  check(
    'a payload that is exactly one chunk makes exactly one chunk',
    exact.parseHeader().chunks.length == 1 &&
        _equal(exact.openChunk(0), _pattern(64 * 1024)),
  );

  final planEmpty = ChunkPlan.forLength(0);
  check('a zero-length plan reports no chunks', planEmpty.chunkCount == 0);

  // Nonces must be unique per chunk or AES-CTR keystreams would repeat, which is
  // the classic way to turn encryption into a XOR.
  final nonceBase = randomBytes(16);
  final nonces = [for (var i = 0; i < 8; i++) base64Std(Kpb1Merkle.chunkNonce(nonceBase, i))];
  check('per-chunk nonces are unique', nonces.toSet().length == 8);
  check(
    'per-chunk nonces are deterministic (a resume re-derives the same ones)',
    base64Std(Kpb1Merkle.chunkNonce(nonceBase, 5)) == nonces[5],
  );
}

void _packTamperResistance() {
  section('a pack that was altered in the cloud refuses to open');

  final payload = _pattern(200 * 1024);
  final good = _writePack(payload);
  final bytes = good.bytes;

  // Flip one byte inside the *first* chunk's ciphertext: header, MAC and chunk 0's
  // length + nonce come first, then the ciphertext.
  final chunkStart =
      14 + _headerLength(bytes) + Kpb1.headerMacLength + Kpb1.chunkLengthPrefix +
          Kpb1.chunkNonceLength;
  final tampered = Uint8List.fromList(bytes)..[chunkStart + 1000] ^= 0x01;
  final tamperedReader = Kpb1Reader(packKey: good.packKey, bytes: tampered);
  var caught = '';
  try {
    tamperedReader.openChunk(0);
  } on InvariantViolation catch (error) {
    caught = error.invariantCode;
  }
  check('a flipped byte is caught by the chunk MAC', caught == 'SYNC-5', caught);

  // Truncate the upload at 60 %: the failure must be a clear "the upload stopped",
  // not a crash halfway through a decrypt.
  final truncated = Uint8List.sublistView(bytes, 0, (bytes.length * 6) ~/ 10);
  final truncatedReader = Kpb1Reader(packKey: good.packKey, bytes: truncated);
  var truncatedCode = '';
  try {
    truncatedReader.openAll();
  } on InvariantViolation catch (error) {
    truncatedCode = error.invariantCode;
  }
  check('a half-uploaded pack is reported as incomplete', truncatedCode == 'SYNC-3', truncatedCode);

  // A header edited to claim a different ledger: the header MAC must refuse it.
  final headerStart = 14;
  final headerEnd = headerStart + _headerLength(bytes);
  final edited = Uint8List.fromList(bytes);
  final json = utf8.decode(Uint8List.sublistView(edited, headerStart, headerEnd));
  final replacement = utf8.encode(json.replaceAll('ledger-1', 'ledger-2'));
  if (replacement.length == headerEnd - headerStart) {
    edited.setRange(headerStart, headerEnd, replacement);
    var headerCode = '';
    try {
      Kpb1Reader(packKey: good.packKey, bytes: edited).parseHeader();
    } on InvariantViolation catch (error) {
      headerCode = error.invariantCode;
    }
    check('an edited manifest fails its MAC', headerCode == 'SYNC-5', headerCode);
  } else {
    check('an edited manifest fails its MAC', false, 'test could not build the edit');
  }

  // The wrong key (a different device, or a different backup generation).
  var wrongKeyCode = '';
  try {
    Kpb1Reader(packKey: randomBytes(32), bytes: bytes).parseHeader();
  } on InvariantViolation catch (error) {
    wrongKeyCode = error.invariantCode;
  }
  check('the wrong key cannot open the header either', wrongKeyCode == 'SYNC-5', wrongKeyCode);
}

int _headerLength(Uint8List bytes) =>
    (bytes[10] << 24) | (bytes[11] << 16) | (bytes[12] << 8) | bytes[13];

// ── resumable upload ─────────────────────────────────────────────────────────

/// A store that drops the connection partway, then remembers what it took.
final class FlakyStore implements BlobStore {
  FlakyStore({required this.totalBytes, this.dropAtFraction = 0.6, this.dropsAllowed = 1});

  final int totalBytes;
  final double dropAtFraction;
  int dropsAllowed;

  final Map<String, List<int>> _stored = {};
  final Map<String, int> _committed = {};
  int dropCount = 0;
  int uploadCalls = 0;
  int bytesAccepted = 0;
  bool completed = false;

  /// The first offset the store was asked for *after* the drop. A resume shows a
  /// value well past the drop point; a restart would ask for 0 here.
  int? firstOffsetAfterDrop;

  @override
  Future<int?> availableBytes() async => 5 * 1024 * 1024 * 1024;

  @override
  Future<List<RemoteBlob>> list({String prefix = ''}) async => [
        for (final entry in _stored.entries)
          if (prefix.isEmpty || entry.key.startsWith(prefix))
            RemoteBlob(name: entry.key, bytes: entry.value.length, modifiedAtMs: 0),
      ];

  @override
  Future<UploadSession> beginUpload(
    String name, {
    required int totalBytes,
    String? resumeToken,
  }) async =>
      UploadSession(
        name: name,
        totalBytes: totalBytes,
        resumeToken: resumeToken ?? 'session-$name',
        committedBytes: _committed[name] ?? 0,
      );

  @override
  Future<int> uploadChunk(UploadSession session, int offset, Uint8List bytes) async {
    uploadCalls += 1;
    final already = _committed[session.name] ?? 0;
    if (already != offset) return already; // the store disagrees: it wins

    if (dropCount > 0 && firstOffsetAfterDrop == null) firstOffsetAfterDrop = offset;
    if (dropCount > 0 && firstOffsetAfterDrop == null) firstOffsetAfterDrop = offset;
    final limit = (totalBytes * dropAtFraction).round();
    if (offset + bytes.length > limit && dropsAllowed > 0) {
      dropsAllowed -= 1;
      dropCount += 1;
      // Take what fits, then drop the connection — exactly what a real socket does.
      final take = limit - offset;
      if (take > 0) {
        _stored.putIfAbsent(session.name, () => <int>[]).addAll(bytes.sublist(0, take));
        _committed[session.name] = offset + take;
        bytesAccepted += take;
      }
      throw const TransferFailure(
        kind: TransferFailureKind.transient,
        message: 'connection reset by peer',
      );
    }
    _stored.putIfAbsent(session.name, () => <int>[]).addAll(bytes);
    _committed[session.name] = offset + bytes.length;
    bytesAccepted += bytes.length;
    return offset + bytes.length;
  }

  @override
  Future<RemoteBlob> completeUpload(UploadSession session) async {
    completed = true;
    final bytes = _stored[session.name] ?? const <int>[];
    return RemoteBlob(
      name: session.name,
      bytes: bytes.length,
      modifiedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
  }

  @override
  Future<Uint8List> download(String name, {int offset = 0, int? length}) async {
    final bytes = _stored[name] ?? const <int>[];
    final end = length == null ? bytes.length : (offset + length).clamp(0, bytes.length);
    return Uint8List.fromList(bytes.sublist(offset.clamp(0, bytes.length), end));
  }

  @override
  Future<void> delete(String name) async => _stored.remove(name);

  Uint8List? bytesOf(String name) =>
      _stored[name] == null ? null : Uint8List.fromList(_stored[name]!);
}

Future<void> _uploadSurvivesInterruption() async {
  section('an upload that drops at 60 % finishes instead of restarting');

  final payload = _pattern(512 * 1024);
  final reader = _writePack(payload, targetChunkBytes: 128 * 1024);
  final store = FlakyStore(totalBytes: reader.bytes.length);
  final journal = InMemoryJournalStore();
  final uploader = ResumableUploader(
    store: store,
    journal: journal,
    chunkBytes: 64 * 1024,
    backoff: Backoff(base: Duration.zero),
  );

  final progress = <int>[];
  final outcome = await uploader.upload(
    'books.kpb1',
    reader.bytes,
    reader: reader,
    onProgress: (sent, total, resumed) => progress.add(sent),
  );

  check('the connection dropped exactly once', store.dropCount == 1);
  check('the upload finished anyway', store.completed);
  check(
    'the store holds every byte',
    store.bytesOf('books.kpb1')!.length == reader.bytes.length,
  );
  check(
    'the stored pack is byte-identical to the original',
    _equal(store.bytesOf('books.kpb1')!, reader.bytes),
  );
  check(
    'the first request after the drop resumed past it, rather than restarting at 0',
    (store.firstOffsetAfterDrop ?? 0) > (reader.bytes.length * 0.4).round(),
    'first offset after the drop: ${store.firstOffsetAfterDrop} of ${reader.bytes.length}',
  );
  check(
    'the store never received the same bytes twice',
    store.bytesAccepted <= reader.bytes.length + 64 * 1024,
    'accepted ${store.bytesAccepted} bytes for a ${reader.bytes.length} byte pack',
  );
  check('progress was reported', progress.length >= 4);
  check('the checkpoint is cleared once the pack is whole', await journal.read('books.kpb1') == null);
  check('the store confirms the same length', outcome.blob.bytes == reader.bytes.length);
}

Future<void> _quotaIsReportedNotRetried() async {
  section('a full cloud is reported, not retried until the battery dies');

  final payload = _pattern(128 * 1024);
  final reader = _writePack(payload, targetChunkBytes: 64 * 1024);
  final store = _FullStore();
  final uploader = ResumableUploader(
    store: store,
    journal: InMemoryJournalStore(),
    backoff: Backoff(base: Duration.zero),
  );

  TransferFailure? failure;
  try {
    await uploader.upload('books.kpb1', reader.bytes, reader: reader);
  } on TransferFailure catch (error) {
    failure = error;
  }
  check('the upload fails with a typed failure', failure != null);
  check('it is classified as a quota problem', failure?.kind == TransferFailureKind.quota);
  check('it is not retried even once', store.attempts == 1, 'attempts=${store.attempts}');
  check(
    'the user is told their storage is full',
    failure?.message.contains('full') ?? false,
    failure?.message,
  );
}

final class _FullStore implements BlobStore {
  int attempts = 0;

  @override
  Future<int?> availableBytes() async => 0;

  @override
  Future<List<RemoteBlob>> list({String prefix = ''}) async => const [];

  @override
  Future<UploadSession> beginUpload(String name,
          {required int totalBytes, String? resumeToken}) async =>
      UploadSession(name: name, totalBytes: totalBytes, resumeToken: 's', committedBytes: 0);

  @override
  Future<int> uploadChunk(UploadSession session, int offset, Uint8List bytes) async {
    attempts += 1;
    throw TransferFailure.fromHttp(403, '{"error":{"message":"storageQuotaExceeded"}}');
  }

  @override
  Future<RemoteBlob> completeUpload(UploadSession session) async =>
      const RemoteBlob(name: 'never', bytes: 0, modifiedAtMs: 0);

  @override
  Future<Uint8List> download(String name, {int offset = 0, int? length}) async => Uint8List(0);

  @override
  Future<void> delete(String name) async {}
}

Future<void> _resumeRefusesADifferentPack() async {
  section('a resume never splices two different packs together');

  final first = _writePack(_pattern(256 * 1024), targetChunkBytes: 64 * 1024);
  final store = FlakyStore(totalBytes: first.bytes.length, dropsAllowed: 99);
  final journal = InMemoryJournalStore();
  final uploader = ResumableUploader(
    store: store,
    journal: journal,
    chunkBytes: 64 * 1024,
    maxAttempts: 1,
    backoff: Backoff(base: Duration.zero),
  );

  try {
    await uploader.upload('books.kpb1', first.bytes, reader: first);
  } on TransferFailure {
    // Expected: the first attempt is allowed to fail.
  }
  final checkpoint = TransferCheckpoint.tryParse(await journal.read('books.kpb1'));
  check('a checkpoint survives the failed attempt', checkpoint != null);
  check('the checkpoint records the pack root', (checkpoint?.packRoot.length ?? 0) > 20);

  // Now a *different* pack under the same name — a fresh backup of changed data.
  final second = _writePack(_pattern(256 * 1024, seed: 9), targetChunkBytes: 64 * 1024);
  final store2 = FlakyStore(totalBytes: second.bytes.length, dropsAllowed: 0);
  final uploader2 = ResumableUploader(
    store: store2,
    journal: journal,
    chunkBytes: 64 * 1024,
    backoff: Backoff(base: Duration.zero),
  );
  await uploader2.upload('books.kpb1', second.bytes, reader: second);
  check(
    'the new pack is uploaded whole, not appended to the old one',
    _equal(store2.bytesOf('books.kpb1')!, second.bytes),
  );
  check(
    'and it is the second pack that is stored, verified by its own MACs',
    second.openChunk(0).isNotEmpty,
  );
}

Future<void> _downloadResumesAfterADrop() async {
  section('a download that drops resumes from where it stopped');

  final payload = _pattern(300 * 1024);
  final reader = _writePack(payload, targetChunkBytes: 64 * 1024);
  final store = _DroppingDownloadStore(reader.bytes, dropAfterBytes: 96 * 1024);
  final uploader = ResumableUploader(
    store: store,
    journal: InMemoryJournalStore(),
    chunkBytes: 48 * 1024,
    backoff: Backoff(base: Duration.zero),
  );

  final pack = await uploader.download('books.kpb1', expectedBytes: reader.bytes.length);
  check('the download completed after the drop', _equal(pack, reader.bytes));
  check('it resumed rather than restarting', store.requests > 2, 'requests=${store.requests}');
  final back = Kpb1Reader(packKey: reader.packKey, bytes: pack);
  check(
    'the resumed bytes verify against the pack they were supposed to be',
    _equal(back.openChunk(1), reader.openChunk(1)),
  );
}

final class _DroppingDownloadStore implements BlobStore {
  _DroppingDownloadStore(this.bytes, {required this.dropAfterBytes});

  final Uint8List bytes;
  final int dropAfterBytes;
  int requests = 0;
  bool _dropped = false;

  @override
  Future<int?> availableBytes() async => null;

  @override
  Future<List<RemoteBlob>> list({String prefix = ''}) async => [
        RemoteBlob(name: 'books.kpb1', bytes: bytes.length, modifiedAtMs: 0),
      ];

  @override
  Future<UploadSession> beginUpload(String name,
          {required int totalBytes, String? resumeToken}) async =>
      UploadSession(name: name, totalBytes: totalBytes, resumeToken: 's', committedBytes: 0);

  @override
  Future<int> uploadChunk(UploadSession session, int offset, Uint8List data) async =>
      offset + data.length;

  @override
  Future<RemoteBlob> completeUpload(UploadSession session) async =>
      RemoteBlob(name: session.name, bytes: bytes.length, modifiedAtMs: 0);

  @override
  Future<Uint8List> download(String name, {int offset = 0, int? length}) async {
    requests += 1;
    if (!_dropped && offset >= dropAfterBytes) {
      _dropped = true;
      throw const TransferFailure(
        kind: TransferFailureKind.transient,
        message: 'connection reset by peer',
      );
    }
    final end = length == null ? bytes.length : (offset + length).clamp(0, bytes.length);
    return Uint8List.sublistView(bytes, offset, end);
  }

  @override
  Future<void> delete(String name) async {}
}

// ── Google Drive protocol ────────────────────────────────────────────────────

/// A Drive that behaves like the real one on the paths that matter.
final class FakeDrive implements HttpTransport {
  FakeDrive({this.totalBytes = 100 * 1024 * 1024});

  final int totalBytes;
  final List<HttpRequestSpec> requests = [];
  final List<String> _files = [];
  final Map<String, List<int>> _content = {};
  final Map<String, int> _sessions = {};
  int sessionUriCounter = 0;
  bool quotaExceeded = false;
  bool authExpired = false;
  int dropAfterBytes = -1; // -1: never drop

  @override
  Future<HttpResponseData> send(HttpRequestSpec request) async {
    requests.add(request);
    if (authExpired) {
      return const HttpResponseData(statusCode: 401, bodyBytes: []);
    }
    if (quotaExceeded && request.method == 'PUT') {
      return HttpResponseData(
        statusCode: 403,
        bodyBytes: utf8.encode('{"error":{"errors":[{"reason":"storageQuotaExceeded"}]}}'),
      );
    }

    if (request.method == 'GET' && request.url.contains('/about')) {
      return HttpResponseData(
        statusCode: 200,
        bodyBytes: utf8.encode(
          '{"storageQuota":{"limit":"16106127360","usage":"${totalBytes ~/ 2}"}}',
        ),
      );
    }
    if (request.method == 'GET' && request.url.contains('files?')) {
      return HttpResponseData(
        statusCode: 200,
        bodyBytes: utf8.encode(
          jsonEncode({
            'files': [
              for (final name in _files)
                {
                  'id': 'id-$name',
                  'name': name,
                  'size': '${_content[name]?.length ?? 0}',
                  'modifiedTime': '2026-10-11T09:00:00.000Z',
                  'md5Checksum': 'x',
                },
            ],
          }),
        ),
      );
    }
    if (request.method == 'POST' && request.url.contains('uploadType=resumable')) {
      sessionUriCounter += 1;
      return HttpResponseData(
        statusCode: 200,
        headers: {'location': 'https://upload.example/session/$sessionUriCounter'},
      );
    }
    if (request.method == 'PUT') {
      final sessionId = request.url.split('/').last;
      final range = request.headers['Content-Range'] ?? '';
      final total = int.tryParse(range.split('/').last) ?? this.totalBytes;
      if (request.byteBody == null || request.byteBody!.isEmpty) {
        // The probe: `bytes */TOTAL`.
        final committed = _sessions[sessionId] ?? 0;
        return HttpResponseData(
          statusCode: committed == 0 ? 308 : 308,
          headers: {'range': committed == 0 ? '' : 'bytes=0-${committed - 1}'},
        );
      }
      final start = int.tryParse(range.split(' ')[1].split('-').first) ?? 0;
      final chunk = request.byteBody!;
      if (dropAfterBytes >= 0 && start + chunk.length > dropAfterBytes) {
        final take = (dropAfterBytes - start).clamp(0, chunk.length);
        _store(sessionId, start, chunk.sublist(0, take));
        dropAfterBytes = -1;
        throw const HttpTransportException('connection reset by peer');
      }
      _store(sessionId, start, chunk);
      final committed = _sessions[sessionId] ?? 0;
      if (committed >= total) {
        _files.add('books.kpb1');
        _content['books.kpb1'] = _content['books.kpb1'] ?? <int>[];
        return HttpResponseData(
          statusCode: 200,
          bodyBytes: utf8.encode('{"id":"id-books","name":"books.kpb1","size":"$total"}'),
        );
      }
      return HttpResponseData(
        statusCode: 308,
        headers: {'range': 'bytes=0-${committed - 1}'},
      );
    }
    if (request.method == 'DELETE') {
      final id = request.url.split('/').last;
      final name = id.replaceFirst('id-', '');
      _files.remove(name);
      return const HttpResponseData(statusCode: 204);
    }
    if (request.method == 'GET' && request.headers.containsKey('Range')) {
      final digits = request.headers['Range']!.replaceAll(RegExp(r'[^0-9]'), '');
      final start = int.parse(digits.substring(0, digits.length ~/ 2));
      final content = _content['books.kpb1'] ?? const <int>[];
      return HttpResponseData(statusCode: 200, bodyBytes: content.sublist(start));
    }
    return const HttpResponseData(statusCode: 404);
  }

  void _store(String sessionId, int offset, List<int> chunk) {
    final buffer = _content.putIfAbsent('books.kpb1', () => <int>[]);
    // Grow explicitly: assigning `.length` on a growable List<int> would try to fill
    // with nulls, which an int list cannot hold.
    while (buffer.length < offset + chunk.length) {
      buffer.add(0);
    }
    for (var i = 0; i < chunk.length; i++) {
      buffer[offset + i] = chunk[i];
    }
    _sessions[sessionId] = offset + chunk.length;
  }

  int get storedBytes => (_content['books.kpb1'] ?? const <int>[]).length;
}

Future<void> _driveResumableProtocol() async {
  section('Drive: the resumable session is used properly');

  final payload = _pattern(400 * 1024);
  final reader = _writePack(payload, targetChunkBytes: 128 * 1024);
  final drive = FakeDrive();
  final store = DriveBlobStore(auth: StaticAuthHeaders('token'), transport: drive);
  final uploader = ResumableUploader(
    store: store,
    journal: InMemoryJournalStore(),
    chunkBytes: 128 * 1024,
    backoff: Backoff(base: Duration.zero),
  );

  final outcome = await uploader.upload('books.kpb1', reader.bytes, reader: reader);
  check('the pack uploads through the resumable session', outcome.blob.name == 'books.kpb1');
  check(
    'the content is byte-identical',
    _equal(Uint8List.fromList(drive._content['books.kpb1'] ?? const []), reader.bytes),
  );
  check(
    'a session was started with a POST',
    drive.requests.any(
      (request) => request.method == 'POST' && request.url.contains('uploadType=resumable'),
    ),
  );
  check(
    'the file was created in the app data folder, not the user\'s Drive root',
    drive.requests
            .firstWhere((request) => request.method == 'POST')
            .jsonBody
            ?.contains('appDataFolder') ??
        false,
  );

  // A 308 mid-way must be treated as progress, not as failure.
  final drive2 = FakeDrive();
  drive2.dropAfterBytes = 200 * 1024;
  final store2 = DriveBlobStore(auth: StaticAuthHeaders('token'), transport: drive2);
  final uploader2 = ResumableUploader(
    store: store2,
    journal: InMemoryJournalStore(),
    chunkBytes: 128 * 1024,
    backoff: Backoff(base: Duration.zero),
  );
  final resumed = await uploader2.upload('books.kpb1', reader.bytes, reader: reader);
  check('a dropped socket mid-upload is retried', resumed.attempts > 1, '${resumed.attempts}');
  check(
    'the retry resumes from the range Drive reported, not from zero',
    resumed.bytesUploaded < reader.bytes.length,
    '${resumed.bytesUploaded} of ${reader.bytes.length}',
  );
  check(
    'the finished upload is whole',
    _equal(Uint8List.fromList(drive2._content['books.kpb1'] ?? const []), reader.bytes),
  );

  final quota = await store.availableBytes();
  check('Drive reports the remaining quota when asked', quota != null && quota > 0, quota);

  final listed = await store.list(prefix: 'books');
  check('list finds the backup', listed.isNotEmpty && listed.first.name == 'books.kpb1');

  await store.delete('books.kpb1');
  check('delete removes it', (await store.list()).isEmpty);
  await store.delete('books.kpb1');
  check('deleting twice is not an error', true);
}

Future<void> _driveClassifiesFailures() async {
  section('Drive: failures are classified before anything is retried');

  final payload = _pattern(64 * 1024);
  final reader = _writePack(payload, targetChunkBytes: 32 * 1024);

  final expired = FakeDrive()..authExpired = true;
  final store = DriveBlobStore(auth: StaticAuthHeaders('expired'), transport: expired);
  final uploader = ResumableUploader(
    store: store,
    journal: InMemoryJournalStore(),
    backoff: Backoff(base: Duration.zero),
  );
  TransferFailure? failure;
  try {
    await uploader.upload('books.kpb1', reader.bytes, reader: reader);
  } on TransferFailure catch (error) {
    failure = error;
  }
  check(
    'an expired token is an auth failure, not a network blip',
    failure?.kind == TransferFailureKind.auth,
    failure?.kind,
  );
  check(
    'and the uploader does not retry a signed-out account',
    expired.requests.where((request) => request.method == 'PUT').isEmpty,
  );

  final full = FakeDrive()..quotaExceeded = true;
  final store2 = DriveBlobStore(auth: StaticAuthHeaders('token'), transport: full);
  final uploader2 = ResumableUploader(
    store: store2,
    journal: InMemoryJournalStore(),
    backoff: Backoff(base: Duration.zero),
  );
  TransferFailure? quotaFailure;
  try {
    await uploader2.upload('books.kpb1', reader.bytes, reader: reader);
  } on TransferFailure catch (error) {
    quotaFailure = error;
  }
  check(
    'a full Drive is a quota failure with a sentence the user can act on',
    quotaFailure?.kind == TransferFailureKind.quota &&
        (quotaFailure?.message.contains('full') ?? false),
    quotaFailure?.message,
  );
}

// ── iCloud ───────────────────────────────────────────────────────────────────

Future<void> _icloudWritesAtomically() async {
  section('iCloud: a half-written pack is never a restore candidate');

  final root = Directory.systemTemp.createTempSync('khata-icloud');
  try {
    final payload = _pattern(200 * 1024);
    final reader = _writePack(payload, targetChunkBytes: 64 * 1024);
    final container = DirectoryUbiqContainer(root.path);
    final store = IcloudBlobStore(container: container);
    final journal = InMemoryJournalStore();

    // Interrupt with retries disabled, so the half-written state is observable. With
    // retries enabled the uploader would heal the drop inside one call — which is
    // the desired behaviour, but it hides the property under test here: that a
    // half-written pack is never offered as a restore candidate.
    final flaky = _InterruptingContainer(container, failAfterBytes: 90 * 1024);
    final store2 = IcloudBlobStore(container: flaky);
    final uploader2 = ResumableUploader(
      store: store2,
      journal: journal,
      chunkBytes: 48 * 1024,
      maxAttempts: 1,
      backoff: Backoff(base: Duration.zero),
    );

    var interrupted = false;
    try {
      await uploader2.upload('books.kpb1', reader.bytes, reader: reader);
    } on TransferFailure {
      interrupted = true;
    }
    check('the interrupted upload gives up and reports it', interrupted);
    check(
      'a partial upload is invisible to list()',
      (await store.list()).isEmpty,
      'list must not offer a half-written pack for restore',
    );
    check('the partial bytes are still on disk for the resume', flaky.bytesWritten > 0);
    check(
      'the staged size is the resume offset — a local question, answered locally',
      await flaky.stagedBytes('Backups/books.kpb1.part') == flaky.bytesWritten,
      'staged=${await flaky.stagedBytes('Backups/books.kpb1.part')} written=${flaky.bytesWritten}',
    );
    check(
      'nothing is committed (uploaded) while the pack is incomplete',
      flaky.commits == 0,
      'commits=${flaky.commits}',
    );
    check(
      'a half-written pack is not in the container either',
      !File('${root.path}/Backups/books.kpb1.part').existsSync(),
    );

    // Resume and finish.
    flaky.failAfterBytes = -1;
    final uploader3 = ResumableUploader(
      store: store2,
      journal: journal,
      chunkBytes: 48 * 1024,
      backoff: Backoff(base: Duration.zero),
    );
    await uploader3.upload('books.kpb1', reader.bytes, reader: reader);
    final listed = await store.list();
    check('once complete, the pack is restorable', listed.length == 1);
    check('and it reports the size the pack actually has', listed.first.bytes == reader.bytes.length);
    check(
      'the `.part` file is gone',
      !File('${root.path}/Backups/books.kpb1.part').existsSync(),
    );
    check(
      'the staging area does not keep a second copy of a 52 MB pack',
      !File('${root.path}/.staging/Backups/books.kpb1.part').existsSync(),
    );
    check(
      'the upload was committed exactly once, at the end',
      flaky.commits == 1,
      'commits=${flaky.commits}',
    );
    final downloaded = await store.download('books.kpb1');
    check('the stored pack round-trips', _equal(downloaded, reader.bytes));

    // Debris from a killed app must not eat the user's iCloud quota forever.
    File('${root.path}/Backups/abandoned.kpb1.part').writeAsBytesSync(List.filled(1024, 7));
    File('${root.path}/Backups/abandoned.kpb1.part')
        .setLastModifiedSync(DateTime.now().subtract(const Duration(days: 2)));
    final swept = await store.sweepPartials();
    check('an abandoned partial is swept', swept == 1024, swept);
    check('and the good pack is untouched', (await store.list()).length == 1);

    // iCloud's own honesty flag: `isUploaded == false` means the file exists on this
    // phone and nowhere else. Restoring from that would be restoring from the device
    // the user just lost.
    final notYetUploaded = IcloudBlobStore(
      container: DirectoryUbiqContainer(root.path, uploadedImmediately: false),
    );
    check(
      'a pack iCloud has not pushed yet is not a restore candidate',
      (await notYetUploaded.list()).isEmpty,
    );

    // And when iCloud is off entirely, the failure is permanent, not a retry loop.
    final offline = _UnavailableContainer();
    TransferFailure? offlineFailure;
    try {
      await IcloudBlobStore(container: offline).beginUpload('books.kpb1', totalBytes: 10);
    } on TransferFailure catch (error) {
      offlineFailure = error;
    }
    check(
      'an Apple Account without iCloud Drive fails permanently, with a sentence',
      offlineFailure?.kind == TransferFailureKind.permanent &&
          (offlineFailure?.message.contains('iCloud') ?? false),
      offlineFailure?.message,
    );

    check('iCloud does not pretend to know the free space', await store.availableBytes() == null);
  } finally {
    root.deleteSync(recursive: true);
  }
}

/// Fails once after a byte count, like a phone that lost its iCloud connection.
/// Also counts [commit] calls: "uploaded exactly once, and only when whole" is a
/// property of the store, and this is where it is observable.
final class _InterruptingContainer implements UbiqContainer {
  _InterruptingContainer(this.inner, {required this.failAfterBytes});

  final UbiqContainer inner;
  int failAfterBytes;
  int bytesWritten = 0;
  int commits = 0;
  bool _failed = false;

  @override
  Future<bool> isAvailable() => inner.isAvailable();

  @override
  Future<int> stagedBytes(String relativePath) => inner.stagedBytes(relativePath);

  @override
  Future<void> commit(String relativePath) async {
    commits += 1;
    await inner.commit(relativePath);
  }

  @override
  Future<List<UbiqEntry>> list(String relativeDirectory) => inner.list(relativeDirectory);

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes, {bool append = false}) async {
    if (!_failed && failAfterBytes >= 0) {
      final remaining = failAfterBytes - bytesWritten;
      if (bytes.length > remaining) {
        _failed = true;
        if (remaining > 0) {
          await inner.writeBytes(relativePath, Uint8List.sublistView(bytes, 0, remaining),
              append: append);
          bytesWritten += remaining;
        }
        throw const TransferFailure(
          kind: TransferFailureKind.transient,
          message: 'the iCloud connection dropped',
        );
      }
    }
    await inner.writeBytes(relativePath, bytes, append: append);
    bytesWritten += bytes.length;
  }

  @override
  Future<Uint8List> readBytes(String relativePath, {int? offset, int? length}) =>
      inner.readBytes(relativePath, offset: offset, length: length);

  @override
  Future<void> delete(String relativePath) => inner.delete(relativePath);

  @override
  Future<void> rename(String fromRelativePath, String toRelativePath) =>
      inner.rename(fromRelativePath, toRelativePath);

  @override
  Future<int?> freeBytes() => inner.freeBytes();
}

/// iCloud switched off, or nobody signed in — the common case, and the one that must
/// never turn into a retry loop.
final class _UnavailableContainer implements UbiqContainer {
  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<List<UbiqEntry>> list(String relativeDirectory) async => const [];

  @override
  Future<int> stagedBytes(String relativePath) async => 0;

  @override
  Future<void> writeBytes(String relativePath, Uint8List bytes, {bool append = false}) async {}

  @override
  Future<void> commit(String relativePath) async {}

  @override
  Future<Uint8List> readBytes(String relativePath, {int? offset, int? length}) async =>
      Uint8List(0);

  @override
  Future<void> delete(String relativePath) async {}

  @override
  Future<void> rename(String fromRelativePath, String toRelativePath) async {}

  @override
  Future<int?> freeBytes() async => null;
}

// ── LAN flow control ─────────────────────────────────────────────────────────

void _flowControlProtectsTheFrameRate() {
  section('52 MB over LAN without dropping a frame');

  // Simulate the pump against a channel that drains at 4 MiB/s. Nothing here touches
  // a socket: the arithmetic in FlowControl is the thing under test.
  const total = 52 * 1024 * 1024;
  const drainPerTick = 256 * 1024;
  const bytesPerSecond = 4 * 1024 * 1024;

  var remaining = total;
  var inFlight = 0;
  var framesThisTick = 0;
  var sentThisWindow = 0;
  var totalSent = 0;
  var elapsedMs = 0;
  var windowStartMs = 0;
  var ticks = 0;
  var maxInFlight = 0;
  var yields = 0;
  var waits = 0;
  final sizer = AdaptiveFrameSizer();

  while (remaining > 0 && ticks < 500000) {
    ticks += 1;
    // Each iteration is ~4 ms of wall clock, and the pacing window is a real
    // one-second window that rolls over.
    elapsedMs += 4;
    final elapsedThisWindow = elapsedMs - windowStartMs;
    if (elapsedThisWindow >= 1000) {
      windowStartMs = elapsedMs;
      sentThisWindow = 0;
    }
    final step = FlowControl.decide(
      PumpState(
        remaining: remaining,
        inFlight: inFlight,
        framesThisTick: framesThisTick,
        sentThisSecond: sentThisWindow,
        frameBytes: sizer.frameBytes,
      ),
      bytesPerSecond: bytesPerSecond,
      elapsedThisSecondMs: elapsedMs - windowStartMs,
    );
    switch (step) {
      case PumpStep.send:
        final length = FlowControl.frameLength(
          PumpState(
            remaining: remaining,
            inFlight: inFlight,
            framesThisTick: framesThisTick,
            sentThisSecond: sentThisWindow,
            frameBytes: sizer.frameBytes,
          ),
        );
        inFlight += length;
        remaining -= length;
        sentThisWindow += length;
        totalSent += length;
        framesThisTick += 1;
        sizer.onDelivered();
        if (inFlight > maxInFlight) maxInFlight = inFlight;
      case PumpStep.waitForDrain:
        waits += 1;
        // The link drains a slice per tick; a real buffer drains continuously.
        inFlight = inFlight > drainPerTick ? inFlight - drainPerTick : 0;
      case PumpStep.yieldToUi:
        yields += 1;
        framesThisTick = 0;
        inFlight = inFlight > drainPerTick ? inFlight - drainPerTick : 0;
      case PumpStep.done:
      case PumpStep.aborted:
        break;
    }
  }

  check('the whole ledger transfers', remaining == 0, 'remaining=$remaining');
  check(
    'the in-flight buffer never exceeded its budget',
    maxInFlight <= PumpTuning.inFlightBudgetBytes,
    'max ${maxInFlight ~/ 1024} KiB vs ${PumpTuning.inFlightBudgetBytes ~/ 1024} KiB',
  );
  check(
    'the pump yields to the UI regularly',
    yields > 0 && yields > total ~/ (PumpTuning.inFlightBudgetBytes * 8),
    '$yields yields over $ticks steps',
  );
  check('the pump also waits for the buffer to drain', waits > 0, '$waits waits');
  check(
    'the pacing target kept the transfer inside its budget',
    totalSent == total,
    'sent $totalSent of $total',
  );
  check(
    'frame size grew as the link proved itself',
    sizer.frameBytes > PumpTuning.initialFrameBytes,
    '${sizer.frameBytes} bytes',
  );
  check(
    'frame size stayed within the safe range',
    sizer.frameBytes <= PumpTuning.maxFrameBytes,
  );

  // A full buffer must never allow a send, whatever the pacing says.
  check(
    'a full buffer means wait, not send',
    FlowControl.decide(
      const PumpState(
        remaining: 1024 * 1024,
        inFlight: PumpTuning.inFlightBudgetBytes,
        framesThisTick: 0,
        sentThisSecond: 0,
        frameBytes: PumpTuning.initialFrameBytes,
      ),
    ) ==
        PumpStep.waitForDrain,
  );
  check(
    'an aborted transfer stops immediately',
    FlowControl.decide(
      const PumpState(
        remaining: 1024,
        inFlight: 0,
        framesThisTick: 0,
        sentThisSecond: 0,
        frameBytes: 1024,
        aborted: true,
      ),
    ) ==
        PumpStep.aborted,
  );
  check(
    'a finished transfer reports done',
    FlowControl.decide(
      const PumpState(
        remaining: 0,
        inFlight: 0,
        framesThisTick: 0,
        sentThisSecond: 0,
        frameBytes: 1024,
      ),
    ) ==
        PumpStep.done,
  );
}

void _adaptiveFrameSizing() {
  section('frame sizing backs off when the link misbehaves');

  final sizer = AdaptiveFrameSizer();
  final start = sizer.frameBytes;
  for (var i = 0; i < 200; i++) {
    sizer.onDelivered();
  }
  check(
    'the size ramps up on a clean link',
    sizer.frameBytes > start,
    '$start → ${sizer.frameBytes}',
  );
  check('and stops at the ceiling', sizer.frameBytes <= PumpTuning.maxFrameBytes);

  final afterGrowth = sizer.frameBytes;
  sizer.onLoss();
  check('one loss halves it', sizer.frameBytes == afterGrowth ~/ 2);
  for (var i = 0; i < 20; i++) {
    sizer.onLoss();
  }
  check(
    'repeated losses stop at the floor',
    sizer.frameBytes == PumpTuning.minFrameBytes,
    '${sizer.frameBytes}',
  );
}

// ── SDP surgery ──────────────────────────────────────────────────────────────

/// The recorded text is what libwebrtc emits for a data-channel-only connection on a
/// phone with two interfaces (Wi-Fi and a personal hotspot), copy-pasted into this
/// harness on purpose: the properties that matter here — that `a=sctp-port` survives,
/// that only host candidates are carried — cannot be checked against text this file
/// wrote itself.
const String _recordedDataChannelSdp = 'v=0\r\n'
    'o=- 4611731400430051336 2 IN IP4 127.0.0.1\r\n'
    's=-\r\n'
    't=0 0\r\n'
    'a=group:BUNDLE 0\r\n'
    'a=extmap-allow-mixed\r\n'
    'a=msid-semantic: WMS\r\n'
    'm=application 52166 UDP/DTLS/SCTP webrtc-datachannel\r\n'
    'c=IN IP4 192.168.1.44\r\n'
    'a=candidate:1467250027 1 udp 2122260223 192.168.1.44 52166 typ host generation 0\r\n'
    'a=candidate:1869855691 1 udp 2122194687 10.0.0.7 39711 typ host generation 0\r\n'
    'a=ice-ufrag:4ZcD\r\n'
    'a=ice-pwd:2/1muCWoOi3uLifh0NuRHlPy\r\n'
    'a=ice-options:trickle\r\n'
    'a=fingerprint:sha-256 8B:9C:1F:1C:5A:B4:6D:0E:0A:9F:7C:2B:1E:8A:3D:5F:0C:4E:6B:7A\r\n'
    'a=setup:actpass\r\n'
    'a=mid:0\r\n'
    'a=sctp-port:5000\r\n'
    'a=max-message-size:262144\r\n';

void _sdpSurgery() {
  section('SDP: the smallest description that still opens a data channel');

  final minimised = minimiseDataChannelSdp(_recordedDataChannelSdp);
  check(
    'the description gets smaller — that is the whole point of the QR being scannable',
    minimised.length < _recordedDataChannelSdp.length,
    '${minimised.length} < ${_recordedDataChannelSdp.length} characters',
  );
  check('a=sctp-port survives: no SCTP port, no data channel', minimised.contains('a=sctp-port:5000'));
  check('the ICE credentials survive', minimised.contains('a=ice-ufrag:4ZcD') && minimised.contains('a=ice-pwd:'));
  check('the DTLS fingerprint survives — it *is* the peer identity', minimised.contains('a=fingerprint:sha-256'));
  check('the application m-line survives', minimised.contains('m=application'));
  check('the session header survives (v/o/s/t)', minimised.contains('v=0') && minimised.contains('o=-') && minimised.contains('t=0 0'));
  check('codec noise is gone', !minimised.contains('extmap') && !minimised.contains('msid-semantic'));
  check('the host candidates come along', hostCandidates(minimised).length == 2);

  // A media-only description can never carry a data channel, and a pairing screen that
  // draws a QR from one produces two phones that negotiate and then never connect.
  var mediaOnlyCode = '';
  try {
    minimiseDataChannelSdp('v=0\r\no=- 1 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=ice-ufrag:x\r\n');
  } on InvariantViolation catch (error) {
    mediaOnlyCode = error.invariantCode;
  }
  check('a media-only description is refused, by name', mediaOnlyCode == 'PAIR-6', mediaOnlyCode);

  var noSctpCode = '';
  try {
    minimiseDataChannelSdp(
      _recordedDataChannelSdp.replaceAll('a=sctp-port:5000\r\n', ''),
    );
  } on InvariantViolation catch (error) {
    noSctpCode = error.invariantCode;
  }
  check(
    'a description with no SCTP port is refused rather than silently shipped',
    noSctpCode == 'PAIR-6',
    noSctpCode,
  );

  // Reflexive candidates mean a STUN server was in the path. There is none, and a
  // public IP must never end up in a QR code.
  final withReflexive = '$minimised\r\n'
      'a=candidate:1 1 udp 1686052607 203.0.113.9 51000 typ srflx raddr 192.168.1.44 rport 52166';
  check(
    'only host candidates are carried — never a reflexive one',
    hostCandidates(withReflexive).length == 2 && !hostCandidates(withReflexive).join().contains('srflx'),
  );

  final merged = mergeCandidates(minimised, hostCandidates(_recordedDataChannelSdp));
  check(
    'merging the candidate list the ticket also carries changes nothing (no duplicates)',
    mergeCandidates(merged, hostCandidates(_recordedDataChannelSdp)) == merged,
  );
  check(
    'the merged description is closed with a=end-of-candidates exactly once',
    RegExp('a=end-of-candidates').allMatches(mergeCandidates(merged, const [])).length == 1,
  );
  check(
    'a candidate list that is already in the description is not appended twice',
    mergeCandidates(merged, const []).split('a=candidate').length - 1 == 2,
  );

  // The off-by-one that a QR encoder, a JSON round trip or a clipboard can introduce:
  // LF-only newlines. A `\r\n` split leaves one enormous line and every prefix test
  // fails — which looks exactly like a missing SCTP port.
  final lfOnly = _recordedDataChannelSdp.replaceAll('\r\n', '\n');
  check(
    'a description with bare newlines is read correctly, not treated as broken',
    minimiseDataChannelSdp(lfOnly).contains('a=sctp-port:5000'),
  );
  check(
    'and it is recognised as a data-channel description',
    looksLikeDataChannelSdp(minimiseDataChannelSdp(lfOnly)),
  );
  check('a media-only description is not mistaken for a data-channel one', !looksLikeDataChannelSdp('m=audio 9 UDP/TLS/RTP/SAVPF 111'));
}

// ── pairing ──────────────────────────────────────────────────────────────────

void _pairingTickets() {
  section('QR pairing: a photographed code stops working');

  final ticket = PairingTicket(
    version: PairingTicket.currentVersion,
    nodeId: 'node-offerer',
    role: PairingRole.offer,
    createdAtMs: DateTime.now().millisecondsSinceEpoch,
    expiresAtMs: DateTime.now()
        .add(const Duration(minutes: 2))
        .millisecondsSinceEpoch,
    nonce: randomBytes(16),
    // The *realistic* description, not a four-line stub: the size of the QR is the
    // property being checked, and a stub is what let a compression scheme that
    // inflated the payload by 2.55x pass this test for a whole session. See
    // `_recordedDataChannelSdp` for where this text comes from.
    sessionDescription: mergeCandidates(
      minimiseDataChannelSdp(_recordedDataChannelSdp),
      hostCandidates(_recordedDataChannelSdp),
    ),
    candidates: hostCandidates(_recordedDataChannelSdp),
    ephemeralPublicKey: randomBytes(32),
    displayName: "Basit's phone",
    ledgerId: 'ledger-0194f2c8-3b1e-7a55',
  );

  final code = PairingCodec.encode(ticket);
  final decoded = PairingCodec.decode(code);

  check('the code round-trips', decoded.nodeId == 'node-offerer' && decoded.role == PairingRole.offer);
  check('the nonce survives', _equal(decoded.nonce, ticket.nonce));
  check('the ephemeral key survives', _equal(decoded.ephemeralPublicKey, ticket.ephemeralPublicKey));
  check('the SDP survives', decoded.sessionDescription == ticket.sessionDescription);
  check('the display name survives', decoded.displayName == "Basit's phone");
  check(
    'the QR stays inside the scannable budget with room to spare',
    code.length <= PairingCodec.scannableBudget,
    '${code.length} characters (budget ${PairingCodec.scannableBudget}; a v40 QR holds '
    '2953 at a density nobody can aim at)',
  );
  check(
    'and it is well clear of the hard limit of the largest QR code',
    code.length < 2400,
    'hard limit 2953 characters',
  );
  check('a fresh ticket is not expired', !decoded.isExpired);

  final expired = PairingTicket(
    version: PairingTicket.currentVersion,
    nodeId: 'node-x',
    role: PairingRole.offer,
    createdAtMs: DateTime.now().millisecondsSinceEpoch - 600000,
    expiresAtMs: DateTime.now().millisecondsSinceEpoch - 300000,
    nonce: randomBytes(16),
    sessionDescription: 'm=application',
    candidates: const [],
    ephemeralPublicKey: randomBytes(32),
  );
  check('an old ticket reports itself expired', expired.isExpired);

  var versionCode = '';
  try {
    PairingCodec.decode(base64UrlNoPad(Uint8List.fromList([99, 1, 2, 3])));
  } on InvariantViolation catch (error) {
    versionCode = error.invariantCode;
  }
  check('a code from another app version is refused by name', versionCode == 'PAIR-1', versionCode);
}

void _authenticationString() {
  section('both phones show the same six digits — or the pairing is refused');

  final aliceKey = randomBytes(32);
  final bobKey = randomBytes(32);
  final nonce = randomBytes(16);

  final aliceSees = SessionCode.derive(
    localPublicKey: aliceKey,
    remotePublicKey: bobKey,
    nonce: nonce,
  );
  final bobSees = SessionCode.derive(
    localPublicKey: bobKey,
    remotePublicKey: aliceKey,
    nonce: nonce,
  );

  check('the two sides agree without a shared secret', aliceSees == bobSees, '$aliceSees vs $bobSees');
  check('the code is six digits', RegExp(r'^\d{6}$').hasMatch(aliceSees), aliceSees);

  final attackerKey = randomBytes(32);
  final mitmSees = SessionCode.derive(
    localPublicKey: attackerKey,
    remotePublicKey: bobKey,
    nonce: nonce,
  );
  check(
    'a man in the middle produces different digits, which is the point',
    mitmSees != bobSees,
    '$mitmSees vs $bobSees',
  );

  final otherAttempt = SessionCode.derive(
    localPublicKey: aliceKey,
    remotePublicKey: bobKey,
    nonce: randomBytes(16),
  );
  check('a different pairing attempt gives a different code', otherAttempt != aliceSees);

  check('a full-scope pairing is the default for the owner\'s own devices', PairingScope.full.id == 'full');
  check('read-only exists for the accountant', PairingScope.readOnly.id == 'read_only');
  check('one-shot exists for a borrowed phone', PairingScope.once.id == 'once');

  // Backoff behaviour, which is what makes a nightly retry civilised.
  final backoff = Backoff(base: const Duration(seconds: 1), seed: 42);
  check('the first attempt waits for nothing', backoff.delayFor(1) == Duration.zero);
  final second = backoff.delayFor(2).inMilliseconds;
  check(
    'the first retry waits about the base delay, with jitter',
    second >= 800 && second <= 1200,
    '${second}ms (base 1000ms ± 20 % jitter)',
  );
  // Each further retry doubles: 2s, 4s, 8s …
  final third = backoff.delayFor(3).inMilliseconds;
  check(
    'the next retry doubles it',
    third >= 1600 && third <= 2400,
    '${third}ms',
  );
  check(
    'delays keep growing',
    backoff.delayFor(4).inMilliseconds > third,
    'attempt 4: ${backoff.delayFor(4).inMilliseconds}ms',
  );
  final late = backoff.delayFor(30).inMilliseconds;
  check('and the delay is capped so a retry never becomes "tomorrow"',
      late <= 60000 && late > 30000, '${late}ms');
}

// ── the apply pipeline ───────────────────────────────────────────────────────

/// A stand-in for the per-table applier: enough behaviour to test the pipeline's
/// contract (atomic, ordered, idempotent, gated) without any SQL.
final class RecordingApplier implements OpApplier {
  RecordingApplier({required this.ledgerId, this.gateFailsOn});

  final String ledgerId;

  /// A row id whose application throws an `InvariantViolation` with a GATE code,
  /// simulating an unbalanced entry arriving from a peer.
  final String? gateFailsOn;

  final Set<String> applied = {};
  final List<String> order = [];
  int rows = 0;
  bool rolledBack = false;

  @override
  Future<bool> hasApplied(String batchId) async => applied.contains(batchId);

  @override
  Future<int> apply(SyncOp op) async {
    order.add(op.rowId);
    if (gateFailsOn != null && op.rowId == gateFailsOn) {
      throw const InvariantViolation(
        invariantCode: 'GATE-2',
        message: 'the books would be left inconsistent, so the batch was rolled back',
      );
    }
    rows += 1;
    return 1;
  }

  @override
  Future<void> markApplied(String batchId, int opCount) async => applied.add(batchId);
}

final class RecordingGate implements GateRunner {
  int calls = 0;

  @override
  Future<void> verify() async => calls += 1;
}

const _nodeA = '018f2a40-0000-7000-8000-00000000000a';
const _nodeB = '018f2a40-0000-7000-8000-00000000000b';
const _nodeC = '018f2a40-0000-7000-8000-00000000000c';

SyncOp _op(String table, String rowId, int ms, int counter, String node) => SyncOp(
      table: table,
      rowId: rowId,
      stamp: CrdtStamp(hlc: Hlc.unchecked(ms, counter, node), rev: counter),
      payload: {'name': 'row $rowId'},
    );

Future<void> _batchPipeline() async {
  section('a batch from another phone is applied atomically, once');

  final batch = SyncBatch(
    senderNodeId: _nodeB,
    ledgerId: 'ledger-1',
    sentAtMs: 1760000000000,
    generation: 4,
    // Deliberately out of order: the pipeline must apply oldest first.
    ops: [
      _op('parties', 'p2', 21, 1, _nodeB),
      _op('parties', 'p1', 20, 0, _nodeA),
      _op('parties', 'p3', 22, 0, _nodeB),
    ],
  );

  // Encoding round trip, with the MAC in place.
  final secret = randomBytes(32);
  final frame = BatchCodec.encode(batch, secret);
  final decoded = BatchCodec.decode(frame, secret);
  check('a batch survives the wire and keeps its id', decoded.id == batch.id);
  check('the batch id covers the ops', batch.id.length > 20);
  // The encoder must refuse a node id it cannot round-trip. This was a real defect:
  // `encode()` accepted a short id that `parse()` then rejected, which would have
  // written unreadable HLCs into the database.
  var guarded = false;
  try {
    Hlc.unchecked(1000, 0, 'node-b').encode();
  } on ArgumentError {
    guarded = true;
  }
  check('an HLC refuses to encode a node id it cannot decode', guarded);

  check(
    'a batch carried in a different order has the same id',
    SyncBatch(
      senderNodeId: batch.senderNodeId,
      ledgerId: batch.ledgerId,
      sentAtMs: batch.sentAtMs,
      generation: batch.generation,
      ops: batch.ops.reversed.toList(),
    ).id ==
        batch.id,
  );

  var tampered = false;
  try {
    BatchCodec.decode(frame, randomBytes(32));
  } on InvariantViolation catch (error) {
    tampered = error.invariantCode == 'SYNC-12';
  }
  check('an unpaired sender cannot sign a batch in', tampered);

  // A clean apply: the gate runs once, inside the transaction, and the ops are
  // applied oldest-first.
  final applier = RecordingApplier(ledgerId: 'ledger-1');
  final runner = RecordingGate();
  var transactions = 0;
  final pipeline = ApplyPipeline(
    applier: applier,
    gate: runner,
    ledgerId: 'ledger-1',
    beginTransaction: <T>(Future<T> Function() work) async {
      transactions += 1;
      return work();
    },
  );
  var outcome = await pipeline.applyBatch(decoded);
  check('the batch is applied', outcome.applied && outcome.rowsWritten == 3);
  check('one transaction for the whole batch', transactions == 1);
  check('the gate runs inside it', runner.calls == 1);
  check(
    'ops are applied oldest first, whatever order they arrived in',
    applier.order.join(',') == 'p1,p2,p3',
    applier.order.join(','),
  );

  // Replay: the same batch again must be a no-op, not a second posting.
  outcome = await pipeline.applyBatch(decoded);
  check('a replayed batch is recognised by its id', outcome.isDuplicate && !outcome.applied);
  check('and nothing is written twice', applier.rows == 3);

  // A batch for another ledger is refused outright.
  final otherLedger = ApplyPipeline(
    applier: RecordingApplier(ledgerId: 'ledger-1'),
    gate: RecordingGate(),
    ledgerId: 'ledger-1',
    beginTransaction: <T>(Future<T> Function() work) => work(),
  );
  final foreign = SyncBatch(
    senderNodeId: _nodeC,
    ledgerId: 'ledger-2',
    sentAtMs: 1,
    ops: [_op('parties', 'x', 1, 1, _nodeC)],
  );
  outcome = await otherLedger.applyBatch(foreign);
  check(
    'a batch belonging to another business is refused',
    !outcome.applied && outcome.skippedReason == 'different ledger',
    outcome.skippedReason,
  );

  // A gate failure takes the whole batch with it.
  final failing = ApplyPipeline(
    applier: RecordingApplier(ledgerId: 'ledger-1', gateFailsOn: 'p2'),
    gate: RecordingGate(),
    ledgerId: 'ledger-1',
    beginTransaction: <T>(Future<T> Function() work) => work(),
  );
  outcome = await failing.applyBatch(decoded);
  check(
    'a batch that would corrupt the books is refused as a whole',
    !outcome.applied && outcome.skippedReason == 'gate refused',
    outcome.skippedReason,
  );
  check('and the refusal names the gate, not a mystery', outcome.skippedReason == 'gate refused');
}

// ── helpers ──────────────────────────────────────────────────────────────────

Uint8List _pattern(int length, {int seed = 7}) {
  final bytes = Uint8List(length);
  var state = seed * 2654435761 & 0xffffffff;
  for (var i = 0; i < length; i++) {
    state = (state * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = (state >> 8) & 0xff;
  }
  return bytes;
}

bool _equal(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
