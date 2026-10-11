/// Analyzer stub for `package:nsd` 5.0.1 (+ `nsd_platform_interface` 2.2.0).
///
/// Transcribed from the package's real source: `nsd` re-exports these types from
/// `nsd_platform_interface`, and the TXT-record type is the one that matters —
/// `Map<String, Uint8List?>`, bytes, not strings.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// The public functions of `nsd` 5.0.1, verbatim in shape.
Future<Discovery> startDiscovery(
  String serviceType, {
  bool autoResolve = true,
  IpLookupType ipLookupType = IpLookupType.none,
}) =>
    throw UnimplementedError('stub');

Future<void> stopDiscovery(Discovery discovery) => throw UnimplementedError('stub');

Future<Service> resolve(Service service) => throw UnimplementedError('stub');

Future<Registration> register(Service service) => throw UnimplementedError('stub');

Future<void> unregister(Registration registration) => throw UnimplementedError('stub');

void enableLogging(LogTopic logTopic) => throw UnimplementedError('stub');

void disableServiceTypeValidation(bool value) => throw UnimplementedError('stub');

class Service {
  const Service({this.name, this.type, this.host, this.port, this.txt, this.addresses});

  final String? name;
  final String? type;
  final String? host;
  final int? port;
  final List<InternetAddress>? addresses;
  final Map<String, Uint8List?>? txt;
}

class Discovery extends _ChangeNotifier {
  Discovery(this.id);

  final String id;
  final String serviceType = '';
  final ServiceStatus status = ServiceStatus.found;

  List<Service> get services => throw UnimplementedError('stub');

  void addServiceListener(ServiceListener serviceListener) =>
      throw UnimplementedError('stub');

  void removeServiceListener(ServiceListener serviceListener) =>
      throw UnimplementedError('stub');
}

class Registration {
  Registration(this.id, this.service);

  final String id;
  final Service service;
}

class NsdError extends Error {
  NsdError(this.cause, this.message);

  final ErrorCause cause;
  final String message;
}

enum ErrorCause { illegalArgument, maxLimit, alreadyActive, internalError, operationNotSupported, securityIssue }

enum ServiceStatus { found, lost }

enum LogTopic { calls, errors }

enum IpLookupType { none, v4, v6, any }

typedef ServiceListener = FutureOr<void> Function(Service service, ServiceStatus status);

/// `Discovery` is declared `with ChangeNotifier` in the real package, so these two
/// members exist on it. Only the names this project calls are stubbed.
class _ChangeNotifier {
  void addListener(void Function() listener) => throw UnimplementedError('stub');
  void removeListener(void Function() listener) => throw UnimplementedError('stub');
  void notifyListeners() => throw UnimplementedError('stub');
  void dispose() => throw UnimplementedError('stub');
}
