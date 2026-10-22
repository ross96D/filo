// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:ui' show Display, Offset, Rect, Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/rendering.dart' show BoxConstraints;
import 'package:flutter/src/widgets/_window_positioner.dart';

import 'backend.dart';
import 'models.dart';
import 'positioner.dart';

//------------------------------------------------------------------------------
// Native ABI (mirrors src/windowing.zig)
//------------------------------------------------------------------------------

final class _Size extends Struct {
  @Uint32()
  external int width;

  @Uint32()
  external int height;
}

final class _Offset extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;
}

final class _Rect extends Struct {
  @Int32()
  external int x;

  @Int32()
  external int y;

  @Int32()
  external int width;

  @Int32()
  external int height;
}

final class _Positioner extends Struct {
  external _Size size;
  external _Rect anchorRect;

  @Int32()
  external int anchor;

  @Int32()
  external int gravity;

  @Uint32()
  external int constraintAdjustment;

  external _Offset offset;
}

final class _WindowRequest extends Struct {
  @Int32()
  external int kind;

  external _Size size;
  external _Size minSize;
  external _Size maxSize;

  @Uint8()
  external int resizable;

  @Uint8()
  external int sizedToContent;

  @Uint8()
  external int modal;

  @Uint8()
  external int decorated;

  external Pointer<Utf8> title;

  @Int64()
  external int parentViewId;

  @Int64()
  external int preferredViewId;

  external _Positioner positioner;
}

final class _WindowHandle extends Struct {
  @Int64()
  external int viewId;

  external _Size contentSize;

  external Pointer<Utf8> title;

  @Uint32()
  external int toplevelState;

  @Uint32()
  external int wmCapabilities;

  external _Offset offsetFromParent;
}

// final class _WindowCallbacks extends Struct {
//   external Pointer<NativeFunction<Void Function(Int32, Int32)>> onConfigure;
//   external Pointer<NativeFunction<Void Function(Uint32)>> onState;
//   external Pointer<NativeFunction<Void Function(Uint32)>> onCapabilities;
//   external Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> onTitle;
//   external Pointer<NativeFunction<Void Function(Int32, Int32)>> onMoved;
//   external Pointer<NativeFunction<Void Function()>> onClose;
//   external Pointer<NativeFunction<Void Function()>> onDestroy;
// }

@Native<Int32 Function(Pointer<_WindowRequest>, Pointer<_WindowHandle>)>(
  symbol: 'filo_window_create',
)
external int _create(Pointer<_WindowRequest> request, Pointer<_WindowHandle> out);

@Native<Int32 Function(Int64)>(symbol: 'filo_window_destroy')
external int _destroy(int viewId);

@Native<
  Int32 Function(
    Int64,
    Pointer<NativeFunction<Void Function(Int32, Int32)>>,
    Pointer<NativeFunction<Void Function(Uint32)>>,
    Pointer<NativeFunction<Void Function(Uint32)>>,
    Pointer<NativeFunction<Void Function(Pointer<Utf8>)>>,
    Pointer<NativeFunction<Void Function(Int32, Int32)>>,
    Pointer<NativeFunction<Void Function()>>,
    Pointer<NativeFunction<Void Function()>>,
  )
>(symbol: 'filo_window_observe')
external int _observe(
  int viewId,
  Pointer<NativeFunction<Void Function(Int32, Int32)>> onConfigure,
  Pointer<NativeFunction<Void Function(Uint32)>> onState,
  Pointer<NativeFunction<Void Function(Uint32)>> onCapabilities,
  Pointer<NativeFunction<Void Function(Pointer<Utf8>)>> onTitle,
  Pointer<NativeFunction<Void Function(Int32, Int32)>> onMoved,
  Pointer<NativeFunction<Void Function()>> onClose,
  Pointer<NativeFunction<Void Function()>> onDestroy,
);

@Native<Int32 Function(Int64, Pointer<Utf8>)>(symbol: 'filo_window_set_title')
external int _setTitle(int viewId, Pointer<Utf8> title);

@Native<Int32 Function(Int64, Int32, Int32)>(symbol: 'filo_window_set_size')
external int _setSize(int viewId, int width, int height);

@Native<Int32 Function(Int64, Int32, Int32, Int32, Int32)>(symbol: 'filo_window_set_constraints')
external int _setConstraints(int viewId, int minWidth, int minHeight, int maxWidth, int maxHeight);

@Native<Int32 Function(Int64)>(symbol: 'filo_window_activate')
external int _activate(int viewId);

@Native<Int32 Function(Int64, Uint8)>(symbol: 'filo_window_set_maximized')
external int _setMaximized(int viewId, int maximized);

@Native<Int32 Function(Int64, Uint8)>(symbol: 'filo_window_set_minimized')
external int _setMinimized(int viewId, int minimized);

@Native<Int32 Function(Int64, Uint8)>(symbol: 'filo_window_set_fullscreen')
external int _setFullscreen(int viewId, int fullscreen);

@Native<Int32 Function(Int64, Int64)>(symbol: 'filo_window_set_parent')
external int _setParent(int viewId, int parentViewId);

@Native<Int32 Function(Int64, Pointer<_Rect>, Pointer<_Positioner>)>(
  symbol: 'filo_window_update_position',
)
external int _updatePosition(int viewId, Pointer<_Rect> anchor, Pointer<_Positioner> positioner);

@Native<Int32 Function(Int64, Pointer<_Size>)>(symbol: 'filo_window_get_size')
external int _getSize(int viewId, Pointer<_Size> out);

@Native<Int32 Function(Int64, Pointer<Uint32>)>(symbol: 'filo_window_get_state')
external int _getState(int viewId, Pointer<Uint32> out);

@Native<Int32 Function(Int64, Pointer<Uint32>)>(symbol: 'filo_window_get_capabilities')
external int _getCapabilities(int viewId, Pointer<Uint32> out);

@Native<Int32 Function(Int64, Pointer<Uint8>, Uint32)>(symbol: 'filo_window_get_title')
external int _getTitle(int viewId, Pointer<Uint8> buffer, int length);

@Native<Int32 Function(Int64, Pointer<_Offset>)>(symbol: 'filo_window_get_offset')
external int _getOffset(int viewId, Pointer<_Offset> out);

//------------------------------------------------------------------------------
// Native backend
//------------------------------------------------------------------------------

/// The [FiloWindowingBackend] backed by the `filo_window_*` symbols the Filo
/// embedder exports from the process image.
class FiloNativeBackend implements FiloWindowingBackend {
  final StreamController<FiloWindowEvent> _events = StreamController<FiloWindowEvent>.broadcast(
    sync: true,
  );
  final Map<int, _WindowRecord> _windows = <int, _WindowRecord>{};

  @override
  Stream<FiloWindowEvent> get events => _events.stream;

  @override
  FiloWindowHandle createWindow(FiloWindowRequest request) {
    final requestPtr = calloc<_WindowRequest>();
    final handlePtr = calloc<_WindowHandle>();
    final titlePtr = request.title == null ? nullptr : request.title!.toNativeUtf8();
    try {
      final ref = requestPtr.ref;
      ref.kind = request.kind.index;
      ref.size.width = _dimension(request.size?.width);
      ref.size.height = _dimension(request.size?.height);
      ref.minSize.width = _constraint(request.constraints?.minWidth);
      ref.minSize.height = _constraint(request.constraints?.minHeight);
      ref.maxSize.width = _constraint(request.constraints?.maxWidth);
      ref.maxSize.height = _constraint(request.constraints?.maxHeight);
      ref.resizable = request.resizable ? 1 : 0;
      ref.sizedToContent = request.sizedToContent ? 1 : 0;
      ref.modal = request.modal ? 1 : 0;
      ref.decorated = request.decorated ? 1 : 0;
      ref.title = titlePtr;
      ref.parentViewId = request.parentViewId;
      ref.preferredViewId = request.preferredViewId;
      _writePositioner(ref.positioner, request.positioner);

      _check(_create(requestPtr, handlePtr), 'createWindow');

      final viewId = handlePtr.ref.viewId;
      final handle = FiloWindowHandle(
        viewId: viewId,
        contentSize: Size(
          handlePtr.ref.contentSize.width.toDouble(),
          handlePtr.ref.contentSize.height.toDouble(),
        ),
        title: handlePtr.ref.title == nullptr ? null : handlePtr.ref.title.toDartString(),
        toplevelState: _stateSet(handlePtr.ref.toplevelState),
        wmCapabilities: _capabilitySet(handlePtr.ref.wmCapabilities),
        offsetFromParent: Offset(
          handlePtr.ref.offsetFromParent.x.toDouble(),
          handlePtr.ref.offsetFromParent.y.toDouble(),
        ),
      );

      final observer = _Observer(this, viewId);
      _check(
        _observe(
          viewId,
          observer._onConfigure.nativeFunction,
          observer._onState.nativeFunction,
          observer._onCapabilities.nativeFunction,
          observer._onTitle.nativeFunction,
          observer._onMoved.nativeFunction,
          observer._onClose.nativeFunction,
          observer._onDestroy.nativeFunction,
        ),
        'observe',
      );

      _windows[viewId] = _WindowRecord(
        observer: observer,
        positioner: request.positioner ?? _defaultPositioner(request.size),
      );
      return handle;
    } finally {
      if (titlePtr != nullptr) malloc.free(titlePtr);
      calloc.free(requestPtr);
      calloc.free(handlePtr);
    }
  }

  @override
  void destroyWindow(int viewId) {
    _check(_destroy(viewId), 'destroyWindow');
  }

  @override
  void setTitle(int viewId, String title) {
    final titlePtr = title.toNativeUtf8();
    try {
      _check(_setTitle(viewId, titlePtr), 'setTitle');
    } finally {
      malloc.free(titlePtr);
    }
  }

  @override
  void setSize(int viewId, Size size) {
    _check(_setSize(viewId, _dimension(size.width), _dimension(size.height)), 'setSize');
  }

  @override
  void setConstraints(int viewId, BoxConstraints constraints) {
    _check(
      _setConstraints(
        viewId,
        _constraint(constraints.minWidth),
        _constraint(constraints.minHeight),
        _constraint(constraints.maxWidth),
        _constraint(constraints.maxHeight),
      ),
      'setConstraints',
    );
  }

  @override
  void activate(int viewId) {
    _check(_activate(viewId), 'activate');
  }

  @override
  void setMaximized(int viewId, bool maximized) {
    _check(_setMaximized(viewId, maximized ? 1 : 0), 'setMaximized');
  }

  @override
  void setMinimized(int viewId, bool minimized) {
    _check(_setMinimized(viewId, minimized ? 1 : 0), 'setMinimized');
  }

  @override
  void setFullscreen(int viewId, bool fullscreen, {Display? display}) {
    _check(_setFullscreen(viewId, fullscreen ? 1 : 0), 'setFullscreen');
  }

  @override
  void setParent(int viewId, int parentViewId) {
    _check(_setParent(viewId, parentViewId), 'setParent');
  }

  @override
  void updatePosition(int viewId, {Rect? anchorRect, WindowPositioner? positioner}) {
    final record = _windows[viewId];
    if (record == null) return;

    var current = record.positioner;
    if (positioner != null) {
      current = current.copyWith(
        anchor: FiloPositionerAnchor.values[positioner.parentAnchor.index],
        gravity: FiloPositionerGravity.values[positioner.childAnchor.index],
        constrainsAdjustments: _constraintAdjustment(positioner.constraintAdjustment),
        offset: FiloOffset(positioner.offset.dx.round(), positioner.offset.dy.round()),
      );
    }
    if (anchorRect != null) {
      current = current.copyWith(
        anchorRect: FiloRect(
          x: anchorRect.left.round(),
          y: anchorRect.top.round(),
          width: anchorRect.width.round(),
          height: anchorRect.height.round(),
        ),
      );
    }

    final positionerPtr = calloc<_Positioner>();
    try {
      _writePositioner(positionerPtr.ref, current);
      _check(_updatePosition(viewId, nullptr, positionerPtr), 'updatePosition');
      record.positioner = current;
    } finally {
      calloc.free(positionerPtr);
    }
  }

  @override
  Size getSize(int viewId) {
    final out = calloc<_Size>();
    try {
      _check(_getSize(viewId, out), 'getSize');
      return Size(out.ref.width.toDouble(), out.ref.height.toDouble());
    } finally {
      calloc.free(out);
    }
  }

  @override
  Set<FiloToplevelState> getState(int viewId) {
    final out = calloc<Uint32>();
    try {
      _check(_getState(viewId, out), 'getState');
      return _stateSet(out.value);
    } finally {
      calloc.free(out);
    }
  }

  @override
  Set<FiloToplevelWMCapabilities> getCapabilities(int viewId) {
    final out = calloc<Uint32>();
    try {
      _check(_getCapabilities(viewId, out), 'getCapabilities');
      return _capabilitySet(out.value);
    } finally {
      calloc.free(out);
    }
  }

  @override
  String getTitle(int viewId) {
    final buffer = calloc<Uint8>(512);
    try {
      _check(_getTitle(viewId, buffer, 512), 'getTitle');
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buffer);
    }
  }

  @override
  Offset getOffset(int viewId) {
    final out = calloc<_Offset>();
    try {
      _check(_getOffset(viewId, out), 'getOffset');
      return Offset(out.ref.x.toDouble(), out.ref.y.toDouble());
    } finally {
      calloc.free(out);
    }
  }

  void _emit(FiloWindowEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _forget(int viewId) {
    final record = _windows.remove(viewId);
    record?.observer.close();
  }
}

class _WindowRecord {
  _WindowRecord({required this.observer, required this.positioner});

  final _Observer observer;
  FiloPositioner positioner;
}

/// Keeps the Dart callbacks alive for the lifetime of one window.
class _Observer {
  _Observer(FiloNativeBackend backend, int viewId)
    : _onConfigure = NativeCallable<Void Function(Int32, Int32)>.isolateLocal((
        int width,
        int height,
      ) {
        backend._emit(
          FiloWindowStateChanged(viewId, contentSize: Size(width.toDouble(), height.toDouble())),
        );
      }),
      _onState = NativeCallable<Void Function(Uint32)>.isolateLocal((int bits) {
        backend._emit(FiloWindowStateChanged(viewId, toplevelState: _stateSet(bits)));
      }),
      _onCapabilities = NativeCallable<Void Function(Uint32)>.isolateLocal((int bits) {
        backend._emit(FiloWindowStateChanged(viewId, wmCapabilities: _capabilitySet(bits)));
      }),
      _onTitle = NativeCallable<Void Function(Pointer<Utf8>)>.isolateLocal((Pointer<Utf8> title) {
        backend._emit(FiloWindowStateChanged(viewId, title: title.toDartString()));
      }),
      _onMoved = NativeCallable<Void Function(Int32, Int32)>.isolateLocal((int x, int y) {
        backend._emit(
          FiloWindowStateChanged(viewId, offsetFromParent: Offset(x.toDouble(), y.toDouble())),
        );
      }),
      _onClose = NativeCallable<Void Function()>.isolateLocal(() {
        backend._emit(FiloWindowCloseRequested(viewId));
      }),
      _onDestroy = NativeCallable<Void Function()>.isolateLocal(() {
        backend._emit(FiloWindowDestroyed(viewId));
        // The native callback is still on the stack; close the callables after
        // it returns.
        scheduleMicrotask(() => backend._forget(viewId));
      });

  final NativeCallable<Void Function(Int32, Int32)> _onConfigure;
  final NativeCallable<Void Function(Uint32)> _onState;
  final NativeCallable<Void Function(Uint32)> _onCapabilities;
  final NativeCallable<Void Function(Pointer<Utf8>)> _onTitle;
  final NativeCallable<Void Function(Int32, Int32)> _onMoved;
  final NativeCallable<Void Function()> _onClose;
  final NativeCallable<Void Function()> _onDestroy;

  void close() {
    _onConfigure.close();
    _onState.close();
    _onCapabilities.close();
    _onTitle.close();
    _onMoved.close();
    _onClose.close();
    _onDestroy.close();
  }
}

//------------------------------------------------------------------------------
// Conversion helpers
//------------------------------------------------------------------------------

void _writePositioner(_Positioner out, FiloPositioner? positioner) {
  final source = positioner ?? _defaultPositioner(null);
  out.size.width = _atLeastOne(source.size.width);
  out.size.height = _atLeastOne(source.size.height);
  out.anchorRect.x = source.anchorRect.x;
  out.anchorRect.y = source.anchorRect.y;
  out.anchorRect.width = source.anchorRect.width;
  out.anchorRect.height = source.anchorRect.height;
  out.anchor = source.anchor?.index ?? 0;
  out.gravity = source.gravity?.index ?? 0;
  out.constraintAdjustment = source.constrainsAdjustments?.value ?? 0;
  out.offset.x = source.offset?.x ?? 0;
  out.offset.y = source.offset?.y ?? 0;
}

FiloPositioner _defaultPositioner(Size? size) {
  return FiloPositioner(
    size: FiloSize(_atLeastOne(size?.width.round() ?? 1), _atLeastOne(size?.height.round() ?? 1)),
    anchorRect: FiloRect(x: 0, y: 0, width: 1, height: 1),
  );
}

FiloPositionerConstrainsAdjustmentsFlags _constraintAdjustment(
  WindowPositionerConstraintAdjustment adjustment,
) {
  var value = 0;
  if (adjustment.slideX) value |= 1;
  if (adjustment.slideY) value |= 2;
  if (adjustment.flipX) value |= 4;
  if (adjustment.flipY) value |= 8;
  if (adjustment.resizeX) value |= 16;
  if (adjustment.resizeY) value |= 32;
  return FiloPositionerConstrainsAdjustmentsFlags(value);
}

Set<FiloToplevelState> _stateSet(int bits) {
  final result = <FiloToplevelState>{};
  for (var i = 0; i < FiloToplevelState.values.length; i++) {
    if ((bits & (1 << i)) != 0) result.add(FiloToplevelState.values[i]);
  }
  return result;
}

Set<FiloToplevelWMCapabilities> _capabilitySet(int bits) {
  final result = <FiloToplevelWMCapabilities>{};
  for (var i = 0; i < FiloToplevelWMCapabilities.values.length; i++) {
    if ((bits & (1 << i)) != 0) result.add(FiloToplevelWMCapabilities.values[i]);
  }
  return result;
}

int _dimension(double? value) => _constraint(value);

int _constraint(double? value) {
  if (value == null || !value.isFinite || value <= 0) return 0;
  return _atMost(value.round());
}

int _atLeastOne(int value) {
  if (value < 1) return 1;
  return _atMost(value);
}

int _atMost(int value) {
  if (value > 16384) return 16384;
  return value;
}

void _check(int status, String operation) {
  if (status == 0) return;
  final reason = switch (status) {
    1 => 'invalid argument',
    2 => 'unknown view',
    3 => 'unsupported',
    4 => 'backend failure',
    _ => 'status $status',
  };
  throw FiloWindowingException('$operation failed: $reason');
}
