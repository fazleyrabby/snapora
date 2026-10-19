#!/usr/bin/env bash
# Builds a release Snapora.app and packages it as build/Snapora-<version>.dmg.
#
# Distribution (outside the Mac App Store) needs:
#   SNAPORA_SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"
#   SNAPORA_NOTARY_PROFILE  keychain profile from `xcrun notarytool store-credentials`
# Without them the DMG is ad-hoc signed and only runs on this Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/Cargo.toml" | head -1)"
APP="$ROOT/build/release/Snapora.app"
DMG="$ROOT/build/Snapora-$VERSION.dmg"

"$ROOT/scripts/build-app.sh" release

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Snapora" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

if [[ -n "${SNAPORA_SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SNAPORA_SIGN_IDENTITY" --timestamp "$DMG"
fi

if [[ -n "${SNAPORA_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${SNAPORA_SIGN_IDENTITY:-}" ]]; then
    echo "Notarization requires SNAPORA_SIGN_IDENTITY (Developer ID)." >&2
    exit 1
  fi
  xcrun notarytool submit "$DMG" --keychain-profile "$SNAPORA_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
else
  echo "Skipping notarization (SNAPORA_NOTARY_PROFILE not set)."
fi

echo "Packaged $DMG"
