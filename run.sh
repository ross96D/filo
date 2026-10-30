#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILO_DIR="${SCRIPT_DIR}/filo"

MODE="${1:-debug}"
APP_DIR="${FILO_APP_DIR:-$SCRIPT_DIR/demos/multiple_windows}"
if [ ! -d "$APP_DIR" ]; then
  echo "missing app directory: $APP_DIR" >&2
  exit 1
fi
APP_DIR="$(cd "$APP_DIR" && pwd)"

case "$(uname -m)" in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  riscv64) ARCH=riscv64 ;;
  *)
    echo "unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

case "$MODE" in
  debug|jit)
    MODE_NAME=debug
    ENGINE_SRC="${FILO_ENGINE_LIB:-$FILO_DIR/flutter-engine/debug/libflutter_engine.so}"
    ICU_DATA="$FILO_DIR/flutter-engine/shared/icudtl.dat"
    FLUTTER_ASSETS="$APP_DIR/build/flutter_assets"
    NATIVE_DIR="$FLUTTER_ASSETS/native_assets/linux"
    AOT_LIB=""
    ;;
  release|aot)
    MODE_NAME=release
    ENGINE_SRC="${FILO_ENGINE_LIB_RELEASE:-$FILO_DIR/flutter-engine/release/libflutter_engine.so}"
    ICU_DATA="$FILO_DIR/flutter-engine/shared/icudtl.dat"
    STAGED_BUNDLE="$APP_DIR/build/wayland/$ARCH/release/bundle"
    if [ -f "$STAGED_BUNDLE/lib/libflutter_engine.so" ] &&
       [ -d "$STAGED_BUNDLE/data/flutter_assets" ]; then
      BUNDLE_DIR="$STAGED_BUNDLE"
      LIB_DIR="$BUNDLE_DIR/lib"
      DATA_DIR="$BUNDLE_DIR/data"
      ENGINE_SRC="$LIB_DIR/libflutter_engine.so"
      ICU_DATA="$DATA_DIR/icudtl.dat"
      FLUTTER_ASSETS="$DATA_DIR/flutter_assets"
      AOT_LIB="$LIB_DIR/libapp.so"
      STAGED_READY=1
    else
      FLUTTER_BUNDLE="$APP_DIR/build/linux/$ARCH/$MODE_NAME/bundle"
      FLUTTER_ASSETS="$FLUTTER_BUNDLE/data/flutter_assets"
      if [ -f "$FLUTTER_BUNDLE/data/icudtl.dat" ]; then
        ICU_DATA="$FLUTTER_BUNDLE/data/icudtl.dat"
      fi
      AOT_LIB="$FLUTTER_BUNDLE/lib/libapp.so"
      NATIVE_DIR="$FLUTTER_BUNDLE/lib"
      STAGED_READY=0
    fi
    ;;
  *)
    echo "usage: $0 [debug|release]" >&2
    exit 1
    ;;
esac

BUNDLE_DIR="${BUNDLE_DIR:-$APP_DIR/build/wayland/$ARCH/$MODE_NAME/bundle}"
LIB_DIR="${LIB_DIR:-$BUNDLE_DIR/lib}"
DATA_DIR="${DATA_DIR:-$BUNDLE_DIR/data}"

if [ ! -f "$ENGINE_SRC" ]; then echo "missing engine lib: $ENGINE_SRC" >&2; exit 1; fi
if [ ! -f "$ICU_DATA" ]; then echo "missing icu data: $ICU_DATA" >&2; exit 1; fi
if [ ! -d "$FLUTTER_ASSETS" ]; then
  echo "missing flutter assets: $FLUTTER_ASSETS" >&2
  if [ "$MODE_NAME" = debug ]; then
    echo "build them in $APP_DIR with: flutter build bundle --target-platform linux-$ARCH" >&2
  else
    echo "build them with: flutter build linux --release, or use the wayland tool's build-release" >&2
  fi
  exit 1
fi
if [ -n "$AOT_LIB" ] && [ ! -f "$AOT_LIB" ]; then echo "missing aot lib: $AOT_LIB" >&2; exit 1; fi

warn_if_engine_lacks_origin() {
  local manifest="$FLUTTER_ASSETS/NativeAssetsManifest.json"
  if [ ! -f "$manifest" ] || ! grep -qE '\.so' "$manifest"; then
    return 0
  fi
  if ! command -v readelf >/dev/null 2>&1; then
    return 0
  fi
  if ! readelf -d "$ENGINE_SRC" 2>/dev/null | grep -E 'RPATH|RUNPATH' | grep -q '\$ORIGIN'; then
    echo "warning: $ENGINE_SRC has no \$ORIGIN in RUNPATH; native assets will not load" >&2
    echo "         build the engine with -Wl,-rpath,'\$ORIGIN' or add it with patchelf" >&2
  fi
}

warn_if_engine_lacks_origin

prepare_bundle() {
  # Resolve sources before clearing the bundle: a caller may point one of the
  # environment variables at a previous bundle entry.
  local engine_src icu_src assets_src aot_src
  engine_src="$(realpath "$ENGINE_SRC")"
  icu_src="$(realpath "$ICU_DATA")"
  assets_src="$(realpath "$FLUTTER_ASSETS")"
  if [ -n "$AOT_LIB" ]; then
    aot_src="$(realpath "$AOT_LIB")"
  fi

  mkdir -p "$LIB_DIR" "$DATA_DIR"
  find "$LIB_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
  find "$DATA_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf {} +

  # Symlink the engine instead of copying it. The engine must already have
  # `$ORIGIN` in its RUNPATH so its own dlopen calls resolve the native assets
  # beside this link.
  ln -s "$engine_src" "$LIB_DIR/libflutter_engine.so"
  if [ -n "$AOT_LIB" ]; then
    ln -s "$aot_src" "$LIB_DIR/libapp.so"
  fi
  ln -s "$icu_src" "$DATA_DIR/icudtl.dat"
  ln -s "$assets_src" "$DATA_DIR/flutter_assets"

  local manifest="$assets_src/NativeAssetsManifest.json"
  if [ -n "${NATIVE_DIR:-}" ] && [ -f "$manifest" ]; then
    while IFS= read -r name; do
      name="${name%\"}"
      name="${name#\"}"
      for dir in "$NATIVE_DIR" "$assets_src/native_assets/linux" "$assets_src/../native_assets/linux"; do
        if [ -f "$dir/$name" ]; then
          ln -s "$(realpath "$dir/$name")" "$LIB_DIR/$name"
          break
        fi
      done
    done < <(grep -oE '"[^"/]+\.so[^"]*"' "$manifest" | sort -u || true)
  fi
}

cd "$FILO_DIR"
zig build

if [ "${STAGED_READY:-0}" = 0 ]; then
  prepare_bundle
fi

export FILO_ENGINE_LIB="$LIB_DIR/libflutter_engine.so"
export FILO_ICU_DATA="$DATA_DIR/icudtl.dat"
export FILO_ASSETS="$DATA_DIR/flutter_assets"
if [ -n "$AOT_LIB" ]; then
  export FILO_AOT_LIB="$LIB_DIR/libapp.so"
fi

exec ./zig-out/bin/filo
