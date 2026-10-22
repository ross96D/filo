// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ui' show Display, Offset, Rect, Size;

import 'package:flutter/rendering.dart' show BoxConstraints;
import 'package:flutter/src/widgets/_window_positioner.dart';

import 'models.dart';

/// The synchronous native boundary of the windowing implementation.
///
/// The embedder supplies an implementation (see [FiloNativeBackend]). Creating
/// a window must return only after the corresponding `FlutterView` is present
/// in `PlatformDispatcher.views`; every operation here is synchronous from the
/// caller's point of view.
abstract interface class FiloWindowingBackend {
  /// Events for every window, delivered on the UI isolate.
  Stream<FiloWindowEvent> get events;

  /// Create a native window and its Flutter view, synchronously.
  FiloWindowHandle createWindow(FiloWindowRequest request);

  /// Destroy a window. Idempotent; the actual teardown is asynchronous and is
  /// reported with [FiloWindowDestroyed].
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
  void updatePosition(int viewId, {Rect? anchorRect, WindowPositioner? positioner});

  /// Set the native parent, or detach it when [parentViewId] is -1.
  void setParent(int viewId, int parentViewId);

  Size getSize(int viewId);
  Set<FiloToplevelState> getState(int viewId);
  Set<FiloToplevelWMCapabilities> getCapabilities(int viewId);
  String getTitle(int viewId);
  Offset getOffset(int viewId);
}
