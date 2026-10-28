# Wayland host

This folder is the app's Wayland platform runner, like `linux/` is the GTK one.
It is a small Zig executable that fetches the `filo` package and runs the
Flutter engine directly on Wayland. The Flutter framework and Dart code are
unchanged; `filo` exports the `filo_window_*` symbols that the
`filo_windowing` Dart package binds to.

The folder belongs to the app, so app-specific native code and future plugins
can live here. Add modules in `build.zig` and import them from `src/main.zig`.

## First-time setup

The tool depends on `package:args`, so make sure the app's pubspec includes it:

```sh
dart pub add args
```

1. Fetch filo into this Zig project:

   ```sh
   dart wayland/tool/wayland.dart setup-filo <filo-package-url-or-path>
   ```

   This runs `zig fetch --save=filo`, so the dependency is pinned by hash. For
   a checkout in this repository, `build.zig.zon` already uses a local path and
   this step can be skipped.

2. Provide a standalone Flutter engine:

   ```sh
   cp wayland/.env.local.example wayland/.env.local
   # edit FILO_ENGINE_LIB
   ```

3. Register the global Flutter custom device once:

   ```sh
   dart wayland/tool/wayland.dart register-device
   ```

4. Run from the app root:

   ```sh
   flutter run -d filo_wayland
   ```

   If your Flutter branch still gates windowing behind a flag, add
   `--enable-windowing`.

   Flutter custom devices do not forward `--dart-entrypoint-args`. To pass
   arguments to Dart's `main(List<String> args)`, set
   `FILO_DART_ENTRYPOINT_ARGS` with one argument per line when running Flutter
   (or put it in `wayland/.env.local`):

   ```sh
   FILO_DART_ENTRYPOINT_ARGS=$'--dart-flag1\npositional' flutter run -d filo_wayland
   ```

The custom device is project-aware: its `ping` only succeeds where
`wayland/build.zig` exists, so the same device entry works for every app that
has this folder. On arm64 hosts, change `platform` in `custom-device.json` to
`linux-arm64`.

The tooling lives in `wayland/tool/`: `wayland.dart` is the command-line
entrypoint, each command is in its own file under `tool/src/commands/`, and
shared helpers are in `tool/src/tool.dart`. It uses the Dart SDK plus
`package:args` from the app's pubspec.
Make sure `dart` is on `PATH` (it ships with Flutter, alongside `flutter`).

## How the hooks fit together

- `postBuild` runs `zig build` after Flutter writes `build/flutter_assets`. It
  resolves the engine, ICU data, assets, Dart entrypoint arguments and filo
  switches, then writes `wayland/.filo-build/launch.json`.
- `install` writes `wayland/.filo/launch.json` with the exact asset directory
  Flutter built; `uninstall` removes that per-run state.
- `runDebug` runs `wayland/zig-out/bin/<appName>` directly, so the app starts
  with the app root as its working directory and Flutter stops the actual app
  process. The host reads the launch manifest; `FILO_*` environment variables
  override it. Flutter's `${engineOptions}` are currently ignored.
- Flutter discovers the VM service URL from the host's stdout, so hot reload
  and hot restart work through the normal Flutter tooling.

For a manual run, `dart wayland/tool/wayland.dart run` refreshes the launch
manifest and starts the host with the app root as the working directory.
`zig build run` from `wayland/` still works when `FILO_ENGINE_LIB`,
`FILO_ICU_DATA` and `FILO_ASSETS` are set.

`.env.local` is parsed by the Dart tool, not sourced by a shell. It supports
`KEY=VALUE`, comments, single/double quoted values and `$'...'` escapes, but no
variable expansion or command substitution. Relative paths resolve against
`wayland/`.

Custom devices only support debug builds, so `flutter run` cannot produce a
release build. Use the `build-release` command instead:

```sh
# Point at a release-built engine. It must match the Flutter SDK/engine
# revision; a debug engine cannot run the AOT snapshot. Add it to
# wayland/.env.local to avoid repeating it:
#   FILO_ENGINE_LIB_RELEASE=/absolute/path/to/release/libflutter_engine.so
dart wayland/tool/wayland.dart build-release

# Build and launch the staged bundle:
dart wayland/tool/wayland.dart build-release --run
```

The command:

1. runs `flutter assemble` for `release_bundle_<platform>_assets`, producing
   the AOT snapshot and assets under `build/wayland/release/`;
2. builds the Zig host with `-Doptimize=ReleaseFast`;
3. writes `wayland/.filo/launch.json` with the release engine, ICU data, assets
   and `libapp.so`;
4. stages a relocatable bundle in `build/wayland/dist/<appName>/`.

The staged bundle can be copied to another machine and started with its
launcher:

```text
<appName>/
├── <appName>              # launcher
├── .filo/launch.json
├── bin/<appName>
├── data/icudtl.dat
├── data/flutter_assets/
└── lib/libapp.so, libflutter_engine.so
```

`build-release` accepts `--dist <dir>` (default `build/wayland/dist`),
`--app-name <name>` (default: `pubspec.yaml`'s `name`), `--target <file>`
(default `lib/main.dart`), `--target-platform <name>`, `--optimize
<debug|safe|fast|small>` (default `fast`) and repeatable `--dart-define` /
`--dart-define-from-file` options. It records the same `FILO_*` switches as the
debug hooks, so values in `.env.local` are baked into the release manifest.

Release builds need a release Flutter engine: `FILO_ENGINE_LIB_RELEASE` is used
if set, otherwise `wayland/engine/release/libflutter_engine.so`. ICU data comes
from `FILO_ICU_DATA`, a previous debug build's manifest,
`wayland/engine/icudtl.dat` or the Flutter SDK cache, in that order.

Native plugin assets are not copied into the staged bundle yet; the host only
runs the Flutter asset bundle and the AOT snapshot.

## Files

- `build.zig`, `build.zig.zon` — the host executable and its filo dependency.
- `src/main.zig` — reads the launch manifest (or `FILO_*`), forwards argv to
  Dart, calls `filo.run`.
- `tool/wayland.dart` — the command-line entrypoint and command registration.
- `tool/src/commands/` — one file per command.
- `tool/src/tool.dart` — shared paths, manifest, `.env.local`, process and file
  helpers.
- `custom-device.json` — the device entry; the `register-device` subcommand
  installs it.
- `.env.local` — machine-specific paths, parsed by the Dart tool; gitignored.
- `.filo-build/`, `.filo/` — generated launch state; gitignored.
- `build/wayland/release/`, `build/wayland/dist/` — generated release AOT and
  staged bundle, inside the app's `build/` directory.
