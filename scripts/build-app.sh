#!/usr/bin/env bash
# Builds Snapora.app into build/<config>/.
# Usage: scripts/build-app.sh [debug|release]
# Signing: set SNAPORA_SIGN_IDENTITY to a codesigning identity. Defaults to
# ad-hoc ("-"); with ad-hoc signing macOS may re-ask for Screen Recording
# permission after each rebuild.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${SNAPORA_SIGN_IDENTITY:--}"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"

"$ROOT/scripts/build-rust.sh" "$CONFIG"

cd "$ROOT/macos"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Snapora"

APP="$ROOT/build/$CONFIG/Snapora.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Snapora"
sed "s/__VERSION__/$VERSION/g" "$ROOT/macos/Resources/Info.plist" > "$APP/Contents/Info.plist"

codesign --force --options runtime --timestamp=none \
  --entitlements "$ROOT/macos/Resources/Snapora.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

echo "Built $APP"
