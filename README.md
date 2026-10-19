# Snapora

Local-first screenshot and screen-recording app for macOS, inspired by
CleanShot X workflows. Rust core + Swift/SwiftUI/AppKit shell. See
[spec.md](spec.md) for the product and engineering plan.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Rust (stable, 1.85+) via rustup
- Xcode Command Line Tools (Swift 5.9+). Full Xcode is not required.

## Build & run

```bash
make test     # Rust unit tests
make debug    # build/debug/Snapora.app
make run      # build debug and launch
make app      # build/release/Snapora.app
```

Snapora is a menu-bar app (camera icon); it has no Dock icon.

On first capture macOS asks for **Screen Recording** permission. Enable
Snapora in System Settings → Privacy & Security → Screen Recording, then
relaunch the app.

### Signing

Builds are ad-hoc signed by default, so macOS may ask for permission again
after each rebuild. To use a real identity:

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
