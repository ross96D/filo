import 'dart:ui' show Display, Offset, Rect, Size;
import 'dart:ffi' as ffi;

import 'package:filo_windowing/src/_window_observer.dart';
import 'package:flutter/rendering.dart' show BoxConstraints;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';

import 'controller_common.dart';

/// A regular top-level window backed by the Filo embedder.
class FiloRegularWindowController extends RegularWindowController
    implements FiloWindowControllerCommon {
  @override
  ffi.Pointer<ffi.Void> get handle => throw UnimplementedError();

  @override
  late FiloWindowObserver observer = throw UnimplementedError();

  /// The delegate that receives this window's lifecycle callbacks.
  // final RegularWindowControllerDelegate delegate;
  FiloRegularWindowController({
    required RegularWindowControllerDelegate delegate,
    Size? size,
    BoxConstraints? constraints,
    String? title,
    required bool resizable,
  }) : super.empty();

  @override
  void activate() {
    // TODO: implement activate
  }

  @override
  // TODO: implement contentSize
  Size get contentSize => throw UnimplementedError();

  @override
  void destroy() {
    // TODO: implement destroy
  }

  @override
  // TODO: implement isActivated
  bool get isActivated => throw UnimplementedError();

  @override
  // TODO: implement isFullscreen
  bool get isFullscreen => throw UnimplementedError();

  @override
  // TODO: implement isMaximized
  bool get isMaximized => throw UnimplementedError();

  @override
  // TODO: implement isMinimized
  bool get isMinimized => throw UnimplementedError();

  @override
  void setConstraints(BoxConstraints constraints) {
    // TODO: implement setConstraints
  }

  @override
  void setFullscreen(bool fullscreen, {Display? display}) {
    // TODO: implement setFullscreen
  }

  @override
  void setMaximized(bool maximized) {
    // TODO: implement setMaximized
  }

  @override
  void setMinimized(bool minimized) {
    // TODO: implement setMinimized
  }

  @override
  void setSize(Size size) {
    // TODO: implement setSize
  }

  @override
  void setTitle(String title) {
    // TODO: implement setTitle
  }

  @override
  // TODO: implement title
  String get title => throw UnimplementedError();
}

/// A dialog window backed by the Filo embedder.
class FiloDialogWindowController extends DialogWindowController
    implements FiloWindowControllerCommon {
  final DialogWindowControllerDelegate delegate;

  @override
  ffi.Pointer<ffi.Void> get handle => throw UnimplementedError();

  @override
  late FiloWindowObserver observer = throw UnimplementedError();

  @override
  final BaseWindowController? parent;

  FiloDialogWindowController({
    required this.delegate,
    this.parent,
    Size? size,
    BoxConstraints? constraints,
    required bool resizable,
    String? title,
  }) : super.empty();

  @override
  void activate() {}

  @override
  // TODO: implement contentSize
  Size get contentSize => throw UnimplementedError();

  @override
  void destroy() {
    // TODO: implement destroy
  }

  @override
  // TODO: implement isActivated
  bool get isActivated => throw UnimplementedError();

  @override
  // TODO: implement isMinimized
  bool get isMinimized => throw UnimplementedError();

  @override
  void setConstraints(BoxConstraints constraints) {
    // TODO: implement setConstraints
  }

  @override
  void setMinimized(bool minimized) {
    // TODO: implement setMinimized
  }

  @override
  void setSize(Size size) {
    // TODO: implement setSize
  }

  @override
  void setTitle(String title) {
    // TODO: implement setTitle
  }

  @override
  // TODO: implement title
  String get title => throw UnimplementedError();
}

/// A tooltip window backed by the Filo embedder.
class FiloTooltipWindowController extends TooltipWindowController
    implements FiloWindowControllerCommon {
  final TooltipWindowControllerDelegate delegate;

  @override
  ffi.Pointer<ffi.Void> get handle => throw UnimplementedError();

  @override
  late FiloWindowObserver observer = throw UnimplementedError();

  @override
  final BaseWindowController parent;

  FiloTooltipWindowController({
    required this.delegate,
    required this.parent,
    required BoxConstraints constraints,
    required Rect anchorRect,
    required WindowPositioner positioner,
  }) : super.empty();

  @override
  // TODO: implement contentSize
  Size get contentSize => throw UnimplementedError();

  @override
  void destroy() {
    // TODO: implement destroy
  }

  @override
  void setConstraints(BoxConstraints constraints) {
    // TODO: implement setConstraints
  }

  @override
  void updatePosition({Rect? anchorRect, WindowPositioner? positioner}) {
    // TODO: implement updatePosition
  }
}

/// A popup window backed by the Filo embedder.
class FiloPopupWindowController extends PopupWindowController
    implements FiloWindowControllerCommon {
  final PopupWindowControllerDelegate delegate;

  @override
  ffi.Pointer<ffi.Void> get handle => throw UnimplementedError();

  @override
  late FiloWindowObserver observer = throw UnimplementedError();

  @override
  final BaseWindowController parent;

  FiloPopupWindowController({
    required this.delegate,
    required this.parent,
    required BoxConstraints constraints,
    required Rect anchorRect,
    required WindowPositioner positioner,
  }) : super.empty();

  @override
  // TODO: implement contentSize
  Size get contentSize => throw UnimplementedError();

  @override
  void destroy() {
    // TODO: implement destroy
  }

  @override
  // TODO: implement offsetFromParent
  Offset get offsetFromParent => throw UnimplementedError();

  @override
  void setConstraints(BoxConstraints constraints) {
    // TODO: implement setConstraints
  }

  @override
  void updatePosition({Rect? anchorRect, WindowPositioner? positioner}) {
    // TODO: implement updatePosition
  }
}

/// A satellite window backed by the Filo embedder.
class FiloSatelliteWindowController extends SatelliteWindowController
    implements FiloWindowControllerCommon {
  final SatelliteWindowControllerDelegate delegate;

  @override
  ffi.Pointer<ffi.Void> get handle => throw UnimplementedError();

  @override
  late FiloWindowObserver observer = throw UnimplementedError();

  @override
  final BaseWindowController parent;

  FiloSatelliteWindowController({
    required this.delegate,
    required this.parent,
    required WindowPositioner initialPositioner,
    Rect? initialAnchorRect,
    Size? size,
    BoxConstraints? constraints,
    required bool resizable,
    String? title,
  }) : super.empty();

  @override
  void activate() {
    // TODO: implement activate
  }

  @override
  // TODO: implement contentSize
  Size get contentSize => throw UnimplementedError();

  @override
  void destroy() {
    // TODO: implement destroy
  }

  @override
  // TODO: implement isActivated
  bool get isActivated => throw UnimplementedError();

  @override
  void setConstraints(BoxConstraints constraints) {
    // TODO: implement setConstraints
  }

  @override
  void setParent(BaseWindowController parent) {
    // TODO: implement setParent
  }

  @override
  void setSize(Size size) {
    // TODO: implement setSize
  }

  @override
  void setTitle(String title) {
    // TODO: implement setTitle
  }

  @override
  // TODO: implement title
  String get title => throw UnimplementedError();
}
