# Decisions

## D1 — Rust/Swift boundary: UniFFI, Swift host process
Swift app is the process host; Rust core is linked as a static library.
UniFFI 0.32 (proc-macro mode, library-mode bindgen) generates Swift
bindings. The `ffi` crate only converts types; logic lives in `core`, which
has no UniFFI or macOS dependencies so future Windows/Linux shells can reuse it.

## D2 — Build system: SwiftPM + scripts, not an Xcode project
Full Xcode is not required to build. `scripts/build-app.sh` builds Rust,
runs `swift build`, assembles `Snapora.app`, and codesigns it (ad-hoc by
default). An Xcode project can be added later if needed for the App Store.
Swift 5 language mode because generated bindings are not Swift 6
strict-concurrency clean.

## D3 — Capture framework: ScreenCaptureKit only
`SCScreenshotManager` for stills (macOS 14+), `SCStream` for recording.
No deprecated `CGWindowListCreateImage`.

## D4 — Coordinate model
All geometry lives in `snapora-core::geometry`. Canonical space is global
points with a top-left origin (Core Graphics / ScreenCaptureKit). AppKit
rects are converted with `appkit_to_global`. Pixel rects are display-local
and rounded outward, with float-noise snapping.

## D5 — No FFmpeg on macOS
AVFoundation/VideoToolbox for MP4, ImageIO for GIF.

## D6 — Dependencies reviewed (M0)
| Crate | Version | License | Notes |
|---|---|---|---|
| uniffi | 0.32 | MPL-2.0 | Mozilla-maintained, actively released |
| thiserror | 2 | MIT/Apache-2.0 | |
| chrono | 0.4 | MIT/Apache-2.0 | clock + std features only |
| tracing / tracing-subscriber | 0.1 / 0.3 | MIT | |
