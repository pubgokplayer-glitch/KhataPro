/// Analyzer stub for `package:go_router` (18.0.2).
///
/// Signatures only, transcribed from the pinned version's source. Nothing here runs —
/// see tool/plugin_stubs/README.md. The widget layer navigates with
/// `context.go`/`context.push` and builds its shell from `StatefulShellRoute`-free
/// plain routes, so only those members are declared.
library;

import 'dart:async';

import 'package:flutter/material.dart';

class RouteBase {
  RouteBase({this.parentNavigatorKey, this.redirect, this.metadata, this.routes = const []});

  final GlobalKey<NavigatorState>? parentNavigatorKey;
  final GoRouterRedirect? redirect;
  final Object? metadata;
  final List<RouteBase> routes;
}

class GoRoute extends RouteBase {
  GoRoute({
    required this.path,
    this.name,
    this.builder,
    this.pageBuilder,
    super.parentNavigatorKey,
    super.redirect,
    super.metadata,
    super.routes,
    this.caseSensitive = true,
  }) : assert(path.isNotEmpty, 'GoRoute path cannot be empty');

  final String path;
  final String? name;
  final GoRouterWidgetBuilder? builder;
  final GoRouterPageBuilder? pageBuilder;
  final bool caseSensitive;
}

typedef GoRouterWidgetBuilder = Widget Function(BuildContext context, GoRouterState state);
typedef GoRouterPageBuilder = Object? Function(BuildContext context, GoRouterState state);
typedef GoRouterRedirect = FutureOr<String?> Function(BuildContext context, GoRouterState state);
typedef GoExceptionHandler = void Function(BuildContext context, GoRouterState state, GoRouter router);

class GoRouter {
  GoRouter({
    required List<RouteBase> routes,
    this.redirect,
    this.errorBuilder,
    this.errorPageBuilder,
    this.observers,
    this.initialLocation,
    this.overridePlatformDefaultLocation = false,
    this.navigatorKey,
    this.debugLogDiagnostics = false,
    this.restorationScopeId,
    this.refreshListenable,
    this.redirectLimit = 5,
  });

  factory GoRouter.of(BuildContext context) => throw UnimplementedError('stub');

  final GoRouterRedirect? redirect;
  final GoRouterWidgetBuilder? errorBuilder;
  final GoRouterPageBuilder? errorPageBuilder;
  final List<Object>? observers;
  final String? initialLocation;
  final bool overridePlatformDefaultLocation;
  final GlobalKey<NavigatorState>? navigatorKey;
  final bool debugLogDiagnostics;
  final String? restorationScopeId;
  final Object? refreshListenable;
  final int redirectLimit;

  void go(String location, {Object? extra}) {}

  /// Disposes the router and its navigator. Called from the root widget's `dispose`.
  void dispose() {}
  Future<T?> push<T extends Object?>(String location, {Object? extra}) => Future<T?>.value();
  void pushReplacement(String location, {Object? extra}) {}
  void replace(String location, {Object? extra}) {}
  void pop<T extends Object?>([T? result]) {}
  bool canPop() => false;
  String namedLocation(String name, {Map<String, String> pathParameters = const {},
    Map<String, dynamic> queryParameters = const {}}) => '';
  void goNamed(String name, {Map<String, String> pathParameters = const {},
    Map<String, dynamic> queryParameters = const {}, Object? extra}) {}
}

/// The route a widget is building under: `pathParameters`, `uri` and `extra` are the
/// three the app reads.
class GoRouterState {
  const GoRouterState({
    required this.uri,
    this.matchedLocation = '',
    this.name,
    this.path,
    this.fullPath,
    this.pathParameters = const {},
    this.extra,
    this.error,
  });

  final Uri uri;
  final String matchedLocation;
  final String? name;
  final String? path;
  final String? fullPath;
  final Map<String, String> pathParameters;
  final Object? extra;
  final Object? error;
}

extension GoRouterHelper on BuildContext {
  void go(String location, {Object? extra}) {}

  /// Disposes the router and its navigator. Called from the root widget's `dispose`.
  void dispose() {}
  Future<T?> push<T extends Object?>(String location, {Object? extra}) => Future<T?>.value();
  void pushReplacement(String location, {Object? extra}) {}
  bool canPop() => false;
  void pop<T extends Object?>([T? result]) {}
}
