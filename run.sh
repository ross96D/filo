#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILO_DIR="${SCRIPT_DIR}/filo"
cd "$FILO_DIR"

MODE="${1:-debug}"
APP_DIR="$SCRIPT_DIR/demos/windowing_demo"

case "$MODE" in
  debug|jit)
    ENGINE_LIB="$FILO_DIR/flutter-engine/debug/libflutter_engine.so"
    ASSETS="$APP_DIR/build/flutter_assets"
    AOT_LIB=""
    ;;
  release|aot)
    ENGINE_LIB="$FILO_DIR/flutter-engine/release/libflutter_engine.so"
    ASSETS="$APP_DIR/build/linux/x64/release/bundle/data/flutter_assets"
    AOT_LIB="$APP_DIR/build/linux/x64/release/bundle/lib/libapp.so"
    ;;
  *)
    echo "usage: $0 [debug|release]" >&2
    exit 1
    ;;
esac

ICU_DATA="$FILO_DIR/flutter-engine/shared/icudtl.dat"

if [ ! -f "$ENGINE_LIB" ]; then echo "missing engine lib: $ENGINE_LIB" >&2; exit 1; fi
if [ ! -f "$ICU_DATA" ]; then echo "missing icu data: $ICU_DATA" >&2; exit 1; fi
if [ ! -d "$ASSETS" ]; then
  echo "missing flutter assets: $ASSETS" >&2
  echo "build them in windowing_demo/ with:  flutter build bundle   (debug)  or  flutter build linux --release" >&2
  exit 1
fi
if [ -n "$AOT_LIB" ] && [ ! -f "$AOT_LIB" ]; then echo "missing aot lib: $AOT_LIB" >&2; exit 1; fi

zig build

export FILO_ENGINE_LIB="$ENGINE_LIB"
export FILO_ICU_DATA="$ICU_DATA"
export FILO_ASSETS="$ASSETS"
if [ -n "$AOT_LIB" ]; then
  export FILO_AOT_LIB="$AOT_LIB"
fi

exec ./zig-out/bin/filo
