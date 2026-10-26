# filo

A Flutter embedder for Wayland, consumed as a Zig package. The embedder is
compiled into the host executable; there is no separate shared library or
installed artifact.

## Requirements

- Zig 0.17
- Wayland (`wayland-client`, a compositor with `xdg-shell`)
- `libxkbcommon`
- A Vulkan 1.3 driver
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

Or use a local checkout while developing:

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

| Field               | Meaning                                                                  |
| ------------------- | ------------------------------------------------------------------------ |
| `engine_lib`        | Path to `libflutter_engine.so`                                           |
| `icu_data`          | Path to `icudtl.dat`                                                     |
| `assets`            | Path to the application's `flutter_assets` directory                     |
| `aot_lib`           | Optional path to the AOT `libapp.so`; JIT when null                      |
| `force_impeller`    | Use Impeller instead of Skia (expected to fail with the compositor path) |
| `vulkan_validation` | Enable the Vulkan validation layer when installed                        |
| `trace`             | Print per-frame synchronization timings                                  |
| `bootstrap_layer`   | Bootstrap implicit view 0 as a layer instead of an xdg_toplevel          |
| `bootstrap_layer_surface` | Layer/anchors/margins/size/namespace for that surface (see below) |
| `windowing_spike`   | Exercise the exported windowing ABI from the event loop                  |
| `engine_args`       | Extra engine switches supplied by the host                               |
| `dart_entrypoint_args` | Arguments for Dart's `main(List<String> args)`                       |

`Config.fromEnv` reads the development environment variables
`FILO_ENGINE_LIB`, `FILO_ICU_DATA`, `FILO_ASSETS`, `FILO_AOT_LIB`,
`FORCE_IMPELLER`, `FILO_VULKAN_VALIDATION`, `FILO_TRACE`, `FILO_LAYER_ONLY` and
`FILO_WINDOWING_SPIKE`. A host with its own configuration can build a `Config`
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

`bootstrap_layer` chooses the role of the implicit view (id 0) before the engine
starts: a layer surface instead of an xdg_toplevel. It is not a restriction on
the windows the app may create. Choose it to match the app's first window; the
current engine integration reliably presents that bootstrap view. The setting
exists because the engine needs view 0's native surface before its first frame.

The defaults in `LayerBootstrap` match the `windowing_demo` panel: top layer,
anchored top-right, 8px top/right margin, 300×300, on-demand keyboard. The first
`FiloLayerWindowController` should use the same properties; it then adopts that
surface without reconfiguring it. A controller with different properties updates
the surface, which can race its first frame, so hosts with a different panel
should set `Config.bootstrap_layer_surface` accordingly. `FILO_LAYER_ONLY=1` is
the development-runner switch that sets `bootstrap_layer`.

The runtime copies the config strings, so the caller's buffers only need to
live until `Runtime.init` returns. `engine_args` and `dart_entrypoint_args` are
the exception: the runtime only reads them during `Runtime.init`, so the backing
strings need to live until then, not for the runtime's lifetime.

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
- One process has one embedder. `Runtime.init` returns
  `error.AlreadyInitialized` while another runtime is alive.

## Dart windowing package

`packages/filo_windowing` keeps its existing loading contract: it looks up the
`filo_window_*` symbols in the process image. This is why the host executable
must be built with `rdynamic`/`--export-dynamic`. No `dlopen` or `libfilo.so`
is involved.

## Flutter custom devices

For `flutter run -d <device>`, use the per-app runner template in
[`templates/wayland/`](templates/wayland/README.md). The working example in this
repository is `demos/multiple_windows/wayland/`. The template contains:

- a Zig host that imports `filo` and calls `filo.run`,
- `postBuild`/`install`/`uninstall`/`runDebug` hooks,
- a `custom-device.json` and a registration script.

Copy it into an app as `wayland/`, fetch filo into it, provide an engine path in
`.env.local`, and register the device once with `wayland/register-device.sh`.
The same global device entry works for every app that has a `wayland/` folder.

Flutter custom devices do not forward `--dart-entrypoint-args`; use
`FILO_DART_ENTRYPOINT_ARGS` with one argument per line instead. Engine switches
from `${engineOptions}` are currently ignored.

Flutter custom devices only support debug builds. Release builds still need a
separate AOT bundle and a manual launch with `FILO_AOT_LIB` set.

## Development

```sh
zig build          # build the development runner
zig build run      # run it (needs the FILO_* variables)
zig build check    # compile + formatting check
zig build test     # unit tests
zig build fmt      # format in place
```

The repository root `run.sh` sets the engine, ICU and asset paths and runs the
development runner. For `flutter run`, use the custom-device template above.
