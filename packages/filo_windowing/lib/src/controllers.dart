// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:ui' show Display, FlutterView, Offset, Rect, Size;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart' show BoxConstraints;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';

import 'backend.dart';
import 'models.dart';
import 'positioner.dart';

/// Shared state and behaviour for controllers backed by a
/// [FiloWindowingBackend].
///
/// The controller keeps the last state the backend reported. The observer
/// callbacks update it and notify listeners; `onClose` and `onDestroy` go
/// straight to the delegate.
mixin FiloWindowControllerMixin on ChangeNotifier {
  late final FiloWindowingBackend _backend;
  late final int _viewId;
  late final void Function() _onClose;
  late final void Function() _onDestroy;

  late Size _contentSize;
  late String _title;
  late int _state;
  late int _capabilities;
  late Offset _offset;

  bool _destroyed = false;
  bool _destroyRequested = false;

  /// Called by the concrete controller once, from its constructor.
  void initWindow({
    required FiloWindowingBackend backend,
    required FiloWindowHandle handle,
    required void Function() onClose,
    required void Function() onDestroy,
  }) {
    _backend = backend;
    _viewId = handle.viewId;
    _onClose = onClose;
    _onDestroy = onDestroy;

    _contentSize = handle.contentSize;
    _title = handle.title ?? '';
    _state = handle.toplevelState;
    _capabilities = handle.wmCapabilities;
    _offset = handle.offsetFromParent;

    backend.observe(
      _viewId,
      FiloWindowObserver(
        onConfigure: (size) {
          _contentSize = size;
          notifyListeners();
        },
        onStateChanged: (bits) {
          _state = bits;
          notifyListeners();
        },
        onCapabilitiesChanged: (bits) {
          _capabilities = bits;
          notifyListeners();
        },
        onTitleChanged: (title) {
          _title = title;
          notifyListeners();
        },
        onMoved: (offset) {
          _offset = offset;
          notifyListeners();
        },
        onClose: _handleClose,
        onDestroy: _handleDestroy,
      ),
    );
  }

  FiloWindowingBackend get backend => _backend;

  int get viewId => _viewId;

  bool get isDestroyed => _destroyed;

  Size get contentSize => _destroyed ? Size.zero : _contentSize;

  String get windowTitle => _destroyed ? '' : _title;

  int get windowState => _destroyed ? 0 : _state;

  int get windowCapabilities => _destroyed ? 0 : _capabilities;

  Offset get windowOffset => _destroyed ? Offset.zero : _offset;

  bool hasState(FiloToplevelState state) =>
      !_destroyed && (_state & state.mask) != 0;

  void destroy() {
    if (_destroyed || _destroyRequested) return;
    _destroyRequested = true;
    _backend.destroyWindow(_viewId);
  }

  void setConstraints(BoxConstraints constraints) {
    if (_destroyed) return;
    _backend.setConstraints(_viewId, constraints);
  }

  /// Update the cached title after a local [setTitle] call.
  void updateTitle(String title) {
    _title = title;
    notifyListeners();
  }

  void _handleClose() {
    if (!_destroyed) _onClose();
  }

  void _handleDestroy() {
    if (_destroyed) return;
    _destroyed = true;
    _destroyRequested = true;
    _onDestroy();
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
    required FlutterView Function(int viewId) resolveView,
    Size? size,
    BoxConstraints? constraints,
    required bool resizable,
    String? title,
    bool reuseImplicitView = true,
  }) : _delegate = delegate,
       super.empty() {
    final handle = backend.createWindow(
      FiloWindowRequest(
        kind: FiloWindowKind.toplevel,
        size: size,
        constraints: constraints,
        resizable: resizable,
        sizedToContent: size == null,
        title: title,
        preferredViewId: reuseImplicitView ? 0 : -1,
      ),
    );
    try {
      rootView = resolveView(handle.viewId);
      initWindow(
        backend: backend,
        handle: handle,
        onClose: () => _delegate.onWindowCloseRequested(this),
        onDestroy: _delegate.onWindowDestroyed,
      );
    } catch (_) {
      backend.destroyWindow(handle.viewId);
      rethrow;
    }
  }

  final RegularWindowControllerDelegate _delegate;

  RegularWindowControllerDelegate get delegate => _delegate;

  @override
  String get title => windowTitle;

  @override
  bool get isActivated => hasState(FiloToplevelState.activated);

  @override
  bool get isMaximized => hasState(FiloToplevelState.maximized);

  @override
  bool get isMinimized => false;

  @override
  bool get isFullscreen => hasState(FiloToplevelState.fullscreen);

  @override
  void setSize(Size size) {
    if (!isDestroyed) backend.setSize(viewId, size);
  }

  @override
  void setTitle(String title) {
    if (isDestroyed) return;
    backend.setTitle(viewId, title);
    updateTitle(title);
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

/// A wlr-layer-shell window backed by the Filo embedder.
///
/// A layer window is not a regular toplevel: the compositor places it on an
/// output according to [FiloLayerSurface.layer], [FiloLayerSurface.anchors],
/// [FiloLayerSurface.margin] and [FiloLayerSurface.exclusiveZone]. It has no
/// title bar, cannot be moved or resized by the user, and does not appear in
/// the compositor's window switcher.
///
/// It still owns an ordinary Flutter view and renders like any other window.
/// By default the first layer window adopts the implicit view (id 0), just like
/// the first regular window; set `reuseImplicitView` to false to force a new
/// Flutter view.
class FiloLayerWindowController extends RegularWindowController
    with FiloWindowControllerMixin {
  FiloLayerWindowController({
    required FiloWindowingBackend backend,
    required RegularWindowControllerDelegate delegate,
    required FlutterView Function(int viewId) resolveView,
    required FiloLayerSurface layerSurface,
    Size? size,
    BoxConstraints? constraints,
    bool? sizedToContent,
    bool reuseImplicitView = true,
  }) : _delegate = delegate,
       _layerSurface = layerSurface,
       super.empty() {
    final handle = backend.createWindow(
      FiloWindowRequest(
        kind: FiloWindowKind.layer,
        size: size,
        constraints: constraints,
        resizable: false,
        sizedToContent: sizedToContent ?? size == null,
        decorated: false,
        preferredViewId: reuseImplicitView ? 0 : -1,
        layer: layerSurface,
      ),
    );
    try {
      rootView = resolveView(handle.viewId);
      initWindow(
        backend: backend,
        handle: handle,
        onClose: () => _delegate.onWindowCloseRequested(this),
        onDestroy: _delegate.onWindowDestroyed,
      );
    } catch (_) {
      backend.destroyWindow(handle.viewId);
      rethrow;
    }
  }

  final RegularWindowControllerDelegate _delegate;
  FiloLayerSurface _layerSurface;

  RegularWindowControllerDelegate get delegate => _delegate;

  /// The layer-surface properties currently applied.
  FiloLayerSurface get layerSurface => _layerSurface;

  @override
  String get title => windowTitle;

  @override
  bool get isActivated => false;

  @override
  bool get isMaximized => false;

  @override
  bool get isMinimized => false;

  @override
  bool get isFullscreen => false;

  @override
  void setSize(Size size) {
    if (!isDestroyed) backend.setSize(viewId, size);
  }

  /// Layer surfaces have no title; this is a no-op.
  @override
  void setTitle(String title) {}

  @override
  void activate() {}

  @override
  void setMaximized(bool maximized) {}

  @override
  void setMinimized(bool minimized) {}

  @override
  void setFullscreen(bool fullscreen, {Display? display}) {}

  /// Apply a complete new layer-surface state.
  void updateLayerSurface(FiloLayerSurface surface) {
    if (isDestroyed) return;
    backend.updateLayerSurface(viewId, surface);
    _layerSurface = surface;
  }

  void setLayer(FiloLayer layer) {
    updateLayerSurface(_layerSurface.copyWith(layer: layer));
  }

  void setAnchors(FiloLayerAnchors anchors) {
    updateLayerSurface(_layerSurface.copyWith(anchors: anchors));
  }

  void setExclusiveZone(int zone) {
    updateLayerSurface(_layerSurface.copyWith(exclusiveZone: zone));
  }

  void setMargins(FiloInsets margin) {
    updateLayerSurface(_layerSurface.copyWith(margin: margin));
  }

  /// Make the surface click-through (false) or interactive (true).
  void setAcceptsInput(bool acceptsInput) {
    updateLayerSurface(_layerSurface.copyWith(acceptsInput: acceptsInput));
  }

  void setKeyboardInteractivity(
    FiloLayerKeyboardInteractivity keyboardInteractivity,
  ) {
    updateLayerSurface(
      _layerSurface.copyWith(keyboardInteractivity: keyboardInteractivity),
    );
  }
}

/// A dialog window backed by the Filo embedder.
class FiloDialogWindowController extends DialogWindowController
    with FiloWindowControllerMixin {
  FiloDialogWindowController({
    required FiloWindowingBackend backend,
    required DialogWindowControllerDelegate delegate,
    required this.parent,
    required FlutterView Function(int viewId) resolveView,
    Size? size,
    BoxConstraints? constraints,
    required bool resizable,
    String? title,
  }) : _delegate = delegate,
       super.empty() {
    final handle = backend.createWindow(
      FiloWindowRequest(
        kind: FiloWindowKind.toplevel,
        size: size,
        constraints: constraints,
        resizable: resizable,
        sizedToContent: size == null,
        title: title,
        parentViewId: parent?.rootView.viewId ?? -1,
        modal: parent != null,
      ),
    );
    try {
      rootView = resolveView(handle.viewId);
      initWindow(
        backend: backend,
        handle: handle,
        onClose: () => _delegate.onWindowCloseRequested(this),
        onDestroy: _delegate.onWindowDestroyed,
      );
    } catch (_) {
      backend.destroyWindow(handle.viewId);
      rethrow;
    }
  }

  final DialogWindowControllerDelegate _delegate;

  @override
  final BaseWindowController? parent;

  DialogWindowControllerDelegate get delegate => _delegate;

  @override
  String get title => windowTitle;

  @override
  bool get isActivated => hasState(FiloToplevelState.activated);

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
    updateTitle(title);
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
    required FlutterView Function(int viewId) resolveView,
    required BoxConstraints constraints,
    required Rect anchorRect,
    required WindowPositioner positioner,
  }) : _delegate = delegate,
       super.empty() {
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
    try {
      rootView = resolveView(handle.viewId);
      initWindow(
        backend: backend,
        handle: handle,
        onClose: destroy,
        onDestroy: _delegate.onWindowDestroyed,
      );
    } catch (_) {
      backend.destroyWindow(handle.viewId);
      rethrow;
    }
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
    required FlutterView Function(int viewId) resolveView,
    required BoxConstraints constraints,
    required Rect anchorRect,
    required WindowPositioner positioner,
  }) : _delegate = delegate,
       super.empty() {
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
    try {
      rootView = resolveView(handle.viewId);
      initWindow(
        backend: backend,
        handle: handle,
        onClose: destroy,
        onDestroy: _delegate.onWindowDestroyed,
      );
    } catch (_) {
      backend.destroyWindow(handle.viewId);
      rethrow;
    }
  }

  final PopupWindowControllerDelegate _delegate;

  @override
  final BaseWindowController parent;

  PopupWindowControllerDelegate get delegate => _delegate;
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
    offset: FiloOffset(
      positioner.offset.dx.round(),
      positioner.offset.dy.round(),
    ),
  );
}
