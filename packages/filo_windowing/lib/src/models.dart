// ignore_for_file: unused_field

import 'dart:ui' show Offset, Size;

import 'package:flutter/rendering.dart' show BoxConstraints;

import 'positioner.dart';

/// The kind of native window a controller owns.
enum FiloWindowKind { toplevel, popup, layer }

enum FiloToplevelState {
  /// The surface is maximized.
  maximized(1),

  /// The surface is fullscreen.
  fullscreen(2),

  /// The surface is being resized.
  resizing(3),

  /// Client window decorations should be painted as if the window is active.
  /// Do not assume this means that the window actually has keyboard or pointer focus.
  activated(4),

  /// The window is currently in a tiled layout and the left edge
  /// is considered to be adjacent to another part of the tiling grid.
  ///
  /// The client should draw without shadow or other decoration outside
  /// of the window geometry on the left edge.
  tiledLeft(5),

  /// The window is currently in a tiled layout and the left edge
  /// is considered to be adjacent to another part of the tiling grid.
  ///
  /// The client should draw without shadow or other decoration outside
  /// of the window geometry on the right edge.
  tiledRight(6),

  /// The window is currently in a tiled layout and the left edge
  /// is considered to be adjacent to another part of the tiling grid.
  ///
  /// The client should draw without shadow or other decoration outside
  /// of the window geometry on the top edge.
  tiledTop(7),

  /// The window is currently in a tiled layout and the left edge
  /// is considered to be adjacent to another part of the tiling grid.
  ///
  /// The client should draw without shadow or other decoration outside
  /// of the window geometry on the bottom edge.
  tiledBottom(8),

  /// The surface is currently not ordinarily being repainted.
  ///
  /// For example because its content is occluded by another window,
  /// or its outputs are switched off due to screen locking.
  supended(9),

  /// The left edge of the window is currently constrained, meaning
  /// it shouldn't attempt to resize from that edge. It can for example
  /// mean it's tiled next to a monitor edge on the constrained side of the window.
  constrainedLeft(10),

  /// The right edge of the window is currently constrained, meaning
  /// it shouldn't attempt to resize from that edge. It can for example
  /// mean it's tiled next to a monitor edge on the constrained side of the window.
  constrainedRight(11),

  /// The top edge of the window is currently constrained, meaning
  /// it shouldn't attempt to resize from that edge. It can for example
  /// mean it's tiled next to a monitor edge on the constrained side of the window.
  constrainedTop(12),

  /// The bottom edge of the window is currently constrained, meaning
  /// it shouldn't attempt to resize from that edge. It can for example
  /// mean it's tiled next to a monitor edge on the constrained side of the window.
  constrainedBottom(13);

  final int _value;

  const FiloToplevelState(this._value);

  static FiloToplevelState fromInt(int value) {
    return FiloToplevelState.values[value - 1];
  }
}

enum FiloToplevelWMCapabilities {
  /// showWindowMenu is available
  windowMenu(1),

  /// set maximized and unset_maximized are available
  maximize(2),

  /// set fullscreen and unset_fullscreen are available
  fullscreen(3),

  /// set minimized is available
  minimize(4);

  final int _value;

  const FiloToplevelWMCapabilities(this._value);

  static FiloToplevelWMCapabilities fromInt(int value) {
    return FiloToplevelWMCapabilities.values[value - 1];
  }
}

class FiloSize {
  int width;
  int height;

  FiloSize(this.width, this.height);
}

class FiloOffset {
  int x;
  int y;

  FiloOffset(this.x, this.y);
}

class FiloRect {
  int x;
  int y;
  int width;
  int height;

  FiloRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  FiloRect.size(this.x, this.y, FiloSize size)
    : width = size.width,
      height = size.height;
}

/// The z depth of a wlr-layer-shell surface, bottom-most first.
enum FiloLayer {
  background(0),
  bottom(1),
  top(2),
  overlay(3);

  final int value;

  const FiloLayer(this.value);
}

/// A bitmask of the output edges a layer surface is anchored to.
class FiloLayerAnchors {
  final int value;

  const FiloLayerAnchors(this.value);

  FiloLayerAnchors operator |(FiloLayerAnchors other) {
    return FiloLayerAnchors(value | other.value);
  }

  bool get isTop => (value & 1) != 0;
  bool get isBottom => (value & 2) != 0;
  bool get isLeft => (value & 4) != 0;
  bool get isRight => (value & 8) != 0;

  static const none = FiloLayerAnchors(0);
  static const top = FiloLayerAnchors(1);
  static const bottom = FiloLayerAnchors(2);
  static const left = FiloLayerAnchors(4);
  static const right = FiloLayerAnchors(8);

  /// Anchored to all four edges: the surface fills the output.
  static const all = FiloLayerAnchors(1 | 2 | 4 | 8);
}

/// How a layer surface receives keyboard events.
enum FiloLayerKeyboardInteractivity {
  none(0),
  exclusive(1),

  /// `on_demand` requires zwlr-layer-shell version 4. Older compositors reject
  /// it and the backend reports an invalid argument.
  onDemand(2);

  final int value;

  const FiloLayerKeyboardInteractivity(this.value);
}

/// Margins from the anchored output edges, in logical pixels.
class FiloInsets {
  final int top;
  final int right;
  final int bottom;
  final int left;

  const FiloInsets({
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    this.left = 0,
  });

  const FiloInsets.all(int value)
    : top = value,
      right = value,
      bottom = value,
      left = value;

  static const zero = FiloInsets();
}

/// The wlr-layer-shell properties of a [FiloWindowKind.layer] window.
///
/// These are the values passed at creation and updated through
/// [FiloWindowingBackend.updateLayerSurface].
class FiloLayerSurface {
  const FiloLayerSurface({
    this.layer = FiloLayer.top,
    this.anchors = FiloLayerAnchors.none,
    this.exclusiveZone = 0,
    this.keyboardInteractivity = FiloLayerKeyboardInteractivity.none,
    this.margin = FiloInsets.zero,
    this.output = -1,
    this.namespace = 'filo',
    this.acceptsInput = true,
  });

  /// Which layer to render the surface in.
  final FiloLayer layer;

  /// Output edges to anchor to.
  final FiloLayerAnchors anchors;

  /// Space to reserve at the anchored edge; 0 avoids other exclusive zones,
  /// -1 ignores them.
  final int exclusiveZone;

  /// Whether the surface can receive keyboard focus.
  final FiloLayerKeyboardInteractivity keyboardInteractivity;

  /// Distance from the anchored edges.
  final FiloInsets margin;

  /// Index into the connection's outputs in registry order, or -1 to let the
  /// compositor choose.
  final int output;

  /// Non-empty role namespace, e.g. `filo-bar`.
  final String namespace;

  /// Whether the surface receives pointer and touch input. Set to false for a
  /// wallpaper or an overlay that should not intercept the desktop.
  final bool acceptsInput;

  FiloLayerSurface copyWith({
    FiloLayer? layer,
    FiloLayerAnchors? anchors,
    int? exclusiveZone,
    FiloLayerKeyboardInteractivity? keyboardInteractivity,
    FiloInsets? margin,
    int? output,
    String? namespace,
    bool? acceptsInput,
  }) {
    return FiloLayerSurface(
      layer: layer ?? this.layer,
      anchors: anchors ?? this.anchors,
      exclusiveZone: exclusiveZone ?? this.exclusiveZone,
      keyboardInteractivity:
          keyboardInteractivity ?? this.keyboardInteractivity,
      margin: margin ?? this.margin,
      output: output ?? this.output,
      namespace: namespace ?? this.namespace,
      acceptsInput: acceptsInput ?? this.acceptsInput,
    );
  }
}

enum FiloPositionerAnchor {
  none(0),
  top(1),
  bottom(2),
  left(3),
  right(4),
  topLeft(5),
  bottomLeft(6),
  topRight(7),
  bottomRight(8);

  final int _value;

  const FiloPositionerAnchor(this._value);

  static FiloPositionerAnchor fromInt(int value) {
    return FiloPositionerAnchor.values[value - 1];
  }
}

enum FiloPositionerGravity {
  none(0),
  top(1),
  bottom(2),
  left(3),
  right(4),
  topLeft(5),
  bottomLeft(6),
  topRight(7),
  bottomRight(8);

  final int _value;

  const FiloPositionerGravity(this._value);

  static FiloPositionerGravity fromInt(int value) {
    return FiloPositionerGravity.values[value - 1];
  }
}

class FiloPositionerConstrainsAdjustmentsFlags {
  final int value;

  const FiloPositionerConstrainsAdjustmentsFlags(this.value);

  FiloPositionerConstrainsAdjustmentsFlags operator |(
    FiloPositionerConstrainsAdjustmentsFlags other,
  ) {
    return FiloPositionerConstrainsAdjustmentsFlags(value | other.value);
  }

  /// Don't move the child surface when constrained
  static const none = FiloPositionerConstrainsAdjustmentsFlags(0);

  /// Move along the x axis until unconstrained
  static const slideX = FiloPositionerConstrainsAdjustmentsFlags(1);

  /// Move along the y axis until unconstrained
  static const slideY = FiloPositionerConstrainsAdjustmentsFlags(2);

  /// Invert the anchor and gravity on the x axis
  static const flipX = FiloPositionerConstrainsAdjustmentsFlags(4);

  /// Invert the anchor and gravity on the y axis
  static const flipY = FiloPositionerConstrainsAdjustmentsFlags(8);

  /// Horizontally resize the surface
  static const resizeX = FiloPositionerConstrainsAdjustmentsFlags(16);

  /// Vertically resize the surface
  static const resizeY = FiloPositionerConstrainsAdjustmentsFlags(32);
}

/// One `createWindow` request.
class FiloWindowRequest {
  const FiloWindowRequest({
    required this.kind,
    this.size,
    this.constraints,
    this.resizable = true,
    this.sizedToContent = false,
    this.modal = false,
    this.decorated = true,
    this.title,
    this.parentViewId = -1,
    this.preferredViewId = -1,
    this.positioner,
    this.layer,
  });

  /// The xdg-shell role to create.
  final FiloWindowKind kind;

  /// Preferred content size, or null to size the window to its content.
  ///
  /// A zero dimension is valid for a layer surface anchored to both opposite
  /// edges on that axis; the compositor then chooses the size.
  final Size? size;

  /// Size constraints, or null for unconstrained.
  final BoxConstraints? constraints;

  /// Whether the user may resize the window.
  final bool resizable;

  /// Whether the backend should derive the window size from its rendered
  /// content. Non-resizable windows keep tracking later content changes;
  /// resizable windows only use their content for the initial size.
  final bool sizedToContent;

  /// Whether a dialog is modal to [parentViewId].
  final bool modal;

  /// Whether the window has decorations.
  final bool decorated;

  /// Initial title, if any.
  final String? title;

  /// Parent view id, or -1 for none. 0 is the implicit view.
  final int parentViewId;

  /// Suggested view id to adopt, or -1 for no preference.
  final int preferredViewId;

  /// Popup positioner, including its anchor rect and size.
  final FiloPositioner? positioner;

  /// wlr-layer-shell properties. Required when [kind] is
  /// [FiloWindowKind.layer].
  final FiloLayerSurface? layer;
}

/// The initial state of a created window.
class FiloWindowHandle {
  const FiloWindowHandle({
    required this.viewId,
    required this.contentSize,
    required this.toplevelState,
    required this.wmCapabilities,
    required this.offsetFromParent,
    this.title,
  });

  final int viewId;
  final Size contentSize;

  /// The `xdg_toplevel.state` bitmask, matching the native ABI.
  final int toplevelState;

  /// The `xdg_toplevel.wm_capabilities` bitmask, matching the native ABI.
  final int wmCapabilities;

  final Offset offsetFromParent;
  final String? title;
}

/// Bit positions for [FiloToplevelState] in the native state bitmask.
extension FiloToplevelStateMask on FiloToplevelState {
  int get mask => 1 << index;
}

/// Bit positions for [FiloToplevelWMCapabilities] in the native bitmask.
extension FiloToplevelWMCapabilitiesMask on FiloToplevelWMCapabilities {
  int get mask => 1 << index;
}

/// A backend operation failed.
class FiloWindowingException implements Exception {
  const FiloWindowingException(this.message);

  final String message;

  @override
  String toString() => 'FiloWindowingException: $message';
}
