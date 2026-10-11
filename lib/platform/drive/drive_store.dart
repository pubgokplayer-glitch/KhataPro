/// KhataPro · Google Drive as a bring-your-own-cloud backup target.
///
/// ## The scope decision, and why it is worth a paragraph
///
/// This app requests **`drive.file`** and nothing else. Under that scope Google
/// grants access to files the app itself created — not "your Drive", not your
/// photos, not your documents. Three consequences, all of them the point:
///
///  * the consent screen says *"See, edit, create and delete only the specific
///    Google Drive files you use with this app"* — a sentence a shopkeeper can read
///    and agree with;
///  * a stolen OAuth token cannot read anything but backups this app wrote;
///  * no Google verification review is needed, because nothing sensitive is
///    requested — which is why a zero-cost app can ship this at all.
///
/// Backups go into the app's private `appDataFolder`: invisible in the user's Drive
/// UI, cannot be accidentally deleted or renamed, still counts against their quota
/// and is still theirs.
///
/// ## Resumable uploads
///
/// Drive's resumable protocol is what makes a 52 MB pack survive a dropped
/// connection: the session URI it returns is the resume token, and a `PUT` with
/// `Content-Range` that stops mid-way is answered with `308` plus the range it
/// actually holds. [DriveBlobStore] passes that range back verbatim, so the uploader
/// above it never has to guess.
///
/// ## What this file is not
///
/// It does not sign anyone in. `google_sign_in` does that, and the token is passed
/// in as an `AuthClient`; see `docs/PLATFORM_SETUP.md` for the OAuth client IDs a
/// release build needs (a free Google Cloud project, no billing).
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import '../../sync/backup/http_transport.dart';
import '../../sync/backup/resumable_transfer.dart';

/// The minimum an HTTP call needs: a token, and the ability to make requests. Kept
/// as an interface so the tests drive the real logic with a fake transport instead
/// of with a mocked network stack.
abstract interface class AuthHeaderProvider {
  Future<Map<String, String>> headers();
}

/// Wraps any `googleapis_auth` client (or, in tests, a Map).
final class StaticAuthHeaders implements AuthHeaderProvider {
  StaticAuthHeaders(this.token, {this.expiresAtMs});

  final String token;
  final int? expiresAtMs;

  @override
  Future<Map<String, String>> headers() async => {
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      };
}

/// Google Drive v3 over plain REST.
///
/// `googleapis` is a dependency for the generated bindings, but the four endpoints
/// this app needs are small enough to call directly — which keeps the resumable
/// upload protocol visible, where it can be reasoned about, instead of buried under
/// a generated layer that hides `308` responses behind an exception.
final class DriveBlobStore implements BlobStore {
  DriveBlobStore({
    required this.auth,
    required HttpTransport transport,
    this.folder = DriveFolder.appData,
    this.apiBase = 'https://www.googleapis.com',
    this.uploadBase = 'https://www.googleapis.com',
    this.appName = 'KhataPro',
  }) : _transport = transport;

  final AuthHeaderProvider auth;
  final HttpTransport _transport;

  /// `appDataFolder` (invisible, safest) or a normal folder the user can find. Both
  /// are supported because a user who wants to *see* their backups in Drive is
  /// making a reasonable request; the setting is theirs.
  final DriveFolder folder;

  final String apiBase;
  final String uploadBase;
  final String appName;

  /// `upload/…` sessions live on a different host path but the same origin.
  Uri _files({Map<String, String>? query}) =>
      Uri.parse('$apiBase/drive/v3/files').replace(queryParameters: query);

  /// Sends a request and turns a transport-level failure into a retryable one.
  /// HTTP status codes are returned untouched: the caller classifies them, because
  /// only the caller knows whether a 403 means "signed out" or "Drive is full".
  Future<HttpResponseData> _send(HttpRequestSpec spec) async {
    try {
      return await _transport.send(spec);
    } on HttpTransportException catch (error) {
      throw TransferFailure(
        kind: TransferFailureKind.transient,
        message: error.message,
      );
    }
  }

  Future<HttpResponseData> _must(HttpRequestSpec spec) async {
    final response = await _send(spec);
    if (!response.isSuccess && !response.isIncomplete) {
      throw TransferFailure.fromHttp(response.statusCode, response.body);
    }
    return response;
  }

  @override
  Future<int?> availableBytes() async {
    // About.get gives the quota, but calls to it are rate-limited and it is not on
    // the resumable path. A failure here must never block a backup, so it is
    // reported honestly as "unknown".
    try {
      final response = await _must(HttpRequestSpec(
        method: 'GET',
        url: Uri.parse('$apiBase/drive/v3/about').replace(
          queryParameters: {'fields': 'storageQuota(limit,usage)'},
        ).toString(),
        headers: await auth.headers(),
      ));
      final quota = ((jsonDecode(response.body) as Map)['storageQuota'] as Map?)
          ?.cast<String, Object?>();
      final limit = int.tryParse('${quota?['limit'] ?? ''}');
      final usage = int.tryParse('${quota?['usage'] ?? ''}');
      if (limit == null || usage == null) return null; // unlimited or unstated
      return math.max(0, limit - usage);
    } on TransferFailure {
      return null;
    }
  }

  @override
  Future<List<RemoteBlob>> list({String prefix = ''}) async {
    final parent = folder == DriveFolder.appData ? 'appDataFolder' : folder.folderId;
    final response = await _must(HttpRequestSpec(
      method: 'GET',
      url: _files(
        query: {
          'q': "'$parent' in parents and trashed = false",
          'fields': 'files(id,name,size,modifiedTime,md5Checksum,appProperties)',
          'pageSize': '1000',
        },
      ).toString(),
      headers: await auth.headers(),
    ));
    final files = ((jsonDecode(response.body) as Map)['files'] as List?) ?? const [];
    final blobs = <RemoteBlob>[];
    for (final file in files) {
      final map = (file as Map).cast<String, Object?>();
      final name = '${map['name']}';
      if (prefix.isNotEmpty && !name.startsWith(prefix)) continue;
      blobs.add(
        RemoteBlob(
          name: name,
          bytes: int.tryParse('${map['size'] ?? '0'}') ?? 0,
          modifiedAtMs: DateTime.tryParse('${map['modifiedTime']}')?.millisecondsSinceEpoch ?? 0,
          checksum: map['md5Checksum'] as String?,
        ),
      );
    }
    blobs.sort((a, b) => b.modifiedAtMs.compareTo(a.modifiedAtMs));
    return blobs;
  }

  @override
  Future<UploadSession> beginUpload(
    String name, {
    required int totalBytes,
    String? resumeToken,
  }) async {
    // An existing session is resumable: ask Drive how much it already holds rather
    // than trusting our own journal. `PUT` with an empty body and
    // `Content-Range: bytes */TOTAL` is the documented probe.
    if (resumeToken != null && resumeToken.isNotEmpty) {
      final probe = await _send(await _putSpec(resumeToken, const [], offset: 0, total: totalBytes));
      final committed = _committedFromRange(probe.headers['range']);
      if (probe.statusCode == 308 || probe.statusCode == 200 || probe.statusCode == 201) {
        return UploadSession(
          name: name,
          totalBytes: totalBytes,
          resumeToken: resumeToken,
          committedBytes: probe.statusCode == 200 || probe.statusCode == 201
              ? totalBytes
              : committed,
        );
      }
      // A 404/410 means the session expired; fall through and start a new one.
    }

    final response = await _must(HttpRequestSpec(
      method: 'POST',
      url: Uri.parse('$uploadBase/upload/drive/v3/files').replace(
        queryParameters: {'uploadType': 'resumable', 'fields': 'id,name,size,md5Checksum'},
      ).toString(),
      headers: {
        ...await auth.headers(),
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Type': 'application/octet-stream',
        'X-Upload-Content-Length': '$totalBytes',
      },
      jsonBody: jsonEncode({
        'name': name,
        if (folder == DriveFolder.appData) 'parents': ['appDataFolder'],
        if (folder != DriveFolder.appData) 'parents': [folder.folderId],
        'appProperties': {'app': appName, 'bytes': '$totalBytes'},
      }),
    ));
    final sessionUri = response.headers['location'];
    if (sessionUri == null || sessionUri.isEmpty) {
      throw const TransferFailure(
        kind: TransferFailureKind.permanent,
        message: 'Drive did not return a resumable session URI',
      );
    }
    return UploadSession(
      name: name,
      totalBytes: totalBytes,
      resumeToken: sessionUri,
      committedBytes: 0,
    );
  }

  @override
  Future<int> uploadChunk(UploadSession session, int offset, Uint8List bytes) async {
    final response = await _send(
      await _putSpec(session.resumeToken, bytes, offset: offset, total: session.totalBytes),
    );
    switch (response.statusCode) {
      case 308:
        // Incomplete: Drive tells us exactly how far it got.
        return _committedFromRange(response.headers['range']);
      case 200:
      case 201:
        return session.totalBytes;
      default:
        throw TransferFailure.fromHttp(response.statusCode, response.body);
    }
  }

  @override
  Future<RemoteBlob> completeUpload(UploadSession session) async {
    // Drive finalises on the request that carries the last byte; the probe here is
    // what makes `completeUpload` idempotent when the last response was lost.
    final files = await list(prefix: '');
    final match = files.where((file) => file.name == session.name).firstOrNull;
    if (match == null) {
      throw const TransferFailure(
        kind: TransferFailureKind.transient,
        message: 'the upload finished but the file is not listed yet',
      );
    }
    return match;
  }

  @override
  Future<Uint8List> download(String name, {int offset = 0, int? length}) async {
    final id = await _fileIdFor(name);
    final response = await _must(HttpRequestSpec(
      method: 'GET',
      url: Uri.parse('$apiBase/drive/v3/files/$id').replace(
        queryParameters: {'alt': 'media'},
      ).toString(),
      headers: {
        ...await auth.headers(),
        // A Range request is what makes a 400 MB restore survivable on a phone: the
        // downloader above asks for the bytes it is missing, so a dropped connection
        // costs one range rather than the whole file.
        if (length != null) 'Range': 'bytes=$offset-${offset + length - 1}',
      },
    ));
    return Uint8List.fromList(response.bodyBytes);
  }

  @override
  Future<void> delete(String name) async {
    final id = await _fileIdFor(name, required: false);
    // Already gone is a success: a retention pass that runs twice must not fail the
    // second time.
    if (id == null) return;
    await _must(HttpRequestSpec(
      method: 'DELETE',
      url: Uri.parse('$apiBase/drive/v3/files/$id').toString(),
      headers: await auth.headers(),
    ));
  }

  Future<String?> _fileIdFor(String name, {bool required = true}) async {
    final response = await _must(HttpRequestSpec(
      method: 'GET',
      url: _files(
        query: {
          'q': "name = '${name.replaceAll("'", r"\'")}' and trashed = false",
          'fields': 'files(id,name)',
        },
      ).toString(),
      headers: await auth.headers(),
    ));
    final files = ((jsonDecode(response.body) as Map)['files'] as List?) ?? const [];
    if (files.isEmpty) {
      if (!required) return null;
      throw TransferFailure(
        kind: TransferFailureKind.permanent,
        message: 'no backup named $name is stored in this Drive account',
      );
    }
    return '${((files.first as Map)['id'])}';
  }

  Future<HttpRequestSpec> _putSpec(
    String url,
    List<int> body, {
    required int offset,
    required int total,
  }) async {
    final end = offset + body.length;
    return HttpRequestSpec(
      method: 'PUT',
      url: url,
      headers: {
        ...await auth.headers(),
        'Content-Type': 'application/octet-stream',
        'Content-Length': '${body.length}',
        // `bytes */TOTAL` with an empty body is the documented way to ask "how much
        // do you already hold?", which is how a resume finds its offset.
        'Content-Range': body.isEmpty ? 'bytes */$total' : 'bytes $offset-${end - 1}/$total',
      },
      byteBody: body.isEmpty ? null : Uint8List.fromList(body),
    );
  }

  /// `Range: bytes=0-1048575` → 1048576. Absent range means nothing is committed.
  int _committedFromRange(String? range) {
    if (range == null || !range.contains('-')) return 0;
    final end = int.tryParse(range.split('-').last);
    return end == null ? 0 : end + 1;
  }
}


extension<T> on Iterable<T> {
  /// `firstOrNull` without pulling in `package:collection` for one method.
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}

/// Where backups live. Both are supported; the default is the invisible one.
enum DriveFolder {
  /// Private to the app, cannot be deleted by accident. **The default.**
  appData,

  /// A visible folder the user can find, copy and print. Requires the id, which
  /// the setup screen obtains once and stores in `app_settings`.
  visible('');

  const DriveFolder([this.folderId = '']);

  final String folderId;
}
