# Architecture

Snapora is a Swift/AppKit menu-bar app with a platform-neutral Rust core.

```text
Swift app (macos/App)                      macOS-only
  Capture/        selection overlay, ScreenCaptureKit stills, scrolling capture
  Recording/      SCStream + AVAssetWriter recorder, controls, microphones
  QuickAccess/    floating preview cards
  Editor/         image editor (canvas, tools, renderer, export, background)
  VideoEditor/    trim/crop/quality/audio editor, MP4 + GIF export
  History/        history service and window
  Pin/            pinned screenshots
  OCR/            Vision text recognition
  System/         settings, hotkeys, permissions, about
  Export/         capture store, PNG writer
  Generated/      UniFFI bindings (generated, not committed)
        │
        ▼  UniFFI (typed records, enums, objects)
Rust workspace (crates/)                   platform-neutral
  core            geometry, file naming, recording timeline, scroll stitcher
  editor          image document model, annotations, undo/redo, JSON
  history         SQLite capture history, retention, search
  ffi             thin UniFFI layer over the crates above
  uniffi-bindgen  bindings generator used by the build
```

## Principles

- **The Rust core never imports macOS APIs**, so Windows and Linux shells can
  reuse it later.
- **Typed commands**: menu items, shortcuts, and the capture bar all dispatch
  the same actions through `AppModel`.
- **Nondestructive editing**: sources are immutable; edits are a document of
  annotations plus crop/rotation, flattened only on export.
- **Privacy**: logs never contain pixels, recognized text, or window titles.
  Nothing is uploaded.

## Coordinates

All capture geometry lives in `crates/core/src/geometry.rs`. The canonical
space is global points with a top-left origin (Core Graphics /
ScreenCaptureKit). AppKit rects (bottom-left origin) are flipped with
`appkit_to_global`. Pixel rects are display-local and rounded outward.

## Recording

`ScreenRecorder` receives frames and audio from `SCStream` on one serial
queue and appends them to `AVAssetWriter`. The pause-aware timeline
(`crates/core/src/recording.rs`) maps host timestamps to output time, drops
samples captured during pauses, and fixes the file length at the stop time.

## Redaction

Redact, blur, and pixelate are rendered into the exported bitmap; exports
are flat PNG/JPEG without annotation data. Blur and pixelate draw over an
opaque base so no source pixel can show through. Debug builds verify sampled
pixels in every destructive region after export.

## Build pipeline

1. `scripts/build-rust.sh` builds `libsnapora_ffi.a` and generates Swift
   bindings into `macos/Generated` and `macos/App/Generated`.
2. `swift build` compiles the SwiftPM package in `macos/`.
3. `scripts/build-app.sh` assembles and signs `Snapora.app`.
4. `scripts/package.sh` creates the DMG (and notarizes when configured).

See [DECISIONS.md](DECISIONS.md) for the reasoning behind these choices.
