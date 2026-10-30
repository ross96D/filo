import 'dart:ffi';

/// A tiny native function built from `src/native_sum.c` by `hook/build.dart`.
///
/// The asset id is the package plus the `assetName` passed to
/// `CBuilder.library` in the build hook.
@Native<Int32 Function(Int32, Int32)>(
  assetId: 'package:native_sum/native_sum.dart',
)
external int native_sum(int a, int b);
