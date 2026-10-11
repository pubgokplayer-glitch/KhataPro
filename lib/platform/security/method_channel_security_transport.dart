/// KhataPro · the one file in the security stack that imports Flutter.
///
/// It contains no decisions: it forwards a call, and turns a `PlatformException`
/// into a typed failure. Everything policy-shaped lives in
/// `security_policy.dart`, which is pure Dart and therefore testable without a
/// device or a Flutter binding.
library;

import 'package:flutter/services.dart';

import 'security_transport.dart';

/// The real transport: one `MethodChannel` per platform, JSON-shaped arguments.
final class MethodChannelSecurityTransport implements SecurityTransport {
  MethodChannelSecurityTransport([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(channelName);

  /// Matches the channel names registered by `SecurityChannel.kt` and
  /// `SecurityChannel.swift`.
  static const String channelName = 'khata_pro/security';

  final MethodChannel _channel;

  @override
  Future<Map<String, Object?>> invoke(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      final result = await _channel.invokeMethod<Object?>(method, args);
      if (result == null) return const <String, Object?>{};
      if (result is Map) {
        return result.map((key, value) => MapEntry('$key', value));
      }
      throw SecurityChannelException(
        SecurityErrorCodes.unimplemented,
        'platform returned ${result.runtimeType} for "$method"; expected a map',
      );
    } on PlatformException catch (error) {
      // An unknown code still surfaces as a typed failure rather than a silent
      // success: a platform build newer than this Dart code must never be able to
      // turn a refusal into an empty result.
      throw SecurityChannelException(error.code, error.message ?? 'no message');
    } on MissingPluginException catch (error) {
      // No handler attached. On a unit-test host and on desktop builds that is
      // expected; the policy reads this as "no hardware here" and steps down the
      // ladder instead of crashing.
      throw SecurityChannelException(
        SecurityErrorCodes.unimplemented,
        'no platform handler for $method (${error.message ?? 'not attached'})',
      );
    }
  }
}
