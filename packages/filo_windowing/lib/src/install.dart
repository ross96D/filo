import 'dart:ui' show FlutterView;

import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/widgets.dart';

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
///   installFiloWindowing(backend: myBackend);
///   runWidget(...);
/// }
/// ```
FiloWindowingOwner installFiloWindowing({
  bool reuseImplicitView = true,
  FlutterView Function(int viewId)? viewResolver,
}) {
  isWindowingEnabled = true;
  WidgetsFlutterBinding.ensureInitialized();

  final owner = FiloWindowingOwner(viewResolver: viewResolver);

  WidgetsBinding.instance.windowingOwner = owner;
  return owner;
}
