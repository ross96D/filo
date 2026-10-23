// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ui' show Display, Offset, Rect, Size;

import 'package:filo_windowing/filo_windowing.dart';
import 'package:flutter/rendering.dart' show BoxConstraints;
import 'package:flutter/src/widgets/_window_positioner.dart';

/// A [FiloWindowingBackend] that records calls and exposes its observers so a
/// test can drive the callbacks directly.
class FakeBackend implements FiloWindowingBackend {
  final List<FiloWindowRequest> requests = <FiloWindowRequest>[];
  final List<String> calls = <String>[];
  final Map<int, FiloWindowObserver> observers = <int, FiloWindowObserver>{};

  /// The view id of the most recently created window.
  int? lastViewId;

  int _nextId = 1;
  bool _adoptedImplicit = false;

  /// The observer registered for [viewId].
  FiloWindowObserver observerFor(int viewId) => observers[viewId]!;

  @override
  FiloWindowHandle createWindow(FiloWindowRequest request) {
    requests.add(request);

    final id = !_adoptedImplicit && request.preferredViewId == 0
        ? 0
        : _nextId++;
    if (id == 0) _adoptedImplicit = true;
    lastViewId = id;

    return FiloWindowHandle(
      viewId: id,
      contentSize: request.size ?? const Size(1, 1),
      title: request.title,
      toplevelState: 0,
      wmCapabilities: 0,
      offsetFromParent: Offset.zero,
    );
  }

  @override
  void observe(int viewId, FiloWindowObserver observer) {
    observers[viewId] = observer;
    calls.add('observe:$viewId');
  }

  @override
  void destroyWindow(int viewId) {
    calls.add('destroy:$viewId');
    // The native removal is asynchronous; mimic that so callers do not rely on
    // a synchronous destroy callback.
    scheduleMicrotask(() {
      observers.remove(viewId)?.onDestroy?.call();
    });
  }

  @override
  void setTitle(int viewId, String title) {
    calls.add('setTitle:$viewId:$title');
  }

  @override
  void setSize(int viewId, Size size) {
    calls.add('setSize:$viewId:${size.width}x${size.height}');
  }

  @override
  void setConstraints(int viewId, BoxConstraints constraints) {
    calls.add('setConstraints:$viewId');
  }

  @override
  void activate(int viewId) => calls.add('activate:$viewId');

  @override
  void setMaximized(int viewId, bool maximized) =>
      calls.add('setMaximized:$viewId:$maximized');

  @override
  void setMinimized(int viewId, bool minimized) =>
      calls.add('setMinimized:$viewId:$minimized');

  @override
  void setFullscreen(int viewId, bool fullscreen, {Display? display}) =>
      calls.add('setFullscreen:$viewId:$fullscreen');

  @override
  void updatePosition(
    int viewId, {
    Rect? anchorRect,
    WindowPositioner? positioner,
  }) => calls.add('updatePosition:$viewId');

  @override
  void setParent(int viewId, int parentViewId) =>
      calls.add('setParent:$viewId:$parentViewId');
}
