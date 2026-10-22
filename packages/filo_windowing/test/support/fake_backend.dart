// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ui' show Display, Offset, Rect, Size;

import 'package:filo_windowing/filo_windowing.dart';
import 'package:flutter/rendering.dart' show BoxConstraints;
import 'package:flutter/src/widgets/_window_positioner.dart';

/// A [FiloWindowingBackend] that records calls and lets a test emit events.
class FakeBackend implements FiloWindowingBackend {
  final StreamController<FiloWindowEvent> _events =
      StreamController<FiloWindowEvent>.broadcast(sync: true);

  final List<FiloWindowRequest> requests = <FiloWindowRequest>[];
  final List<String> calls = <String>[];
  final Map<int, Size> sizes = <int, Size>{};
  final Map<int, Set<FiloToplevelState>> states =
      <int, Set<FiloToplevelState>>{};
  final Map<int, Set<FiloToplevelWMCapabilities>> capabilities =
      <int, Set<FiloToplevelWMCapabilities>>{};
  final Map<int, String> titles = <int, String>{};
  final Map<int, Offset> offsets = <int, Offset>{};

  /// The view id of the most recently created window.
  int? lastViewId;

  int _nextId = 1;
  bool _adoptedImplicit = false;

  @override
  Stream<FiloWindowEvent> get events => _events.stream;

  /// Deliver an event as the native backend would.
  void emit(FiloWindowEvent event) => _events.add(event);

  @override
  FiloWindowHandle createWindow(FiloWindowRequest request) {
    requests.add(request);

    final id = !_adoptedImplicit && request.preferredViewId == 0
        ? 0
        : _nextId++;
    if (id == 0) _adoptedImplicit = true;
    lastViewId = id;

    final size = request.size ?? const Size(1, 1);
    sizes[id] = size;
    titles[id] = request.title ?? '';
    offsets[id] = Offset.zero;

    return FiloWindowHandle(
      viewId: id,
      contentSize: size,
      title: request.title,
      toplevelState: const <FiloToplevelState>{},
      wmCapabilities: const <FiloToplevelWMCapabilities>{},
      offsetFromParent: Offset.zero,
    );
  }

  @override
  void destroyWindow(int viewId) {
    calls.add('destroy:$viewId');
    // The native removal is asynchronous; mimic that so callers do not rely on
    // a synchronous destroy callback.
    scheduleMicrotask(() => _events.add(FiloWindowDestroyed(viewId)));
  }

  @override
  void setTitle(int viewId, String title) {
    titles[viewId] = title;
    calls.add('setTitle:$viewId:$title');
  }

  @override
  void setSize(int viewId, Size size) {
    sizes[viewId] = size;
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

  @override
  Size getSize(int viewId) => sizes[viewId] ?? Size.zero;

  @override
  Set<FiloToplevelState> getState(int viewId) =>
      states[viewId] ?? const <FiloToplevelState>{};

  @override
  Set<FiloToplevelWMCapabilities> getCapabilities(int viewId) =>
      capabilities[viewId] ?? const <FiloToplevelWMCapabilities>{};

  @override
  String getTitle(int viewId) => titles[viewId] ?? '';

  @override
  Offset getOffset(int viewId) => offsets[viewId] ?? Offset.zero;
}
