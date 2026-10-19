#!/usr/bin/env bash
# Builds the Rust core as a static library and generates Swift bindings.
# Usage: scripts/build-rust.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

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

rm -rf "$FFI_MODULE" "$GEN/lib" "$SWIFT_OUT"
mkdir -p "$FFI_MODULE" "$GEN/lib" "$SWIFT_OUT"

cp "$TMP/snapora_ffiFFI.h" "$FFI_MODULE/"
# SwiftPM system-library targets need the map named module.modulemap.
cp "$TMP/snapora_ffiFFI.modulemap" "$FFI_MODULE/module.modulemap"
cp "$TMP/snapora_ffi.swift" "$SWIFT_OUT/"
# Only the static archive goes here so the linker cannot pick the dylib.
cp "$LIB_DIR/libsnapora_ffi.a" "$GEN/lib/"

echo "Rust core built ($CONFIG); bindings in macos/Generated and macos/App/Generated"
