# filo

filo is a Flutter embedder for Linux/Wayland. It is a Zig package compiled into the app's host executable, replacing the GTK runner and rendering through Vulkan. It supports xdg toplevels, dialogs, popups, tooltips, and wlr-layer-shell layers; Dart talks to it through the `filo_windowing` package.

## Quick start

You need Linux with a Wayland compositor, a Vulkan 1.1 driver, `wayland-client`, `libxkbcommon`, Zig 0.17, and Flutter 3.47.7. If you are in a wayland desktop is very likely that `wayland-client` and `libxkbcommon` are already installed.

### 1. Add the runner to your app

Copy the template from this repository into your Flutter app as `wayland/`:

```sh
cp -r /path/to/this/repo/filo/templates/wayland /path/to/your/app/wayland
```

Then install the tooling dependencies if you dont already have them:

```sh
cd /path/to/your/app
dart pub add dev:args dev:path
```

### 2. Fetch filo and the engine

```sh
dart wayland/tool/wayland.dart setup-filo
```

This pins filo in `wayland/build.zig.zon` and downloads the Flutter 3.47.7 debug and release engines plus ICU data into `wayland/engine/`. Flutter framework and engine artifacts must come from the same revision, so build the app with Flutter 3.47.7.

If you want another Flutter version, provide the engine yourself. Run the setup command, then replace the downloaded files with a standalone engine and ICU data built from the Flutter revision you use:

```text
wayland/engine/debug/libflutter_engine.so
wayland/engine/release/libflutter_engine.so
wayland/engine/common/icudtl.dat
```

If the files are in those default locations, no environment variables are needed. If they live elsewhere, point `FILO_ENGINE_LIB`, `FILO_ENGINE_LIB_RELEASE`, and `FILO_ICU_DATA` at them instead. Your engine must have `$ORIGIN` in its `RUNPATH` (see the note below) and Skia enabled. `filo_windowing` targets the Flutter 3.47 windowing API, so use a 3.47.x release until the package is updated.

### 3. Register the device

```sh
dart wayland/tool/wayland.dart register-device
```

This registers `filo_wayland` globally for every app that has a `wayland/` folder.

### 4. Run

```sh
flutter run -d filo_wayland
```

If your Flutter branch still gates windowing behind a flag, pass `--enable-windowing`.

For a release build:

```sh
dart wayland/tool/wayland.dart build-release
./build/wayland/x64/release/bundle/<app_name>
```

Native asset libraries loaded by Dart build hooks need `$ORIGIN` in the engine's `RUNPATH`. The engines downloaded by the setup command have it; for your own engine, run:

```sh
patchelf --add-rpath '$ORIGIN' /path/to/libflutter_engine.so
```

See [`filo/README.md`](filo/README.md) for the Zig API, configuration, and bundle layout.
