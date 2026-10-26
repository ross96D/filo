// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:ui' show FlutterView, Rect, Size;

import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';
import 'package:flutter/widgets.dart';

import 'backend.dart';
import 'controllers.dart';
import 'models.dart';

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
    return FiloRegularWindowController(
      backend: backend,
      delegate: delegate,
      resolveView: resolveView,
      size: size,
      constraints: constraints,
      resizable: resizable,
      title: title,
      reuseImplicitView: reuseImplicitView,
    );
  }

  /// Creates a wlr-layer-shell window. This is not part of Flutter's
  /// `WindowingOwner` interface: layer surfaces are a Filo extension.
  ///
  /// The controller is a [RegularWindowController] subtype so it can be passed
  /// to [FiloLayerWindow]. When [reuseImplicitView] is true it adopts the
  /// implicit view (id 0), like the first regular window does. A layer-only
  /// embedder bootstraps that view's layer surface before startup.
  FiloLayerWindowController createLayerWindowController({
    required RegularWindowControllerDelegate delegate,
    required FiloLayerSurface layerSurface,
    Size? size,
    BoxConstraints? constraints,
    bool? sizedToContent,
    bool? reuseImplicitView,
  }) {
    _ensureEnabled();
    return FiloLayerWindowController(
      backend: backend,
      delegate: delegate,
      resolveView: resolveView,
      layerSurface: layerSurface,
      size: size,
      constraints: constraints,
      sizedToContent: sizedToContent,
      reuseImplicitView: reuseImplicitView ?? this.reuseImplicitView,
    );
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
    return FiloDialogWindowController(
      backend: backend,
      delegate: delegate,
      parent: parent,
      resolveView: resolveView,
      size: size,
      constraints: constraints,
      resizable: resizable,
      title: title,
    );
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
    return FiloTooltipWindowController(
      backend: backend,
      delegate: delegate,
      parent: parent,
      resolveView: resolveView,
      constraints: constraints,
      anchorRect: anchorRect,
      positioner: positioner,
    );
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
    return FiloPopupWindowController(
      backend: backend,
      delegate: delegate,
      parent: parent,
      resolveView: resolveView,
      constraints: constraints,
      anchorRect: anchorRect,
      positioner: positioner,
    );
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

  void _ensureEnabled() {
    if (!isWindowingEnabled) {
      throw StateError(
        'Windowing is not enabled. Call installFiloWindowing() before '
        'creating a window.',
      );
    }
  }
}
