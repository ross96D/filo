import 'dart:ui' show FlutterView;

import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/widgets.dart';

import 'backend.dart';
import 'bindings.dart';
import 'owner.dart';

/// Installs a [FiloWindowingOwner] for the Filo embedder.
///
/// This also enables Flutter's experimental windowing API at runtime. The
/// stable Flutter tool does not expose `--enable-windowing`, so a custom
/// embedder that owns the platform can turn the flag on directly.
///
/// Call this before creating any windowing widgets:
///
/// ```dart
/// void main() {
///   installFiloWindowing();
///   runWidget(...);
/// }
/// ```
///
/// [backend] defaults to [FiloNativeBackend], which talks to the
/// `filo_window_*` symbols the embedder exports. Pass a fake backend in tests.
FiloWindowingOwner installFiloWindowing({
  FiloWindowingBackend? backend,
  bool reuseImplicitView = true,
  FlutterView Function(int viewId)? viewResolver,
}) {
  // Initialize the binding while windowing is still disabled, then enable it.
  // Enabling first makes `WidgetsBinding.initInstances` create Flutter's
  // default platform owner, which we neither want nor can satisfy here.
  WidgetsFlutterBinding.ensureInitialized();
  isWindowingEnabled = true;

  final owner = FiloWindowingOwner(
    backend: backend ?? FiloNativeBackend(),
    reuseImplicitView: reuseImplicitView,
    viewResolver: viewResolver,
  );

  WidgetsBinding.instance.windowingOwner = owner;
  return owner;
}
