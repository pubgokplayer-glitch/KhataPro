/// KhataPro · the transport under the platform security bindings.
///
/// The Keystore/Secure-Enclave work happens in Kotlin and Swift, but *nothing in
/// that code decides anything*: it stores a key, wraps bytes, unwraps bytes and
/// reports what the hardware can do. Every decision — which custody level, which
/// alias, whether a biometric prompt is required, what happens on failure — lives
/// in Dart, behind this interface. That is what makes the security policy
/// testable: the harness swaps in a fake Keystore that behaves like the real one
/// (opaque handles, refusals, invalidation) and the policy is exercised without a
/// phone.
///
/// This file is deliberately free of any Flutter import: the contract, the error
/// codes and the custody policy built on them compile — and are tested — with bare
/// Dart. The one file that does touch `MethodChannel` is
/// `method_channel_security_transport.dart`, and it contains no decisions.
///
/// The channel is deliberately **one-way about key material**: there is no method
/// that returns a raw key. `wrap` and `unwrap` are the only operations, so a
/// compromised Dart context cannot ask for the DEK's protection key — it can only
/// ask the hardware to use it. See `CustodyRules.neverExportable`.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Method names, in one place: a typo here would otherwise be a runtime failure
/// on a device, which is the most expensive place to find one.
abstract final class SecurityMethods {
  /// What can this device actually do? Never cached across installs: StrongBox
  /// availability and biometric enrolment change under the app's feet.
  static const String capabilities = 'capabilities';

  /// Create the key for [alias] if it is absent, and report its fingerprint.
  /// Idempotent — calling it twice must not rotate a key the database is using.
  static const String ensureKey = 'ensureKey';

  /// Wrap plaintext (the DEK) under the key for [alias].
  static const String wrap = 'wrap';

  /// Unwrap, throwing `user_not_authenticated` when the key requires a prompt.
  static const String unwrap = 'unwrap';

  /// Is there a key for [alias]? (Cheap, no prompt: used at boot to choose the
  /// custody ladder before decrypting anything.)
  static const String hasKey = 'hasKey';

  /// Irreversibly destroy the key for [alias]. Used by "wipe" — after this the
  /// wrapped DEK is noise, which is the point.
  static const String delete = 'delete';

  /// Ask the platform to authenticate the user *now*, so a subsequent
  /// biometric-bound `unwrap` can succeed. Returns a token the caller may reuse
  /// for one operation.
  static const String authorize = 'authorize';
}

/// Error codes the platform side may throw. Kept as a closed set so the Dart
/// policy can react to each one deliberately instead of pattern-matching strings.
abstract final class SecurityErrorCodes {
  /// The key requires a fresh biometric/passcode check.
  static const String userNotAuthenticated = 'user_not_authenticated';

  /// The key was invalidated — on Android by enrolling a new fingerprint, on iOS
  /// by changing the passcode. Unrecoverable by design: the data protected by it
  /// is gone unless a backup exists.
  static const String keyInvalidated = 'key_invalidated';

  /// No such alias: the key was deleted, or never created.
  static const String keyMissing = 'key_missing';

  /// The device has not been unlocked since boot, so a
  /// `kSecAttrAccessibleAfterFirstUnlock` key is not readable yet.
  static const String deviceLocked = 'device_locked';

  /// No hardware keystore on this device (rare; usually an old or emulated one).
  static const String hardwareUnavailable = 'hardware_unavailable';

  /// The method named is not implemented by this platform build.
  static const String unimplemented = 'unimplemented';

  static const Set<String> all = {
    userNotAuthenticated,
    keyInvalidated,
    keyMissing,
    deviceLocked,
    hardwareUnavailable,
    unimplemented,
  };
}

/// A failure that came from the platform side, carrying its code.
final class SecurityChannelException implements Exception {
  SecurityChannelException(this.code, this.message);

  final String code;
  final String message;

  bool get isLockedOrPrompt =>
      code == SecurityErrorCodes.userNotAuthenticated ||
      code == SecurityErrorCodes.deviceLocked;

  /// Invalidation is not a bug and not retryable: the key is gone.
  bool get isPermanent =>
      code == SecurityErrorCodes.keyInvalidated ||
      code == SecurityErrorCodes.unimplemented;

  @override
  String toString() => 'SecurityChannelException($code): $message';
}

/// The seam. Two implementations: the real method channel, and the harness's
/// fake device.
abstract interface class SecurityTransport {
  /// Invokes [method] and returns its result map. Throws
  /// [SecurityChannelException] for any platform error, including codes this
  /// Dart version does not know yet (forward compatibility: an unknown code
  /// still surfaces as a typed failure, never as a silent success).
  Future<Map<String, Object?>> invoke(String method, [Map<String, Object?>? args]);
}

/// Byte helpers shared by every implementation, because base64 is the only
/// binary-safe primitive the standard message codec guarantees on both
/// platforms without extra codec registration.
abstract final class SecurityBytes {
  static String toBase64(Uint8List bytes) => base64Encode(bytes);

  static Uint8List fromBase64(Object? value) {
    if (value is! String) {
      throw SecurityChannelException(
        SecurityErrorCodes.unimplemented,
        'expected a base64 string, got ${value.runtimeType}',
      );
    }
    // An empty string is a legitimate value, not a malformed one: the iOS
    // Secure Enclave wraps with ECIES, whose output carries its own nonce, so the
    // `iv` field is empty by design. Rejecting it here would have broken every
    // unwrap on iOS — which is what this check caught.
    if (value.isEmpty) return Uint8List(0);
    try {
      return base64Decode(value);
    } on FormatException catch (error) {
      throw SecurityChannelException(
        SecurityErrorCodes.unimplemented,
        'malformed base64 from platform: ${error.message}',
      );
    }
  }
}
