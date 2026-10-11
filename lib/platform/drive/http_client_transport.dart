/// KhataPro · the production `HttpTransport`, over `package:http`.
///
/// The only place in the Drive adapter that imports a networking package. Twelve
/// lines, no decisions — which is why the resumable-upload logic above it can be
/// tested against a fake that drops connections, something no real HTTP client will
/// do on request.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../sync/backup/http_transport.dart';

final class HttpClientTransport implements HttpTransport {
  HttpClientTransport([http.Client? client]) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<HttpResponseData> send(HttpRequestSpec request) async {
    try {
      final response = await _client.send(
        http.Request(request.method, Uri.parse(request.url))
          ..headers.addAll(request.headers)
          ..bodyBytes = request.byteBody ?? _encodeJson(request.jsonBody),
      );
      final bytes = await response.stream.toBytes();
      return HttpResponseData(
        statusCode: response.statusCode,
        // Header names are lower-cased for consistency, because Google's own
        // responses mix cases (`Location` on the session URI, `range` on a 308).
        headers: {
          for (final entry in response.headers.entries) entry.key.toLowerCase(): entry.value,
        },
        bodyBytes: bytes,
      );
    } on http.ClientException catch (error) {
      // A socket that closed mid-upload is the normal case on a phone, not an
      // exceptional one; the uploader retries it with backoff.
      throw HttpTransportException(error.message);
    }
  }

  static Uint8List _encodeJson(String? json) =>
      json == null ? Uint8List(0) : Uint8List.fromList(json.codeUnits);
}
