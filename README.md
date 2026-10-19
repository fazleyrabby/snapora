<p align="center">
  <img src="docs/assets/icon.png" width="128" height="128" alt="Snapora icon">
</p>

<h1 align="center">Snapora</h1>

<p align="center">
  Screenshots and screen recordings for macOS, kept local.<br>
  Capture, annotate, record, trim, and share — without leaving your flow.
</p>

<p align="center">
  <a href="https://github.com/fazleyrabby/snapora/releases/download/v0.1.0/Snapora-0.1.0.dmg"><b>Download for macOS</b></a> ·
  <a href="docs/USER_GUIDE.md">User Guide</a> ·
  <a href="CHANGELOG.md">Changelog</a>
</p>

---

Snapora is a native menu-bar app inspired by the CleanShot X workflow. It is
written in Swift (SwiftUI/AppKit) on top of a platform-neutral Rust core, uses
Apple's ScreenCaptureKit, Vision, and AVFoundation, and never uploads anything.

## Features

- **Screenshots** — area, window (with shadow or transparent), fullscreen with a
  display picker for multiple monitors, previous area, self-timer
- **Capture bar** — switch between area / window / display and screenshot /
  recording right on the overlay
- **Quick Access** — a floating card after every capture: copy, save, drag,
  edit, pin
- **Image editor** — arrows, shapes, text, pen, counters, highlight, spotlight,
  blur, pixelate, redact, crop, rotate, beautiful backgrounds, undo/redo
- **Screen recording** — area, window, or display to MP4 with pause, system
  audio, microphone selection, cursor and fps options
- **Video editor** — trim, crop, quality, dimensions, mono/mute/volume, MP4 or
  GIF export with file size estimate
- **Scrolling capture**, **text recognition (OCR)**, **capture history**,
  **pinned screenshots**
- **Private by design** — everything stays on your Mac

## Install

1. Download [`Snapora-0.1.0.dmg`](https://github.com/fazleyrabby/snapora/releases/download/v0.1.0/Snapora-0.1.0.dmg)
   (all versions on the [releases page](https://github.com/fazleyrabby/snapora/releases)).
2. Open the DMG and drag **Snapora** to **Applications**.
3. The preview build is not notarized yet. On first launch, right-click
   Snapora.app → **Open** → **Open** (or run
   `xattr -dr com.apple.quarantine /Applications/Snapora.app`).
4. Take a capture with **⌥⇧3**, allow **Screen Recording** in System Settings,
   then quit and reopen Snapora.

Requires macOS 14 Sonoma or later on Apple Silicon.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌥⇧1 | All-in-One: screenshot or record; area, window, or display |
| ⌥⇧2 | Capture window |
| ⌥⇧3 | Capture fullscreen (pick a display when several are connected) |
| ⌥⇧4 | Capture area |
| ⌥⇧5 | Record screen; press again to stop |
| ⌥⇧6 | Capture previous area |
| ⌥⇧O | Capture text (OCR) |

In the overlay: `A` area · `W` window · `F` display · `Space` toggle ·
`Return` confirm · `Esc` cancel. See the [User Guide](docs/USER_GUIDE.md) for
everything else.

## Build from source

Requirements: macOS 14+, Apple Silicon, [Rust](https://rustup.rs) (stable), and
the Xcode Command Line Tools (`xcode-select --install`). Full Xcode is not
needed.

```bash
git clone https://github.com/fazleyrabby/snapora.git
cd snapora
make run      # build a debug app and launch it
```

| Command | What it does |
|---|---|
| `make test` | Rust unit tests |
| `make debug` | `build/debug/Snapora.app` |
| `make run` | Build debug and launch |
| `make app` | `build/release/Snapora.app` |
| `make dmg` | `build/Snapora-<version>.dmg` |

### Signing

Builds are ad-hoc signed by default, so macOS treats every rebuild as a new app
and asks for Screen Recording permission again. To keep the permission across
rebuilds, create a self-signed certificate once (Keychain Access → Certificate
Assistant → Create a Certificate…, name **Snapora Development**, Self Signed
Root, Code Signing). The build script picks it up automatically.

For distribution, sign with a Developer ID and notarize:

```bash
SNAPORA_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
SNAPORA_NOTARY_PROFILE="notary-profile" make dmg
```

### Logs

```bash
SNAPORA_LOG=debug build/debug/Snapora.app/Contents/MacOS/Snapora
```

## Project layout

```text
crates/core            geometry, file naming, recording timeline, scroll stitcher
crates/editor          image document model and undo/redo
crates/history         SQLite capture history
crates/ffi             UniFFI bindings exposed to Swift
macos/                 SwiftPM package for the macOS app
scripts/               build, packaging, and icon scripts
docs/                  user guide, architecture, decisions, testing
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit
together and [docs/TESTING.md](docs/TESTING.md) for the release checklist.

## Roadmap

- Notarized builds and automatic updates
- Customizable shortcuts
- Intel support
- Windows and Linux (the Rust core is already platform-neutral)

## License

[MIT](LICENSE) © [Fazley Rabbi](https://fazleyrabbi.xyz/)

Snapora is an independent project and is not affiliated with CleanShot X or
MTW.
