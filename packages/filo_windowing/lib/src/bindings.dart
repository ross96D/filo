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

final class _LayerSurface extends Struct {
  @Int32()
  external int layer;

  @Uint32()
  external int anchor;

  @Int32()
  external int exclusiveZone;

  @Int32()
  external int keyboardInteractivity;

  @Int32()
  external int marginTop;

  @Int32()
  external int marginRight;

  @Int32()
  external int marginBottom;

  @Int32()
  external int marginLeft;

  @Int32()
  external int output;

  external Pointer<Utf8> namespace;

  @Uint8()
  external int acceptsInput;
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

  external _LayerSurface layerSurface;
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
external int _create(
  Pointer<_WindowRequest> request,
  Pointer<_WindowHandle> out,
);

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

@Native<Int32 Function(Int64, Int32, Int32, Int32, Int32)>(
  symbol: 'filo_window_set_constraints',
)
external int _setConstraints(
  int viewId,
  int minWidth,
  int minHeight,
  int maxWidth,
  int maxHeight,
);

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
external int _updatePosition(
  int viewId,
  Pointer<_Rect> anchor,
  Pointer<_Positioner> positioner,
);

@Native<Int32 Function(Int64, Pointer<_LayerSurface>)>(
  symbol: 'filo_window_update_layer_surface',
)
external int _updateLayerSurface(int viewId, Pointer<_LayerSurface> layer);

//------------------------------------------------------------------------------
// Native backend
//------------------------------------------------------------------------------

/// The [FiloWindowingBackend] backed by the `filo_window_*` symbols the Filo
/// embedder exports from the process image.
class FiloNativeBackend implements FiloWindowingBackend {
  final Map<int, _WindowRecord> _windows = <int, _WindowRecord>{};

  @override
  FiloWindowHandle createWindow(FiloWindowRequest request) {
    if (request.kind == FiloWindowKind.layer && request.layer == null) {
      throw const FiloWindowingException(
        'createWindow failed: layer windows need a layer surface',
      );
    }
    if (request.layer != null && request.layer!.namespace.isEmpty) {
      throw const FiloWindowingException(
        'createWindow failed: the layer namespace cannot be empty',
      );
    }
    final requestPtr = calloc<_WindowRequest>();
    final handlePtr = calloc<_WindowHandle>();
    final titlePtr = request.title == null
        ? nullptr
        : request.title!.toNativeUtf8();
    final namespacePtr = request.layer == null
        ? nullptr
        : request.layer!.namespace.toNativeUtf8();
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
      _writeLayerSurface(ref.layerSurface, request.layer, namespacePtr);

      _check(_create(requestPtr, handlePtr), 'createWindow');

      final viewId = handlePtr.ref.viewId;
      _windows[viewId] = _WindowRecord(
        positioner: request.positioner ?? _defaultPositioner(request.size),
      );

      return FiloWindowHandle(
        viewId: viewId,
        contentSize: Size(
          handlePtr.ref.contentSize.width.toDouble(),
          handlePtr.ref.contentSize.height.toDouble(),
        ),
        title: handlePtr.ref.title == nullptr
            ? null
            : handlePtr.ref.title.toDartString(),
        toplevelState: handlePtr.ref.toplevelState,
        wmCapabilities: handlePtr.ref.wmCapabilities,
        offsetFromParent: Offset(
          handlePtr.ref.offsetFromParent.x.toDouble(),
          handlePtr.ref.offsetFromParent.y.toDouble(),
        ),
      );
    } finally {
      if (titlePtr != nullptr) malloc.free(titlePtr);
      if (namespacePtr != nullptr) malloc.free(namespacePtr);
      calloc.free(requestPtr);
      calloc.free(handlePtr);
    }
  }

  @override
  void observe(int viewId, FiloWindowObserver observer) {
    final record = _windows[viewId];
    if (record == null) {
      throw const FiloWindowingException('observe failed: unknown view');
    }

    final callbacks = _Observer(this, viewId, observer);
    try {
      _check(
        _observe(
          viewId,
          callbacks._onConfigure.nativeFunction,
          callbacks._onState.nativeFunction,
          callbacks._onCapabilities.nativeFunction,
          callbacks._onTitle.nativeFunction,
          callbacks._onMoved.nativeFunction,
          callbacks._onClose.nativeFunction,
          callbacks._onDestroy.nativeFunction,
        ),
        'observe',
      );
    } catch (_) {
      callbacks.close();
      rethrow;
    }

    record.observer?.close();
    record.observer = callbacks;
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
    _check(
      _setSize(viewId, _dimension(size.width), _dimension(size.height)),
      'setSize',
    );
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
  void updatePosition(
    int viewId, {
    Rect? anchorRect,
    WindowPositioner? positioner,
  }) {
    final record = _windows[viewId];
    if (record == null) return;

    var current = record.positioner;
    if (positioner != null) {
      current = current.copyWith(
        anchor: FiloPositionerAnchor.values[positioner.parentAnchor.index],
        gravity: FiloPositionerGravity.values[positioner.childAnchor.index],
        constrainsAdjustments: _constraintAdjustment(
          positioner.constraintAdjustment,
        ),
        offset: FiloOffset(
          positioner.offset.dx.round(),
          positioner.offset.dy.round(),
        ),
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
  void updateLayerSurface(int viewId, FiloLayerSurface surface) {
    final ptr = calloc<_LayerSurface>();
    final namespacePtr = surface.namespace.toNativeUtf8();
    try {
      _writeLayerSurface(ptr.ref, surface, namespacePtr);
      _check(_updateLayerSurface(viewId, ptr), 'updateLayerSurface');
    } finally {
      malloc.free(namespacePtr);
      calloc.free(ptr);
    }
  }

  void _forget(int viewId) {
    final record = _windows.remove(viewId);
    record?.observer?.close();
  }
}

class _WindowRecord {
  _WindowRecord({required this.positioner});

  FiloPositioner positioner;
  _Observer? observer;
}

/// Keeps the Dart callbacks alive for the lifetime of one window.
class _Observer {
  _Observer(FiloNativeBackend backend, int viewId, FiloWindowObserver observer)
    : _onConfigure = NativeCallable<Void Function(Int32, Int32)>.isolateLocal((
        int width,
        int height,
      ) {
        observer.onConfigure?.call(Size(width.toDouble(), height.toDouble()));
      }),
      _onState = NativeCallable<Void Function(Uint32)>.isolateLocal((int bits) {
        observer.onStateChanged?.call(bits);
      }),
      _onCapabilities = NativeCallable<Void Function(Uint32)>.isolateLocal((
        int bits,
      ) {
        observer.onCapabilitiesChanged?.call(bits);
      }),
      _onTitle = NativeCallable<Void Function(Pointer<Utf8>)>.isolateLocal((
        Pointer<Utf8> title,
      ) {
        observer.onTitleChanged?.call(title.toDartString());
      }),
      _onMoved = NativeCallable<Void Function(Int32, Int32)>.isolateLocal((
        int x,
        int y,
      ) {
        observer.onMoved?.call(Offset(x.toDouble(), y.toDouble()));
      }),
      _onClose = NativeCallable<Void Function()>.isolateLocal(() {
        observer.onClose?.call();
      }),
      _onDestroy = NativeCallable<Void Function()>.isolateLocal(() {
        try {
          observer.onDestroy?.call();
        } finally {
          // The native callback is still on the stack; release the callables
          // after it returns.
          scheduleMicrotask(() => backend._forget(viewId));
        }
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

void _writeLayerSurface(
  _LayerSurface out,
  FiloLayerSurface? layer,
  Pointer<Utf8> namespace,
) {
  if (layer == null) {
    out.layer = 0;
    out.anchor = 0;
    out.exclusiveZone = 0;
    out.keyboardInteractivity = 0;
    out.marginTop = 0;
    out.marginRight = 0;
    out.marginBottom = 0;
    out.marginLeft = 0;
    out.output = -1;
    out.namespace = nullptr;
    out.acceptsInput = 1;
    return;
  }

  out.layer = layer.layer.value;
  out.anchor = layer.anchors.value;
  out.exclusiveZone = layer.exclusiveZone;
  out.keyboardInteractivity = layer.keyboardInteractivity.value;
  out.marginTop = layer.margin.top;
  out.marginRight = layer.margin.right;
  out.marginBottom = layer.margin.bottom;
  out.marginLeft = layer.margin.left;
  out.output = layer.output;
  out.namespace = namespace;
  out.acceptsInput = layer.acceptsInput ? 1 : 0;
}

FiloPositioner _defaultPositioner(Size? size) {
  return FiloPositioner(
    size: FiloSize(
      _atLeastOne(size?.width.round() ?? 1),
      _atLeastOne(size?.height.round() ?? 1),
    ),
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
