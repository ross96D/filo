/// Flutter windowing support for the Filo custom embedder.
///
/// This package implements Flutter's experimental `WindowingOwner` for an
/// embedder that exposes synchronous native window creation. It targets the
/// Flutter 3.47 windowing API (`RegularWindowController` and friends) and the
/// `filo_window_*` C ABI exported by the Filo embedder.
library;

export 'src/backend.dart';
export 'src/bindings.dart';
export 'src/controllers.dart';
export 'src/install.dart';
export 'src/models.dart';
export 'src/owner.dart';
export 'src/positioner.dart';
export 'src/widgets.dart';
