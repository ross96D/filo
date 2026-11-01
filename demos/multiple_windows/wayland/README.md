# Wayland host

This folder is the multiple_windows demo's Wayland platform runner, like
`linux/` is the GTK one. It is a small Zig executable that runs the Flutter
engine directly on Wayland. The Flutter framework and Dart code are unchanged;
`filo` exports the `filo_window_*` symbols that the `filo_windowing` Dart
package binds to.

The folder belongs to the app, so app-specific native code and future plugins
can live here. Add modules in `build.zig` and import them from `src/main.zig`.

Unlike the template in `filo/templates/wayland/`, this copy's `build.zig.zon`
already depends on the local filo checkout at `../../../filo`, so
`setup-filo` is not required.

## Bundle layout

The host derives every path from its own executable:

```text
<appName>
lib/
  libflutter_engine.so
  libapp.so            # release only; picked up automatically when present
data/
  icudtl.dat
  flutter_assets/
```

Environment variables override the defaults:

| Variable | Meaning |
| --- | --- |
| `FILO_ENGINE_LIB` | Path to `libflutter_engine.so` |
| `FILO_ICU_DATA` | Path to `icudtl.dat` |
| `FILO_ASSETS` | Path to `flutter_assets` |
| `FILO_AOT_LIB` | Path to `libapp.so` |
| `FILO_DART_ENTRYPOINT_ARGS` | Arguments for Dart's `main`, one per line |
| `FORCE_IMPELLER` | Use Impeller instead of Skia |
| `FILO_VULKAN_VALIDATION` | Enable the Vulkan validation layer |
| `FILO_TRACE` | Print per-frame synchronization timings |
| `FILO_LAYER_ONLY` | Bootstrap the implicit view as a layer surface |

Relative paths in the tool's override variables resolve against `wayland/`.

## Setup

The tool depends on `package:args` and `package:path`, so make sure the app's
pubspec includes them:

```sh
dart pub add args path
```

1. Provide a standalone Flutter engine and ICU data:

   ```text
   wayland/engine/debug/libflutter_engine.so
   wayland/engine/release/libflutter_engine.so
   wayland/engine/common/icudtl.dat
   ```

   The engines must match the Flutter SDK/engine revision used to build the
   app. A debug engine cannot run the AOT snapshot, so keep the release engine
   separate.

   `FILO_ENGINE_LIB`, `FILO_ENGINE_LIB_RELEASE` and `FILO_ICU_DATA` override
   these paths. For a checkout in this repository, the engine can also be
   symlinked to `filo/flutter-engine/debug/libflutter_engine.so`.

   The engine must have `$ORIGIN` in its `RUNPATH`. The engine, not the host,
   calls `dlopen` for Dart native assets, so the engine's own search path is
   what matters. Build the engine with `-Wl,-rpath,'$ORIGIN'`, or add the entry
   to a prebuilt engine once:

   ```sh
   patchelf --add-rpath '$ORIGIN' /absolute/path/to/libflutter_engine.so
   ```

   Verify with:

   ```sh
   readelf -d /absolute/path/to/libflutter_engine.so | grep -E 'RPATH|RUNPATH'
   ```

   The output must contain `$ORIGIN`. The debug runner symlinks the engine into
   the app bundle; it does not patch it.

2. Register the global Flutter custom device once:

   ```sh
   dart wayland/tool/wayland.dart register-device
   ```

   This writes the host architecture into the generated custom-device entry,
   so arm64 and x64 hosts register the correct `runDebug` path automatically.

3. Run from the app root:

   ```sh
   flutter run -d filo_wayland
   ```

   If your Flutter branch still gates windowing behind a flag, add
   `--enable-windowing`.

   Flutter custom devices do not forward `--dart-entrypoint-args`. To pass
   arguments to Dart's `main(List<String> args)`, set
   `FILO_DART_ENTRYPOINT_ARGS` with one argument per line when running Flutter:

   ```sh
   FILO_DART_ENTRYPOINT_ARGS=$'--dart-flag1\npositional' flutter run -d filo_wayland
   ```

The custom device is project-aware: its `ping` only succeeds where
`wayland/build.zig` exists, so the same device entry works for every app that
has this folder.

The tooling lives in `wayland/tool/`: `wayland.dart` is the command-line
entrypoint, each command is in its own file under `tool/src/commands/`, and
shared helpers are in `tool/src/tool.dart`. It uses the Dart SDK plus
`package:args` and `package:path` from the app's pubspec.
Make sure `dart` is on `PATH` (it ships with Flutter, alongside `flutter`).

## How the hooks fit together

- `postBuild` runs `zig build` after Flutter writes `build/flutter_assets` and
  stages a debug bundle under `build/wayland/<arch>/debug/bundle/`.
- `install` and `uninstall` are no-ops; the staged bundle already contains
  everything the host needs.
- `runDebug` runs the host inside that bundle, so Flutter stops the actual app
  process. The host resolves the engine, ICU data, assets and AOT snapshot
  relative to itself.
- Flutter discovers the VM service URL from the host's stdout, so hot reload
  and hot restart work through the normal Flutter tooling.

The debug bundle mirrors the native part of Flutter's Linux bundle:

```text
build/wayland/<arch>/debug/bundle/
├── <appName>
├── lib/
│   └── libflutter_engine.so -> wayland/engine/debug/libflutter_engine.so
└── data/
    ├── icudtl.dat -> wayland/engine/common/icudtl.dat
    └── flutter_assets -> <appRoot>/build/flutter_assets
```

The engine is only symlinked. If a Dart build hook produces native asset
libraries in `build/flutter_assets/native_assets/linux/`, they are copied into
`bundle/lib/`, next to the engine link. Because the engine has `$ORIGIN` in its
RUNPATH, its `dlopen` calls find those libraries.

For a manual run, `dart wayland/tool/wayland.dart run` stages the debug bundle
and starts the host with the app root as the working directory.

## Release builds

Custom devices only support debug builds, so `flutter run` cannot produce a
release build. Use the `build-release` command instead:

```sh
dart wayland/tool/wayland.dart build-release
```

The command:

1. runs `flutter assemble` for `release_bundle_<platform>_assets`, producing
   the AOT snapshot, assets and native assets under
   `build/wayland/<arch>/release/`;
2. builds the Zig host with `-Doptimize=ReleaseFast`;
3. stages a relocatable bundle in
   `build/wayland/<arch>/release/bundle/`.

The release bundle has the same layout as the debug one:

```text
bundle/
├── <appName>
├── lib/
│   ├── libflutter_engine.so
│   ├── libapp.so
│   └── <native asset libraries>
└── data/
    ├── icudtl.dat
    └── flutter_assets/
```

Launch it directly:

```sh
build/wayland/x64/release/bundle/multiple_windows
```

`build-release` accepts `--dist <dir>` (default
`build/wayland/<arch>/release/bundle`), `--app-name <name>` (default:
`pubspec.yaml`'s `name`), `--target <file>` (default `lib/main.dart`),
`--target-platform <name>`, `--optimize <debug|safe|fast|small>` (default
`fast`) and repeatable `--dart-define` / `--dart-define-from-file` options.

Release builds need a release Flutter engine at
`wayland/engine/release/libflutter_engine.so` or the path in
`FILO_ENGINE_LIB_RELEASE`. ICU data comes from `FILO_ICU_DATA` or
`wayland/engine/common/icudtl.dat`.

## Files

- `build.zig`, `build.zig.zon` — the host executable and its filo dependency.
- `src/main.zig` — resolves the bundle layout, forwards argv to Dart, calls
  `filo.run`.
- `tool/wayland.dart` — the command-line entrypoint and command registration.
- `tool/src/commands/` — one file per command.
- `tool/src/tool.dart` — shared paths, bundle staging, process and file
  helpers.
- `custom-device.json` — the device entry template; `register-device` fills in
  the host architecture.
- `engine/` — debug/release engines and `common/icudtl.dat`; gitignored.
- `build/wayland/<arch>/debug/` — generated debug bundle; gitignored.
- `build/wayland/<arch>/release/` — generated release AOT and staged bundle,
  inside the app's gitignored `build/` directory.
