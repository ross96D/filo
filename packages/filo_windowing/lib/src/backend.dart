// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:ui' show Display, Offset, Rect, Size;

import 'package:flutter/rendering.dart' show BoxConstraints;
import 'package:flutter/src/widgets/_window_positioner.dart';

import 'models.dart';

/// Per-window callbacks.
///
/// The backend invokes them synchronously on the UI isolate, on the thread
/// that owns the windowing loop. They must not create a window reentrantly:
/// creating one calls back into the engine synchronously. Defer window
/// creation from a callback with `scheduleMicrotask` or a post-frame callback.
///
/// `onDestroy` is the last callback for a window. After it returns the backend
/// may release the native callables.
class FiloWindowObserver {
  const FiloWindowObserver({
    this.onConfigure,
    this.onStateChanged,
    this.onCapabilitiesChanged,
    this.onTitleChanged,
    this.onMoved,
    this.onClose,
    this.onDestroy,
  });

  /// The compositor configured a new content size.
  final void Function(Size contentSize)? onConfigure;

  /// The `xdg_toplevel.state` bitmask changed.
  final void Function(int toplevelState)? onStateChanged;

  /// The `xdg_toplevel.wm_capabilities` bitmask changed.
  final void Function(int wmCapabilities)? onCapabilitiesChanged;

  final void Function(String title)? onTitleChanged;

  /// A popup moved; [offsetFromParent] is the new relative offset.
  final void Function(Offset offsetFromParent)? onMoved;

  /// The compositor or user asked the window to close. The window is still
  /// alive; the delegate decides whether to destroy it.
  final void Function()? onClose;

  /// The native window and its Flutter view are gone.
  final void Function()? onDestroy;
}

/// The synchronous native boundary of the windowing implementation.
///
/// The embedder supplies an implementation (see [FiloNativeBackend]). Creating
/// a window must return only after the corresponding `FlutterView` is present
/// in `PlatformDispatcher.views`; every operation here is synchronous from the
/// caller's point of view.
abstract interface class FiloWindowingBackend {
  /// Create a native window and its Flutter view, synchronously.
  FiloWindowHandle createWindow(FiloWindowRequest request);

  /// Register [observer] for a window returned by [createWindow].
  ///
  /// Call this before the UI task returns so no earlier callback is missed.
  void observe(int viewId, FiloWindowObserver observer);

  /// Destroy a window. Idempotent; the actual teardown is asynchronous and is
  /// reported to [FiloWindowObserver.onDestroy].
  void destroyWindow(int viewId);

  void setTitle(int viewId, String title);
  void setSize(int viewId, Size size);
  void setConstraints(int viewId, BoxConstraints constraints);
  void activate(int viewId);
  void setMaximized(int viewId, bool maximized);
  void setMinimized(int viewId, bool minimized);
  void setFullscreen(int viewId, bool fullscreen, {Display? display});

  /// Reposition a popup. Either argument may be omitted to keep the previous
  /// value.
  void updatePosition(
    int viewId, {
    Rect? anchorRect,
    WindowPositioner? positioner,
  });

  /// Change the wlr-layer-shell properties of a layer window. The output and
  /// namespace are fixed at creation and ignored here.
  void updateLayerSurface(int viewId, FiloLayerSurface surface);

  /// Set the native parent, or detach it when [parentViewId] is -1.
  void setParent(int viewId, int parentViewId);
}
