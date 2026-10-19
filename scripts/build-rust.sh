#!/usr/bin/env bash
# Builds the Rust core as a static library and generates Swift bindings.
# Usage: scripts/build-rust.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Match the app's minimum macOS so C deps (bundled sqlite) link cleanly.
export MACOSX_DEPLOYMENT_TARGET=14.0

PROFILE_FLAG=()
[[ "$CONFIG" == "release" ]] && PROFILE_FLAG=(--release)

cargo build -p snapora-ffi "${PROFILE_FLAG[@]}"

LIB_DIR="$ROOT/target/$CONFIG"
GEN="$ROOT/macos/Generated"
FFI_MODULE="$GEN/SnaporaFFI"
SWIFT_OUT="$ROOT/macos/App/Generated"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cargo run -q -p uniffi-bindgen -- generate \
  --library "$LIB_DIR/libsnapora_ffi.dylib" \
  --language swift \
  --out-dir "$TMP"

mkdir -p "$FFI_MODULE" "$GEN/lib" "$SWIFT_OUT"

# Replace outputs only when they change, so concurrent or incremental Swift
# builds never see missing files.
install_if_changed() {
  if ! cmp -s "$1" "$2"; then
    cp "$1" "$2.tmp.$$" && mv -f "$2.tmp.$$" "$2"
  fi
}
install_if_changed "$TMP/snapora_ffiFFI.h" "$FFI_MODULE/snapora_ffiFFI.h"
# SwiftPM system-library targets need the map named module.modulemap.
install_if_changed "$TMP/snapora_ffiFFI.modulemap" "$FFI_MODULE/module.modulemap"
install_if_changed "$TMP/snapora_ffi.swift" "$SWIFT_OUT/snapora_ffi.swift"
# Only the static archive goes here so the linker cannot pick the dylib.
install_if_changed "$LIB_DIR/libsnapora_ffi.a" "$GEN/lib/libsnapora_ffi.a"

echo "Rust core built ($CONFIG); bindings in macos/Generated and macos/App/Generated"
