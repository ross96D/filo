// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ui' show FlutterView, Rect, Size;

import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';
import 'package:flutter/widgets.dart';

import 'backend.dart';
import 'controllers.dart';
import 'models.dart';
import 'positioner.dart';

/// A [WindowingOwner] implementation backed by a [FiloWindowingBackend].
///
/// Install it with `installFiloWindowing`, or assign it to
/// `WidgetsBinding.instance.windowingOwner` yourself.
///
/// Every controller resolves its `rootView` from `PlatformDispatcher.views`
/// before it is returned. The backend must create that view synchronously.
class FiloWindowingOwner implements WindowingOwner {
  FiloWindowingOwner({
    required this.backend,
    this.viewResolver,
    this.reuseImplicitView = true,
  }) {
    if (!isWindowingEnabled) {
      throw StateError(
        'Windowing is not enabled. Call installFiloWindowing() before '
        'creating a FiloWindowingOwner.',
      );
    }
    WidgetsFlutterBinding.ensureInitialized();
    _subscription = backend.events.listen(_dispatch);
  }

  /// The native bridge.
  final FiloWindowingBackend backend;

  /// Resolves a view id to a Flutter view.
  ///
  /// Defaults to searching `PlatformDispatcher.views`. Tests can inject a
  /// resolver for views that are not registered with the platform dispatcher.
  final FlutterView Function(int viewId)? viewResolver;

  /// Whether the first regular window may adopt the implicit view (id 0).
  final bool reuseImplicitView;

  final Map<int, _ControllerEntry> _controllers = <int, _ControllerEntry>{};
  StreamSubscription<FiloWindowEvent>? _subscription;

  /// Stop listening to backend events.
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }

  /// Resolves [viewId] to a registered [FlutterView].
  ///
  /// Throws a [StateError] if the id is not registered. A synchronous backend
  /// must not return a view id that is not already visible here.
  FlutterView resolveView(int viewId) {
    final resolver = viewResolver;
    if (resolver != null) return resolver(viewId);

    for (final view in WidgetsBinding.instance.platformDispatcher.views) {
      if (view.viewId == viewId) return view;
    }

    final known = WidgetsBinding.instance.platformDispatcher.views
        .map((view) => view.viewId)
        .join(', ');
    throw StateError(
      'The backend returned view id $viewId, but no such FlutterView is '
      'registered with PlatformDispatcher.views (known ids: [$known]). '
      'FiloWindowingBackend.createWindow must create the native view '
      'synchronously.',
    );
  }

  @override
  RegularWindowController createRegularWindowController({
    required RegularWindowControllerDelegate delegate,
    Size? size,
    BoxConstraints? constraints,
    required bool resizable,
    String? title,
  }) {
    _ensureEnabled();
    final handle = backend.createWindow(
      FiloWindowRequest(
        kind: FiloWindowKind.toplevel,
        size: size,
        constraints: constraints,
        resizable: resizable,
        title: title,
        preferredViewId: reuseImplicitView ? 0 : -1,
      ),
    );
    final controller = FiloRegularWindowController(
      backend: backend,
      delegate: delegate,
      handle: handle,
      view: resolveView(handle.viewId),
    );
    _register(
      viewId: handle.viewId,
      controller: controller,
      onCloseRequested: () => delegate.onWindowCloseRequested(controller),
      onDestroyed: delegate.onWindowDestroyed,
    );
    return controller;
  }

  @override
  DialogWindowController createDialogWindowController({
    required DialogWindowControllerDelegate delegate,
    Size? size,
    BoxConstraints? constraints,
    required bool resizable,
    BaseWindowController? parent,
    String? title,
  }) {
    _ensureEnabled();
    final handle = backend.createWindow(
      FiloWindowRequest(
        kind: FiloWindowKind.toplevel,
        size: size,
        constraints: constraints,
        resizable: resizable,
        title: title,
        parentViewId: parent?.rootView.viewId ?? -1,
        modal: parent != null,
      ),
    );
    final controller = FiloDialogWindowController(
      backend: backend,
      delegate: delegate,
      parent: parent,
      handle: handle,
      view: resolveView(handle.viewId),
    );
    _register(
      viewId: handle.viewId,
      controller: controller,
      onCloseRequested: () => delegate.onWindowCloseRequested(controller),
      onDestroyed: delegate.onWindowDestroyed,
    );
    return controller;
  }

  @override
  TooltipWindowController createTooltipWindowController({
    required TooltipWindowControllerDelegate delegate,
    required BoxConstraints constraints,
    required Rect anchorRect,
    required WindowPositioner positioner,
    required BaseWindowController parent,
  }) {
    _ensureEnabled();
    final handle = backend.createWindow(
      FiloWindowRequest(
        kind: FiloWindowKind.popup,
        constraints: constraints,
        resizable: false,
        decorated: false,
        sizedToContent: true,
        parentViewId: parent.rootView.viewId,
        positioner: _toFiloPositioner(positioner, anchorRect, constraints),
      ),
    );
    final controller = FiloTooltipWindowController(
      backend: backend,
      delegate: delegate,
      parent: parent,
      handle: handle,
      view: resolveView(handle.viewId),
    );
    _register(
      viewId: handle.viewId,
      controller: controller,
      onCloseRequested: () {},
      onDestroyed: delegate.onWindowDestroyed,
    );
    return controller;
  }

  @override
  PopupWindowController createPopupWindowController({
    required PopupWindowControllerDelegate delegate,
    required BoxConstraints constraints,
    required Rect anchorRect,
    required WindowPositioner positioner,
    required BaseWindowController parent,
  }) {
    _ensureEnabled();
    final handle = backend.createWindow(
      FiloWindowRequest(
        kind: FiloWindowKind.popup,
        constraints: constraints,
        resizable: false,
        decorated: false,
        sizedToContent: true,
        parentViewId: parent.rootView.viewId,
        positioner: _toFiloPositioner(positioner, anchorRect, constraints),
      ),
    );
    final controller = FiloPopupWindowController(
      backend: backend,
      delegate: delegate,
      parent: parent,
      handle: handle,
      view: resolveView(handle.viewId),
    );
    _register(
      viewId: handle.viewId,
      controller: controller,
      onCloseRequested: () {},
      onDestroyed: delegate.onWindowDestroyed,
    );
    return controller;
  }

  @override
  SatelliteWindowController createSatelliteWindowController({
    required SatelliteWindowControllerDelegate delegate,
    required BaseWindowController parent,
    required WindowPositioner initialPositioner,
    Rect? initialAnchorRect,
    Size? size,
    BoxConstraints? constraints,
    required bool resizable,
    String? title,
  }) {
    // Core xdg-shell has no programmatic toplevel positioning or move, so the
    // satellite contract (initial positioner, relative offset tracking,
    // reparenting without moving) cannot be honoured on Wayland.
    throw UnimplementedError(
      'Satellite windows are not supported on the Filo embedder: core '
      'xdg-shell cannot position or move a toplevel.',
    );
  }

  void _register({
    required int viewId,
    required FiloWindowControllerMixin controller,
    required void Function() onCloseRequested,
    required void Function() onDestroyed,
  }) {
    _controllers[viewId] = _ControllerEntry(
      onStateChanged: controller.handleStateChanged,
      onCloseRequested: onCloseRequested,
      onDestroyed: () {
        controller.handleDestroyed();
        onDestroyed();
      },
    );
  }

  void _dispatch(FiloWindowEvent event) {
    final entry = _controllers[event.viewId];
    if (entry == null) return;

    switch (event) {
      case FiloWindowCloseRequested():
        entry.onCloseRequested();
      case FiloWindowDestroyed():
        _controllers.remove(event.viewId);
        entry.onDestroyed();
      case FiloWindowStateChanged():
        entry.onStateChanged();
    }
  }

  void _ensureEnabled() {
    if (!isWindowingEnabled) {
      throw StateError(
        'Windowing is not enabled. Call installFiloWindowing() before '
        'creating a window.',
      );
    }
  }
}

class _ControllerEntry {
  const _ControllerEntry({
    required this.onStateChanged,
    required this.onCloseRequested,
    required this.onDestroyed,
  });

  final void Function() onStateChanged;
  final void Function() onCloseRequested;
  final void Function() onDestroyed;
}

FiloPositioner _toFiloPositioner(
  WindowPositioner positioner,
  Rect anchorRect,
  BoxConstraints constraints,
) {
  final width = constraints.minWidth.isFinite && constraints.minWidth >= 1
      ? constraints.minWidth.round()
      : 1;
  final height = constraints.minHeight.isFinite && constraints.minHeight >= 1
      ? constraints.minHeight.round()
      : 1;

  final adjustment = positioner.constraintAdjustment;
  var flags = 0;
  if (adjustment.slideX) flags |= 1;
  if (adjustment.slideY) flags |= 2;
  if (adjustment.flipX) flags |= 4;
  if (adjustment.flipY) flags |= 8;
  if (adjustment.resizeX) flags |= 16;
  if (adjustment.resizeY) flags |= 32;

  return FiloPositioner(
    size: FiloSize(width, height),
    anchorRect: FiloRect(
      x: anchorRect.left.round(),
      y: anchorRect.top.round(),
      width: anchorRect.width.round(),
      height: anchorRect.height.round(),
    ),
    anchor: FiloPositionerAnchor.values[positioner.parentAnchor.index],
    gravity: FiloPositionerGravity.values[positioner.childAnchor.index],
    constrainsAdjustments: FiloPositionerConstrainsAdjustmentsFlags(flags),
    offset: FiloOffset(positioner.offset.dx.round(), positioner.offset.dy.round()),
  );
}
