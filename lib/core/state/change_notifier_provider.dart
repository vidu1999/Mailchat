import 'package:flutter/material.dart';

/// Minimal reactive provider layer.
///
/// MailChat keeps its core free of external packages so the project builds and
/// tests in restricted environments. This small provider replicates the
/// essentials of ChangeNotifierProvider + scoped providers:
///
///   - [ChangeNotifierProvider] exposes a [ChangeNotifier] to its subtree via
///     [ChangeNotifierProvider.of].
///   - [ListenableBuilder] rebuilds when the listened [Listenable] changes.
///   - [ProviderScope]/[ProviderContainer] style scoped access is achieved by
///     nesting providers; lookups walk up the widget tree.
///
/// Usage:
///   final auth = context.read<AuthNotifier>();
///   context.watch<AuthNotifier>()          // rebuilds on notifyListeners
///   ChangeNotifierProvider(create: () => AuthNotifier(), child: ...)
extension BuildContextProviderExtension on BuildContext {
  T read<T extends ChangeNotifier>() {
    final provider = _ProviderScope.maybeOf(this);
    if (provider == null) {
      throw StateError('No ChangeNotifierProvider<$T> ancestor found.');
    }
    return provider.read<T>() as T;
  }

  T watch<T extends ChangeNotifier>() {
    final provider = _ProviderScope.of(this);
    return provider.watch<T>() as T;
  }
}

/// Holds a map of type -> ChangeNotifier and rebuilds dependents on change.
class _ProviderScope extends InheritedWidget {
  final Map<Type, ChangeNotifier> _services;
  final Map<Type, void Function()> _dispose;

  const _ProviderScope({
    required super.child,
    Map<Type, ChangeNotifier>? services,
    Map<Type, void Function()>? dispose,
  })  : _services = services ?? const {},
        _dispose = dispose ?? const {},
        super(key: ObjectKey(_services));

  static _ProviderScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ProviderScope>();

  static _ProviderScope of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null) {
      throw StateError('No _ProviderScope ancestor found.');
    }
    return scope;
  }

  T read<T extends ChangeNotifier>() {
    final service = _services[T];
    if (service == null) {
      throw StateError('No provider registered for $T.');
    }
    return service as T;
  }

  T watch<T extends ChangeNotifier>() {
    read<T>();
    return read<T>();
  }

  @override
  bool updateShouldNotify(_ProviderScope oldWidget) =>
      _services.length != oldWidget._services.length;
}

/// Provides a [ChangeNotifier] to descendants.
class ChangeNotifierProvider<T extends ChangeNotifier> extends StatefulWidget {
  final T Function(BuildContext context) create;
  final Widget child;
  final bool lazy;

  const ChangeNotifierProvider({
    super.key,
    required this.create,
    required this.child,
    this.lazy = false,
  });

  @override
  State<ChangeNotifierProvider<T>> createState() => _ChangeNotifierProviderState<T>();

  /// Convenience lookup when the provider is an ancestor of [context].
  static T of<T extends ChangeNotifier>(BuildContext context) {
    final scope = _ProviderScope.maybeOf(context);
    if (scope == null) {
      throw StateError('No ChangeNotifierProvider<$T> ancestor.');
    }
    return scope.read<T>() as T;
  }
}

class _ChangeNotifierProviderState<T extends ChangeNotifier>
    extends State<ChangeNotifierProvider<T>> {
  T? _service;

  T get _value {
    if (!_widget.lazy && _service == null) {
      _service = widget.create(context);
    }
    return _service!;
  }

  ChangeNotifierProvider<T> get _widget => super.widget as ChangeNotifierProvider<T>;

  @override
  void initState() {
    super.initState();
    if (!widget.lazy) {
      _service = widget.create(context);
    }
  }

  @override
  void didUpdateWidget(covariant ChangeNotifierProvider<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Recreate only if the create function identity changed.
    if (oldWidget.create != widget.create) {
      _service?.dispose();
      _service = widget.create(context);
    }
  }

  @override
  void dispose() {
    _service?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_service == null && widget.lazy) {
      return widget.child;
    }
    return _ProviderScope(
      services: {T: _value},
      child: widget.child,
    );
  }
}

/// Rebuilds [builder] whenever [listenable] notifies its listeners.
class ListenableBuilder extends StatefulWidget {
  final Widget Function(BuildContext context, Widget? child) builder;
  final Listenable listenable;
  final Widget? child;

  const ListenableBuilder({
    super.key,
    required this.builder,
    required this.listenable,
    this.child,
  });

  @override
  State<ListenableBuilder> createState() => _ListenableBuilderState();
}

class _ListenableBuilderState extends State<ListenableBuilder> {
  void _onChange() => setState(() {});

  @override
  void initState() {
    super.initState();
    widget.listenable.addListener(_onChange);
  }

  @override
  void didUpdateWidget(covariant ListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      oldWidget.listenable.removeListener(_onChange);
      widget.listenable.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.listenable.removeListener(_onChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      widget.builder(context, widget.child);
}
