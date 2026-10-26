# Wayland host

This folder is the app's Wayland platform runner, like `linux/` is the GTK one.
It is a small Zig executable that fetches the `filo` package and runs the
Flutter engine directly on Wayland. The Flutter framework and Dart code are
unchanged; `filo` exports the `filo_window_*` symbols that the
`filo_windowing` Dart package binds to.

The folder belongs to the app, so app-specific native code and future plugins
can live here. Add modules in `build.zig` and import them from `src/main.zig`.

## First-time setup

1. Fetch filo into this Zig project:

   ```sh
   cd wayland
   zig fetch --save=filo <filo-package-url-or-path>
   ```

   For a checkout in this repository, `build.zig.zon` already uses a local
   path. For an app outside the repository, use `zig fetch` so the dependency
   is pinned by hash.

2. Provide a standalone Flutter engine:

   ```sh
   cp wayland/.env.local.example wayland/.env.local
   # edit FILO_ENGINE_LIB
   ```

3. Register the global Flutter custom device once:

   ```sh
   ./wayland/register-device.sh
   ```

4. Run from the app root:

   ```sh
   flutter run -d filo_wayland
   ```

   If your Flutter branch still gates windowing behind a flag, add
   `--enable-windowing`.

   Flutter custom devices do not forward `--dart-entrypoint-args`. To pass
   arguments to Dart's `main(List<String> args)`, set
   `FILO_DART_ENTRYPOINT_ARGS` with one argument per line:

   ```sh
   FILO_DART_ENTRYPOINT_ARGS=$'--dart-flag1\npositional' flutter run -d filo_wayland
   ```

The custom device is project-aware: its `ping` only succeeds where
`wayland/build.zig` exists, so the same device entry works for every app that
has this folder. On arm64 hosts, change `platform` in `custom-device.json` to
`linux-arm64`.

## How the hooks fit together

- `postBuild` runs `zig build` after Flutter writes `build/flutter_assets`.
- `install` records the exact asset directory in `wayland/.filo/assets`.
- `runDebug` sets `FILO_ENGINE_LIB`, `FILO_ICU_DATA` and `FILO_ASSETS` and
  `exec`s the host with the Dart entrypoint arguments as argv. Flutter's
  `${engineOptions}` are currently ignored.
- Flutter discovers the VM service URL from the host's stdout, so hot reload
  and hot restart work through the normal Flutter tooling.

Custom devices only support debug builds. For release, build the AOT bundle
separately (for example with `flutter build linux --release` while the `linux/`
runner is still present) and launch the host with `FILO_AOT_LIB` and the
release `FILO_ASSETS`. `filo` itself supports AOT; only the custom-device
debug hook is limited to debug mode.

## Files

- `build.zig`, `build.zig.zon` — the host executable and its filo dependency.
- `src/main.zig` — reads `FILO_*`, forwards argv to Dart, calls `filo.run`.
- `tool/post-build.sh`, `tool/install.sh`, `tool/uninstall.sh`, `tool/run.sh`
  — the custom-device hooks.
- `custom-device.json` — the device entry; `register-device.sh` installs it.
- `.env.local` — machine-specific paths; gitignored.
