# filo

A Flutter embedder for Wayland, consumed as a Zig package. The embedder is
compiled into the host executable; there is no separate shared library or
installed artifact.

## Requirements

- Zig 0.17
- Wayland (`wayland-client`, a compositor with `xdg-shell`)
- `libxkbcommon`
- A Vulkan 1.1 driver
- A Flutter engine build (`libflutter_engine.so`), its ICU data and the
  application's `flutter_assets` at runtime

Layer windows additionally need a compositor that implements
`zwlr_layer_shell_v1` (wlroots-based compositors and most desktop shells). The
protocol is optional: without it, the regular, dialog, popup, and tooltip
windows still work and creating a layer window reports `unsupported`.

## Consuming

Add the package to the host's `build.zig.zon`:

```sh
zig fetch --save=filo git+https://github.com/ross96D/filo#master
```

The repository root is a small package wrapper that exposes the module from
`filo/`, so this Git URL works even though the embedder lives in a
subdirectory. A local checkout can still point at `filo/` directly:

```zon
.dependencies = .{
    .filo = .{ .path = "../filo" },
},
```

Then import the public module:

```zig
// build.zig
const filo = b.dependency("filo", .{
    .target = target,
    .optimize = optimize,
}).module("filo");

exe.root_module.addImport("filo", filo);

// The Dart `filo_windowing` package finds `filo_window_*` through
// `DynamicLibrary.executable()`, so the host's symbols must be exported.
exe.rdynamic = true;
```

```zig
// main.zig
const std = @import("std");
const filo = @import("filo");

pub fn main(init: std.process.Init) !void {
    const config = try filo.Config.fromEnv(init.environ_map);
    try filo.run(init.gpa, init.io, config);
}
```

`libc`, `wayland-client` and `xkbcommon` are linked by the module, so importing
it is enough.

## Configuration

`filo.Config` is the host-facing configuration:

| Field                     | Meaning                                                                  |
| ------------------------- | ------------------------------------------------------------------------ |
| `engine_lib`              | Path to `libflutter_engine.so`                                           |
| `icu_data`                | Path to `icudtl.dat`                                                     |
| `assets`                  | Path to the application's `flutter_assets` directory                     |
| `aot_lib`                 | Optional path to the AOT `libapp.so`; JIT when null                      |
| `force_impeller`          | Use Impeller instead of Skia (expected to fail with the compositor path) |
| `vulkan_validation`       | Enable the Vulkan validation layer when installed                        |
| `trace`                   | Print per-frame synchronization timings                                  |
| `bootstrap_layer`         | Bootstrap implicit view 0 as a layer instead of an xdg_toplevel          |
| `bootstrap_layer_surface` | Layer/anchors/margins/size/namespace for that surface (see below)        |
| `engine_args`             | Extra engine switches supplied by the host                               |
| `dart_entrypoint_args`    | Arguments for Dart's `main(List<String> args)`                           |

`Config.fromEnv` reads the development environment variables
`FILO_ENGINE_LIB`, `FILO_ICU_DATA`, `FILO_ASSETS`, `FILO_AOT_LIB`,
`FORCE_IMPELLER`, `FILO_VULKAN_VALIDATION`, `FILO_TRACE` and
`FILO_LAYER_ONLY`. A host with its own configuration can build a `Config`
directly.

`engine_args` is a host-facing field. The switches Flutter passes to a custom
device in `${engineOptions}` are currently ignored.

Command-line arguments are the Dart entrypoint arguments and arrive as
`main(List<String> args)`, flags included:

```sh
./zig-out/bin/app --dart-flag1 --dart-flag2=value positional
```

For `flutter run` through a custom device, use `FILO_DART_ENTRYPOINT_ARGS`
instead, with one argument per line. Flutter's custom-device API does not
forward `--dart-entrypoint-args`:

```sh
FILO_DART_ENTRYPOINT_ARGS=$'--dart-flag1\npositional' flutter run -d filo_wayland
```

`bootstrap_layer` it appears that the engine needs view 0's native surface before
its first frame. This settings makes the app create the first view as a wlr-layer-shell
instead of a xdg-toplevel.

The runtime copies the config strings, so the caller's buffers only need to
live until `Runtime.init` returns.

## Lifecycle

```zig
const runtime = try filo.Runtime.init(allocator, io, config);
defer runtime.deinit();
try runtime.run(); // blocks
```

- `init`, `run`, `deinit` and every `filo_window_*` call must happen on the same
  thread — the thread that owns the Wayland connection and the Vulkan device.
- `run` blocks until the loop stops: the framework asks to quit, the last view
  goes away, or `Runtime.stop` is called.
- `Runtime.stop` is safe from another thread. It posts a task through the
  engine's eventfd, so the loop wakes up and stops on its own thread.
- `deinit` frees the runtime; it is one-shot. Call it after `run` returns (or
  after a failed `init`).

## Dart windowing package

`packages/filo_windowing` keeps its existing loading contract: it looks up the
`filo_window_*` symbols in the process image. This is why the host executable
must be built with `rdynamic`/`--export-dynamic`. No `dlopen` or `libfilo.so`
is involved.

## Dart native assets

Flutter writes a `NativeAssetsManifest.json` into `flutter_assets` and copies
the libraries built by Dart build hooks into
`flutter_assets/native_assets/linux/`. The manifest stores only the file name,
for example `["absolute","libnative_sum.so"]`.

The engine resolves those entries with `dlopen`, and the call is made from
`libflutter_engine.so`, not from the host executable. This has two
consequences:

- a host rpath does not help
- the engine itself needs `$ORIGIN` in its `RUNPATH`

The Wayland runner template therefore lays out a Flutter-style debug bundle:

```text
build/wayland/<arch>/debug/bundle/
├── <appName>
├── lib/
│   ├── libflutter_engine.so -> <engine>
│   └── libnative_sum.so
└── data/
    ├── icudtl.dat
    └── flutter_assets -> <appRoot>/build/flutter_assets
```

The engine is symlinked into `bundle/lib`; the native asset libraries are
copied there. Landing in the engine's `$ORIGIN` directory is what makes
`dlopen("libnative_sum.so")` succeed. The same layout is staged for release,
with real copies so the bundle stays relocatable.

The engine is expected to have `$ORIGIN` in its `RUNPATH`; the runner does not
patch it. Add it to a prebuilt engine with:

```sh
patchelf --add-rpath '$ORIGIN' /path/to/libflutter_engine.so
```

`demos/native_assets/` is a minimal end-to-end example.
