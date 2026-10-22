// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:ui' show Display, FlutterView, Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show BoxConstraints;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';

import 'backend.dart';
import 'models.dart';

/// Shared state and behaviour for controllers backed by a
/// [FiloWindowingBackend].
mixin FiloWindowControllerMixin on ChangeNotifier {
  late final FiloWindowingBackend _backend;
  late final int _viewId;
  bool _destroyed = false;
  bool _destroyRequested = false;

  /// Called by the concrete controller once, from its constructor.
  void initWindow({
    required FiloWindowingBackend backend,
    required FiloWindowHandle handle,
  }) {
    _backend = backend;
    _viewId = handle.viewId;
  }

  FiloWindowingBackend get backend => _backend;

  int get viewId => _viewId;

  bool get isDestroyed => _destroyed;

  Size get windowContentSize =>
      _destroyed ? Size.zero : _backend.getSize(_viewId);

  String get windowTitle => _destroyed ? '' : _backend.getTitle(_viewId);

  Set<FiloToplevelState> get windowState =>
      _destroyed ? const <FiloToplevelState>{} : _backend.getState(_viewId);

  Set<FiloToplevelWMCapabilities> get windowCapabilities => _destroyed
      ? const <FiloToplevelWMCapabilities>{}
      : _backend.getCapabilities(_viewId);

  Offset get windowOffset =>
      _destroyed ? Offset.zero : _backend.getOffset(_viewId);

  Size get contentSize => windowContentSize;

  void destroy() {
    if (_destroyed || _destroyRequested) return;
    _destroyRequested = true;
    _backend.destroyWindow(_viewId);
  }

  void setConstraints(BoxConstraints constraints) {
    if (_destroyed) return;
    _backend.setConstraints(_viewId, constraints);
  }

  /// The owner calls this when the backend reports a state change.
  void handleStateChanged() {
    if (!_destroyed) notifyListeners();
  }

  /// The owner calls this when the backend reports the window is gone.
  void handleDestroyed() {
    if (_destroyed) return;
    _destroyed = true;
    _destroyRequested = true;
    notifyListeners();
  }
}

/// Adds the popup/tooltip repositioning API.
mixin FiloPositionedWindowControllerMixin on FiloWindowControllerMixin {
  void updatePosition({Rect? anchorRect, WindowPositioner? positioner}) {
    if (isDestroyed) return;
    backend.updatePosition(
      viewId,
      anchorRect: anchorRect,
      positioner: positioner,
    );
  }

  Offset get offsetFromParent => windowOffset;
}

/// A regular top-level window backed by the Filo embedder.
class FiloRegularWindowController extends RegularWindowController
    with FiloWindowControllerMixin {
  FiloRegularWindowController({
    required FiloWindowingBackend backend,
    required RegularWindowControllerDelegate delegate,
    required FiloWindowHandle handle,
    required FlutterView view,
  }) : _delegate = delegate,
       super.empty() {
    initWindow(backend: backend, handle: handle);
    rootView = view;
  }

  final RegularWindowControllerDelegate _delegate;

  RegularWindowControllerDelegate get delegate => _delegate;

  @override
  String get title => windowTitle;

  @override
  bool get isActivated =>
      windowState.contains(FiloToplevelState.activated);

  @override
  bool get isMaximized =>
      windowState.contains(FiloToplevelState.maximized);

  @override
  bool get isMinimized => false;

  @override
  bool get isFullscreen =>
      windowState.contains(FiloToplevelState.fullscreen);

  @override
  void setSize(Size size) {
    if (!isDestroyed) backend.setSize(viewId, size);
  }

  @override
  void setTitle(String title) {
    if (isDestroyed) return;
    backend.setTitle(viewId, title);
    notifyListeners();
  }

  @override
  void activate() {
    if (!isDestroyed) backend.activate(viewId);
  }

  @override
  void setMaximized(bool maximized) {
    if (!isDestroyed) backend.setMaximized(viewId, maximized);
  }

  @override
  void setMinimized(bool minimized) {
    if (!isDestroyed) backend.setMinimized(viewId, minimized);
  }

  @override
  void setFullscreen(bool fullscreen, {Display? display}) {
    if (!isDestroyed) {
      backend.setFullscreen(viewId, fullscreen, display: display);
    }
  }
}

/// A dialog window backed by the Filo embedder.
class FiloDialogWindowController extends DialogWindowController
    with FiloWindowControllerMixin {
  FiloDialogWindowController({
    required FiloWindowingBackend backend,
    required DialogWindowControllerDelegate delegate,
    required this.parent,
    required FiloWindowHandle handle,
    required FlutterView view,
  }) : _delegate = delegate,
       super.empty() {
    initWindow(backend: backend, handle: handle);
    rootView = view;
  }

  final DialogWindowControllerDelegate _delegate;

  @override
  final BaseWindowController? parent;

  DialogWindowControllerDelegate get delegate => _delegate;

  @override
  String get title => windowTitle;

  @override
  bool get isActivated =>
      windowState.contains(FiloToplevelState.activated);

  @override
  bool get isMinimized => false;

  @override
  void setSize(Size size) {
    if (!isDestroyed) backend.setSize(viewId, size);
  }

  @override
  void setTitle(String title) {
    if (isDestroyed) return;
    backend.setTitle(viewId, title);
    notifyListeners();
  }

  @override
  void activate() {
    if (!isDestroyed) backend.activate(viewId);
  }

  @override
  void setMinimized(bool minimized) {
    if (!isDestroyed) backend.setMinimized(viewId, minimized);
  }
}

/// A tooltip window backed by the Filo embedder.
class FiloTooltipWindowController extends TooltipWindowController
    with FiloWindowControllerMixin, FiloPositionedWindowControllerMixin {
  FiloTooltipWindowController({
    required FiloWindowingBackend backend,
    required TooltipWindowControllerDelegate delegate,
    required this.parent,
    required FiloWindowHandle handle,
    required FlutterView view,
  }) : _delegate = delegate,
       super.empty() {
    initWindow(backend: backend, handle: handle);
    rootView = view;
  }

  final TooltipWindowControllerDelegate _delegate;

  @override
  final BaseWindowController parent;

  TooltipWindowControllerDelegate get delegate => _delegate;
}

/// A popup window backed by the Filo embedder.
class FiloPopupWindowController extends PopupWindowController
    with FiloWindowControllerMixin, FiloPositionedWindowControllerMixin {
  FiloPopupWindowController({
    required FiloWindowingBackend backend,
    required PopupWindowControllerDelegate delegate,
    required this.parent,
    required FiloWindowHandle handle,
    required FlutterView view,
  }) : _delegate = delegate,
       super.empty() {
    initWindow(backend: backend, handle: handle);
    rootView = view;
  }

  final PopupWindowControllerDelegate _delegate;

  @override
  final BaseWindowController parent;

  PopupWindowControllerDelegate get delegate => _delegate;
}
