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
| `extra_windows`     | Open this many extra test views at startup                               |
| `windowing_spike`   | Exercise the exported windowing ABI from the event loop                  |
| `engine_args`       | Extra engine switches, e.g. Flutter's `${engineOptions}`                 |

`Config.fromEnv` reads the development environment variables
`FILO_ENGINE_LIB`, `FILO_ICU_DATA`, `FILO_ASSETS`, `FILO_AOT_LIB`,
`FORCE_IMPELLER`, `FILO_VULKAN_VALIDATION`, `FILO_TRACE`,
`FILO_EXTRA_WINDOWS` and `FILO_WINDOWING_SPIKE`. A host with its own
configuration can build a `Config` directly.

The runtime copies the config strings, so the caller's buffers only need to
live until `Runtime.init` returns. `engine_args` is the exception: the runtime
only reads it during `Runtime.init`, so the backing strings need to live until
then, not for the runtime's lifetime.

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
