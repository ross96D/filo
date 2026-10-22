import 'dart:ffi' as ffi;
import 'package:flutter/foundation.dart';

class FiloWindowObserver {
  factory FiloWindowObserver(
    ffi.Pointer<ffi.Void> filoHandle, {
    VoidCallback? onConfigure,
    VoidCallback? onActive,
    VoidCallback? onClose,
    VoidCallback? onDestroy,
  }) {
    return ._internal();
  }

  FiloWindowObserver._internal();
}
