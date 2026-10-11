/// Analyzer stub for `package:flutter/services.dart`.
///
/// Signatures only, transcribed from the Flutter 3.47 SDK's `services` library for
/// the members this project uses. Nothing here is ever executed — it exists so
/// `dart analyze` can type-check the two files that talk to a platform channel in a
/// sandbox that has no Flutter SDK. See tool/plugin_stubs/README.md.
library;

class MethodChannel {
  const MethodChannel(this.name, [this.codec = const StandardMethodCodec()]);

  final String name;
  final MethodCodec codec;

  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) =>
      throw UnimplementedError('stub');

  void setMethodCallHandler(Future<dynamic> Function(MethodCall call)? handler) =>
      throw UnimplementedError('stub');
}

class MethodCall {
  const MethodCall(this.method, [this.arguments]);

  final String method;
  final dynamic arguments;
}

abstract class MethodCodec {
  const MethodCodec();
}

class StandardMethodCodec implements MethodCodec {
  const StandardMethodCodec([this.messageCodec = const StandardMessageCodec()]);

  final MessageCodec<dynamic> messageCodec;
}

abstract class MessageCodec<T> {
  const MessageCodec();
}

class StandardMessageCodec implements MessageCodec<dynamic> {
  const StandardMessageCodec();
}

class PlatformException implements Exception {
  PlatformException({
    required this.code,
    this.message,
    this.details,
    this.stacktrace,
  });

  final String code;
  final String? message;
  final Object? details;
  final String? stacktrace;

  @override
  String toString() => 'PlatformException($code, $message, $details)';
}

class MissingPluginException implements Exception {
  MissingPluginException([this.message]);

  final String? message;

  @override
  String toString() => 'MissingPluginException($message)';
}

// ── assets ───────────────────────────────────────────────────────────────────
// Verified against Flutter 3.47: `rootBundle` is a top-level *final* (not const)
// `AssetBundle`, and `AssetManifest` has no public constructor — the only way to build
// one is `loadFromAssetBundle`. `listAssets()` returns asset *keys*.

abstract class AssetBundle {
  const AssetBundle();

  Future<String> loadString(String key, {bool cache = true}) =>
      throw UnimplementedError('stub');
}

final AssetBundle rootBundle = _StubAssetBundle();

class _StubAssetBundle extends AssetBundle {
  const _StubAssetBundle();
}

class AssetManifest {
  const AssetManifest._(this._assets);

  static Future<AssetManifest> loadFromAssetBundle(AssetBundle bundle) =>
      throw UnimplementedError('stub');

  final List<String> _assets;

  List<String> listAssets() => _assets;
}
