# Snapora

Local-first screenshot and screen-recording app for macOS, inspired by
CleanShot X workflows. Rust core + Swift/SwiftUI/AppKit shell. See
[spec.md](spec.md) for the product and engineering plan.

## Features

| Shortcut | Action |
|---|---|
| ⌥⇧1 | All-in-One: screenshot or record; area, window, or display |
| ⌥⇧2 | Capture window |
| ⌥⇧3 | Capture fullscreen (pick a display when several are connected) |
| ⌥⇧4 | Capture area (Space toggles window picking) |
| ⌥⇧5 | Record: choose area / window / display, set audio, then Record; press again to stop |
| ⌥⇧6 | Capture previous area |
| ⌥⇧O | Capture text (OCR) |

- Quick Access preview: copy, save, drag, edit, pin
- Image editor: arrows, shapes, text, pen, counters, highlight, spotlight,
  blur, pixelate, redact, crop, rotate, background styling, undo/redo
- Screen recording to MP4 (H.264/HEVC) with pause, system audio, microphone
- Video editor: trim, crop, mute, MP4 and GIF export
- Scrolling capture, self-timer, hide desktop icons
- Capture history with search and favorites; pinned screenshots
- Everything stays local; nothing is uploaded

In the capture overlay: `A` area, `W` window, `F` display, Space toggles
area/window, Return confirms, Esc clears the selection or cancels.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Rust (stable, 1.85+) via rustup
- Xcode Command Line Tools (Swift 5.9+). Full Xcode is not required.

## Build & run

```bash
make test     # Rust unit tests
make dmg      # build/Snapora-<version>.dmg (signs/notarizes if configured)
make debug    # build/debug/Snapora.app
make run      # build debug and launch
make app      # build/release/Snapora.app
```

Snapora is a menu-bar app (camera icon); it has no Dock icon.

On first capture macOS asks for **Screen Recording** permission. Enable
Snapora in System Settings → Privacy & Security → Screen Recording, then
relaunch the app.

### Signing

Builds are ad-hoc signed by default, so macOS treats every rebuild as a new
app and asks for Screen Recording permission again. To keep the permission,
create a self-signed certificate once (Keychain Access → Certificate
Assistant → Create a Certificate…, name **Snapora Development**, Self Signed
Root, Code Signing); the build script uses it automatically. Reset a stale
permission entry with `tccutil reset ScreenCapture com.snapora.app`.

To sign with a Developer ID instead:

```bash
SNAPORA_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make app
```

### Logs

Rust logs go to stderr; filter with `SNAPORA_LOG=debug`. Run the binary
directly to see them:

```bash
SNAPORA_LOG=debug build/debug/Snapora.app/Contents/MacOS/Snapora
```

## Layout

```
crates/core            platform-neutral core (geometry, naming, documents)
crates/ffi             UniFFI bindings exposed to Swift
crates/uniffi-bindgen  bindgen CLI used by scripts/build-rust.sh
macos/                 SwiftPM package for the macOS app
scripts/               build scripts
```

## Known limitations

- Not yet verified on real hardware; see [docs/TESTING.md](docs/TESTING.md).
- System audio and microphone are separate audio tracks (not mixed).
- Scrolling capture is manual (you scroll); it flags uncertain joins.
- GIF export is capped at 1280 px wide and 600 frames.
- Only solid Redact is fully irreversible; blur/pixelate are cosmetic.
