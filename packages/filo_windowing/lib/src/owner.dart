import 'dart:ui' show FlutterView, Rect, Size;

import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';
import 'package:flutter/widgets.dart';

import 'controllers.dart';

/// A [WindowingOwner] implementation backed by the Filo embedder.
///
/// Install it with [installFiloWindowing], or assign it to
/// `WidgetsBinding.instance.windowingOwner` yourself.
///
/// The owner creates controllers synchronously through [backend]. Every
/// controller's [BaseWindowController.rootView] is resolved from
/// `PlatformDispatcher.views` before the controller is returned.
class FiloWindowingOwner with WidgetsBindingObserver implements WindowingOwner {
  /// Creates an owner.
  ///
  /// The binding must be initialized, and windowing must be enabled. Prefer
  /// [installFiloWindowing], which takes care of both.
  FiloWindowingOwner({this.viewResolver}) {
    if (!isWindowingEnabled) {
      throw StateError(
        'Windowing is not enabled. Call installFiloWindowing() before '
        'creating a FiloWindowingOwner.',
      );
    }
    WidgetsFlutterBinding.ensureInitialized();
    WidgetsBinding.instance.addObserver(this);
  }

  /// Resolves a view id to a Flutter view.
  ///
  /// Defaults to searching `PlatformDispatcher.views`. Tests can inject a
  /// resolver for views that are not registered with the platform dispatcher.
  final FlutterView Function(int viewId)? viewResolver;

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
      delegate: delegate,
      size: size,
      constraints: constraints,
      title: title,
      resizable: resizable,
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
      delegate: delegate,
      size: size,
      constraints: constraints,
      resizable: resizable,
      parent: parent,
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
      delegate: delegate,
      parent: parent,
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
      delegate: delegate,
      parent: parent,
      positioner: positioner,
      constraints: constraints,
      anchorRect: anchorRect,
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
    _ensureEnabled();
    return FiloSatelliteWindowController(
      delegate: delegate,
      parent: parent,
      initialPositioner: initialPositioner,
      initialAnchorRect: initialAnchorRect,
      size: size,
      resizable: resizable,
      constraints: constraints,
      title: title,
    );
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
      'The embedder returned view id $viewId, but no such FlutterView is '
      'registered with PlatformDispatcher.views (known ids: [$known]). '
      'FiloWindowingBackend.createWindow must create the native view '
      'synchronously.',
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
