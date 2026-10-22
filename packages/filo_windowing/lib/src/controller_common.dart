import 'dart:ffi' as ffi;

import 'package:filo_windowing/src/_window_observer.dart';

abstract interface class FiloWindowControllerCommon {
  ffi.Pointer<ffi.Void> get handle;

  FiloWindowObserver observer;

  FiloWindowControllerCommon._(this.observer);
}
