# Native assets demo

A minimal Dart native assets example for the filo Wayland embedder.

The app calls a C function from a Dart build hook:

```text
native_sum/
├── hook/build.dart     # CBuilder.library(...) -> libnative_sum.so
├── src/native_sum.c    # int32_t native_sum(int32_t a, int32_t b)
└── lib/native_sum.dart # @Native(assetId: 'package:native_sum/native_sum.dart')
```

The window shows `native_sum(20, 22) = 42`.

## Prerequisites

Native assets are still behind a Flutter feature flag:

```sh
flutter config --enable-native-assets
```

The engine must have `$ORIGIN` in its `RUNPATH`. The engine, not the host,
performs the `dlopen` for native assets, so this is what lets it find a library
placed next to it:

```sh
readelf -d /path/to/libflutter_engine.so | grep -E 'RPATH|RUNPATH'
```

If the output has no `$ORIGIN`, build the engine with
`-Wl,-rpath,'$ORIGIN'` or add it once with:

```sh
patchelf --add-rpath '$ORIGIN' /path/to/libflutter_engine.so
```

The demo does not patch the engine.

## Run with the repository development runner

```sh
cd demos/native_assets
flutter pub get
flutter build bundle --target-platform linux-x64

cd ../..
FILO_APP_DIR="$PWD/demos/native_assets" \
FILO_ENGINE_LIB=/path/to/libflutter_engine.so \
./run.sh
```

`FILO_ENGINE_LIB` must point to an engine with `$ORIGIN` in its RUNPATH. If it
is omitted, `run.sh` uses `filo/flutter-engine/debug/libflutter_engine.so`,
which must be patched the same way.

`run.sh` creates:

```text
demos/native_assets/build/wayland/x64/debug/bundle/
├── lib/
│   ├── libflutter_engine.so -> <FILO_ENGINE_LIB>
│   └── libnative_sum.so
└── data/
    ├── icudtl.dat -> filo/flutter-engine/shared/icudtl.dat
    └── flutter_assets -> <appRoot>/build/flutter_assets
```

## Run with the Wayland custom device

```sh
cd demos/native_assets

# Provide the debug engine and ICU data, or export FILO_ENGINE_LIB and
# FILO_ICU_DATA when running Flutter.
mkdir -p wayland/engine/debug wayland/engine/common
ln -s ../../../../../filo/flutter-engine/debug/libflutter_engine.so \
  wayland/engine/debug/libflutter_engine.so
ln -s ../../../../../filo/flutter-engine/shared/icudtl.dat \
  wayland/engine/common/icudtl.dat

# once per machine
dart wayland/tool/wayland.dart register-device

flutter run -d filo_wayland
```

The `postBuild` hook stages a debug bundle under
`build/wayland/<arch>/debug/bundle/`. `runDebug` launches the host from that
bundle, and the host resolves the engine, assets and ICU data relative to
itself. There is no launch manifest or `.env.local` step.

## Release

```sh
cd demos/native_assets
# place a release engine at wayland/engine/release/libflutter_engine.so,
# or set FILO_ENGINE_LIB_RELEASE
dart wayland/tool/wayland.dart build-release
build/wayland/x64/release/bundle/native_assets_demo
```

The release bundle contains real copies of the engine, AOT snapshot, assets and
native asset libraries, so it can be moved to another machine.

## What Flutter generates

`flutter build bundle` or `flutter run` produces:

```text
build/flutter_assets/
├── NativeAssetsManifest.json
└── native_assets/linux/libnative_sum.so
```

The manifest contains:

```json
{"format-version":[1,0,0],"native-assets":{"linux_x64":{"package:native_sum/native_sum.dart":["absolute","libnative_sum.so"]}}}
```

Because the path is only a file name, the engine resolves it through its own
`RUNPATH`. Placing `libnative_sum.so` in the same directory as the engine is
what makes the lookup work.
