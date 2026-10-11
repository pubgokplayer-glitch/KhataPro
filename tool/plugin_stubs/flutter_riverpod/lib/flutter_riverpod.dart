/// Analyzer stub for `package:flutter_riverpod` (3.4.3).
///
/// The Flutter half is declared here; the **whole Dart half is re-exported from the real
/// `package:riverpod`** that the harness already resolves (3.4.3, the same version
/// `flutter_riverpod` depends on). That is deliberate: `AsyncValue`, the provider
/// constructors, `Ref` and the `select` extension are not transcribed by hand — they are
/// the real declarations. Only the widget-facing classes are stubs, and their signatures
/// are transcribed from `flutter_riverpod-3.4.3/lib/src/core/{consumer,provider_scope,widget_ref}.dart`.
///
/// Nothing here runs; see tool/plugin_stubs/README.md.
library;

import 'package:flutter/material.dart';
import 'package:riverpod/riverpod.dart';
import 'package:riverpod/misc.dart';

export 'package:riverpod/riverpod.dart';
export 'package:riverpod/misc.dart'
    show
        ProviderListenable,
        ProviderListenableOrFamily,
        ProviderBase,
        ProviderOrFamily,
        Override,
        Family,
        Refreshable,
        ProviderException,
        KeepAliveLink;

typedef ConsumerBuilder = Widget Function(BuildContext context, WidgetRef ref, Widget? child);

/// `WidgetRef` is a **sealed** class in 3.4.3: the framework supplies the only
/// implementations, so a widget cannot fake one. Members listed here are exactly the
/// public ones (`lib/src/core/widget_ref.dart`).
abstract class WidgetRef {
  BuildContext get context;
  StateT watch<StateT>(ProviderListenable<StateT> provider);
  void listen<StateT>(
    ProviderListenable<StateT> provider,
    void Function(StateT? previous, StateT next) listener, {
    void Function(Object error, StackTrace stackTrace)? onError,
    bool fireImmediately,
  });
  ProviderSubscription<StateT> listenManual<StateT>(
    ProviderListenable<StateT> provider,
    void Function(StateT? previous, StateT next) listener, {
    void Function(Object error, StackTrace stackTrace)? onError,
    bool fireImmediately,
    bool weak,
  });
  StateT read<StateT>(ProviderListenable<StateT> provider);
  StateT refresh<StateT>(Refreshable<StateT> provider);
  bool exists(ProviderBase<Object?> provider);
  void invalidate(ProviderOrFamily provider, {bool asReload});
}

abstract class ConsumerStatefulWidget extends StatefulWidget {
  const ConsumerStatefulWidget({super.key});
  @override
  ConsumerState<ConsumerStatefulWidget> createState();
}

abstract class ConsumerWidget extends ConsumerStatefulWidget {
  const ConsumerWidget({super.key});
  Widget build(BuildContext context, WidgetRef ref);
  @override
  ConsumerState<ConsumerWidget> createState() => throw UnimplementedError('stub');
}

abstract class ConsumerState<WidgetT extends ConsumerStatefulWidget> extends State<WidgetT> {
  late final WidgetRef ref;
}

final class Consumer extends ConsumerWidget {
  const Consumer({super.key, required this.builder, this.child});

  final ConsumerBuilder builder;
  final Widget? child;

  @override
  ConsumerState<Consumer> createState() => throw UnimplementedError('stub');

  @override
  Widget build(BuildContext context, WidgetRef ref) => builder(context, ref, child);
}

class ProviderScope extends StatefulWidget {
  /// The container above the nearest `ProviderScope`. Used by widgets that have a
  /// `BuildContext` but no `WidgetRef` (a modal route's builder, for instance).
  static ProviderContainer containerOf(BuildContext context) =>
      throw UnimplementedError('stub');

  const ProviderScope({
    super.key,
    this.overrides = const <Override>[],
    this.observers,
    this.retry,
    required this.child,
  });

  final List<Override> overrides;
  final List<ProviderObserver>? observers;
  final Object? retry;
  final Widget child;

  @override
  State<ProviderScope> createState() => throw UnimplementedError('stub');
}

class UncontrolledProviderScope extends StatefulWidget {
  const UncontrolledProviderScope({
    super.key,
    required this.container,
    required this.child,
  });

  final ProviderContainer container;
  final Widget child;

  @override
  State<UncontrolledProviderScope> createState() => throw UnimplementedError('stub');
}
