# Changelog

All notable changes to Snapora are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- Camera overlay for screen recordings: choose a camera, circle or rounded
  shape, and size; the draggable bubble is recorded in area and display
  recordings.
- Open images and videos with Snapora from Finder (Open With).

## [0.1.0] - 2026-10-19

First public preview for macOS 14 Sonoma or later on Apple Silicon.

### Added

- **Screenshots**: area, window (with or without shadow), fullscreen with a
  display picker on multi-monitor setups, previous area, self-timer, and
  All-in-One mode.
- **Capture bar** on the selection overlay to switch between area, window, and
  display, and between screenshot and recording.
- **Quick Access** cards after every capture and recording: copy, save, drag,
  edit, pin.
- **Image editor**: arrow, line, rectangle, ellipse, text, pen, counter,
  highlight, spotlight, blur, pixelate, redact, crop, rotate, background
  styling, undo/redo; Done saves an edited copy and shows it in Quick Access.
- **Screen recording** of an area, window, or display to MP4 (H.264/HEVC) with
  pause/resume, system audio, microphone with device selection, and cursor
  options.
- **Video editor**: trim, crop, quality, dimensions, audio (mono, mute,
  volume), MP4 or GIF export with an estimated file size.
- **Scrolling capture** with automatic stitching and uncertainty warnings.
- **Text recognition (OCR)** on-device with Vision.
- **Capture history** with thumbnails, search, filters, favorites, and
  retention.
- **Pinned screenshots** with zoom, opacity, and click-through lock.
- **Settings window** (General, Capture, Recording, Shortcuts, About).
- Global shortcuts ⌥⇧1–6 and ⌥⇧O.

### Known limitations

- Builds are not notarized yet; Gatekeeper asks for confirmation on first open.
- Apple Silicon only.
- System audio and microphone are recorded as separate audio tracks.
- Shortcuts are not yet customizable.

[0.1.0]: https://github.com/fazleyrabby/snapora/releases/tag/v0.1.0
