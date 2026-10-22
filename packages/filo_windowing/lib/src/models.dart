// ignore_for_file: unused_field

import 'dart:ui' show Offset, Size;

import 'package:flutter/rendering.dart' show BoxConstraints;

import 'positioner.dart';

/// The kind of native window a controller owns.
enum FiloWindowKind { toplevel, popup }


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

  FiloRect({required this.x, required this.y, required this.width, required this.height});

  FiloRect.size(this.x, this.y, FiloSize size) : width = size.width, height = size.height;
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
  });

  /// The xdg-shell role to create.
  final FiloWindowKind kind;

  /// Preferred content size. Null or zero means "size to content".
  final Size? size;

  /// Size constraints, or null for unconstrained.
  final BoxConstraints? constraints;

  /// Whether the user may resize the window.
  final bool resizable;

  /// Whether the window should track its content size.
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
  final Set<FiloToplevelState> toplevelState;
  final Set<FiloToplevelWMCapabilities> wmCapabilities;
  final Offset offsetFromParent;
  final String? title;
}

/// An event the backend delivers for a window.
sealed class FiloWindowEvent {
  const FiloWindowEvent(this.viewId);

  final int viewId;
}

/// The compositor or user asked the window to close.
///
/// The window is still alive; the controller's delegate decides whether to
/// destroy it.
final class FiloWindowCloseRequested extends FiloWindowEvent {
  const FiloWindowCloseRequested(super.viewId);
}

/// The native window and its Flutter view are gone.
final class FiloWindowDestroyed extends FiloWindowEvent {
  const FiloWindowDestroyed(super.viewId);
}

/// Some window state changed. Fields that are null did not change.
final class FiloWindowStateChanged extends FiloWindowEvent {
  const FiloWindowStateChanged(
    super.viewId, {
    this.title,
    this.toplevelState,
    this.wmCapabilities,
    this.contentSize,
    this.offsetFromParent,
  });

  final String? title;
  final Set<FiloToplevelState>? toplevelState;
  final Set<FiloToplevelWMCapabilities>? wmCapabilities;
  final Size? contentSize;
  final Offset? offsetFromParent;
}

/// A backend operation failed.
class FiloWindowingException implements Exception {
  const FiloWindowingException(this.message);

  final String message;

  @override
  String toString() => 'FiloWindowingException: $message';
}
