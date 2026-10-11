/// KhataPro · the HTTP seam under the cloud adapters.
///
/// Google Drive's resumable-upload protocol is the part of BYOC sync most likely
/// to break in the field, and it is exactly the part that is impossible to test
/// against the real service (a dropped connection at 87 % is not something you can
/// ask Google for on demand). So the requests are described by a small value type
/// and executed by an injected transport: production uses `package:http`, the
/// verification harness uses a fake that drops connections, returns `308` with a
/// partial range, answers `403 storageQuotaExceeded`, and pretends to be slow.
///
/// This file has no third-party import — that is the whole reason it exists.
library;

import 'dart:typed_data';

/// One request, described completely enough to be logged and replayed.
final class HttpRequestSpec {
  const HttpRequestSpec({
    required this.method,
    required this.url,
    this.headers = const <String, String>{},
    this.jsonBody,
    this.byteBody,
  });

  final String method;
  final String url;
  final Map<String, String> headers;

  /// Exactly one of these is set. JSON for control calls, bytes for payload.
  final String? jsonBody;
  final Uint8List? byteBody;

  int get contentLength => byteBody?.length ?? jsonBody?.length ?? 0;
}

/// One response. `bodyBytes` is what matters; `body` decodes it for JSON calls.
final class HttpResponseData {
  const HttpResponseData({
    required this.statusCode,
    this.headers = const <String, String>{},
    this.bodyBytes = const <int>[],
  });

  final int statusCode;
  final Map<String, String> headers;
  final List<int> bodyBytes;

  String get body => String.fromCharCodes(bodyBytes);

  bool get isSuccess => statusCode >= 200 && statusCode < 300;

  /// Drive answers an incomplete resumable upload with `308 Resume Incomplete`,
  /// which is not an error: it carries the range the server actually holds.
  bool get isIncomplete => statusCode == 308;
}

/// The transport. Implementations must not throw for HTTP status codes — a 4xx is
/// a response, not an exception, and the caller needs to classify it.
abstract interface class HttpTransport {
  Future<HttpResponseData> send(HttpRequestSpec request);
}

/// A client-side failure (socket closed, DNS, timeout) as opposed to a server
/// response. The adapters turn this into a retryable `TransferFailure`.
final class HttpTransportException implements Exception {
  const HttpTransportException(this.message);

  final String message;

  @override
  String toString() => 'HttpTransportException: $message';
}
