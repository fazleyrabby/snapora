# Testing

## Automated

```bash
make test        # all Rust unit tests (geometry, naming, recording timeline, editor, history, ffi)
```

## Manual checklist (run on a real Mac before each release)

Grant **Screen Recording** permission on first capture, then relaunch.
Ad-hoc signed builds may need re-granting after every rebuild.

### Capture (M1)
- [ ] ⌥⇧3 fullscreen saves a PNG with the expected pixel size (e.g. 3024×1964 on a 14" MBP).
- [ ] ⌥⇧4 region: crosshair, size label in pixels, Esc cancels, output matches selection.
- [ ] Space during region toggles window picking; click captures the window with shadow.
- [ ] ⌥⇧2 window capture with "Window Shadow" on and off (transparent background).
- [ ] ⌥⇧1 All-in-One: capture bar switches Screenshot/Record and Area/Window/Display.
- [ ] ⌥⇧3 with an external monitor: hover highlights a display, click captures that display only.
- [ ] Capture bar is clickable and never captured; hovering it does not highlight windows behind it.
- [ ] ⌥⇧6 previous area repeats the last region.
- [ ] Self-timer counts down in the menu and can be cancelled.
- [ ] "Hide Desktop Icons" removes Finder desktop icons from the output.
- [ ] Two displays, incl. one left of / above the primary and with different scale.
- [ ] Selection across a display edge is clipped to the start display.
- [ ] Permission denied: menu shows the grant button; no crash.

### Quick Access (M2)
- [ ] Card appears bottom-left without stealing focus from the frontmost app.
- [ ] Copy → paste into another app; Save → file in save folder; drag into Finder/Slack.
- [ ] Five+ captures stack and drop the oldest; auto-close pauses on hover.
- [ ] Works over fullscreen apps and on other Spaces.

### Editor (M3)
- [ ] Each tool draws; select/move/delete; undo/redo across all edits.
- [ ] Crop + rotate render in canvas and export.
- [ ] **Redaction:** export, reopen the PNG in Preview, confirm no underlying content in redacted, blurred and pixelated areas.
- [ ] Transparent window captures keep alpha in PNG; JPEG flattens on white.

### Recording (M4)
- [ ] ⌥⇧5 → Area: drag, adjust with handles/move, Return or Record starts; Esc clears selection.
- [ ] ⌥⇧5 → Window: click selects a window, Record starts window recording.
- [ ] ⌥⇧5 → Display: choose each monitor; recording covers only that display.
- [ ] Mic / system audio / cursor / fps toggles in the bar apply to the recording.
- [ ] Control bar shows timer; red dashed border and controls are NOT in the video.
- [ ] Pause/resume leaves no gap or frozen segment in the output.
- [ ] System audio and microphone tracks present and in sync after 10+ minutes.
- [ ] Discard deletes the partial file. Window recording follows the window.
- [ ] HEVC toggle produces a playable file.
- [ ] Disk nearly full: recording fails with a message, app stays usable.

### Video editor / GIF (M5)
- [ ] Trim, crop with aspect presets, mute, MP4 export plays in QuickTime.
- [ ] GIF export at each fps/width; loops; memory stays flat on a long clip.

### History & pins (M6)
- [ ] Captures and recordings appear with thumbnails; search, filters, favorites.
- [ ] Deleting a file outside the app shows "File missing".
- [ ] Pin: move, zoom, opacity, lock (click-through) and unlock from the menu bar.

### OCR (M7)
- [ ] ⌥⇧O → select text → clipboard contains the text with line breaks.
- [ ] Selecting an area without text reports "No text found".
