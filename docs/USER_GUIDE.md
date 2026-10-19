# Snapora User Guide

Snapora lives in the menu bar (camera icon). It has no Dock icon. Everything
you capture stays on your Mac.

## First launch

1. Take any capture, for example press **⌥⇧3**.
2. macOS asks for **Screen Recording** permission. Turn Snapora on in
   **System Settings → Privacy & Security → Screen Recording**.
3. Quit Snapora from the menu bar and open it again. macOS only applies the
   permission after a relaunch.

Recording with the microphone asks for **Microphone** permission the first time.

## Shortcuts

| Shortcut | Action |
|---|---|
| ⌥⇧1 | All-in-One: screenshot or record; area, window, or display |
| ⌥⇧2 | Capture a window |
| ⌥⇧3 | Capture fullscreen (pick a display when several are connected) |
| ⌥⇧4 | Capture an area |
| ⌥⇧5 | Start recording; press again to stop |
| ⌥⇧6 | Capture the previous area again |
| ⌥⇧O | Capture text (OCR) to the clipboard |

The defaults avoid macOS's own ⌘⇧3/4/5 shortcuts. If another app already uses
one, the menu tells you which shortcut is unavailable.

## The capture overlay

When you pick an area, window, or display, the screen dims and a **capture
bar** appears at the bottom.

- **Area**: drag to select. Click a window instead of dragging to capture it.
- **Window**: hover to highlight, click to choose.
- **Display**: hover a monitor, click to choose.

Keys: `A` area · `W` window · `F` display · `Space` toggles area/window ·
`Return` confirms (or captures the display under the pointer) · `Esc` clears
the selection, then cancels.

In All-in-One (⌥⇧1) the bar also switches between **Screenshot** and **Record**.

## Quick Access

After a capture, a card appears in the bottom-left corner:

- **Copy** – image (or video file) to the clipboard
- **Save** – into your save folder (Settings → General)
- **Edit** – open the image or video editor (double-click works too)
- **Pin** – float the screenshot above all windows
- **Drag** the card into Finder, Slack, Mail, a browser…

Change what happens after a capture or recording in **Settings → General**:
show Quick Access, save and copy, or open the editor directly.

## Image editor

Tools (with keys): Select `V`, Arrow `A`, Line `L`, Rectangle `R`, Ellipse `O`,
Text `T`, Pen `P`, Counter `N`, Highlight `H`, Spotlight `S`, Blur `B`,
Pixelate `X`, Redact `D`, Crop `C`.

- Drag to draw. Hold Shift for straight lines and squares.
- Select tool: click to select, drag to move, Delete to remove, arrows nudge.
- **Background**: wrap the screenshot in a gradient or solid background with
  padding, rounded corners, shadow, and an aspect ratio.
- Undo/redo: ⌘Z / ⇧⌘Z. Zoom: ⌘+ / ⌘− / ⌘0 (fit) / ⌘1 (actual size).
- ⌘C copies, ⌘S saves "‹name› edited.png", ⇧⌘S Save As (PNG or JPEG).
- **Done** copies the result, saves "‹name› edited.png", and puts it in Quick
  Access in place of the original.

> **Sensitive information:** use **Redact**. It is a solid fill baked into the
> exported pixels and cannot be undone by anyone who receives the file. Blur
> and pixelate are strong but cosmetic.

## Screen recording

Press **⌥⇧5** (or choose Record in All-in-One), then pick an area, window, or
display. In the capture bar you can set:

- Microphone (choose the input device from the menu)
- System audio
- Cursor visibility
- 30 or 60 fps

Press **Record** or Return. A small control bar shows the time with Pause,
Stop, and Discard. Press **⌥⇧5** again to stop.

A red dashed border marks the recorded area. Snapora's own windows never
appear in recordings.

## Video editor

Opened from a recording's Quick Access card (**Edit**) or from history.

- Drag the yellow handles to **trim**; drag elsewhere on the strip to scrub.
- **Quality**: Low, Medium, High, Ultra.
- **Dimensions**: Original, 1080p, 720p, 480p, 50%, or custom.
- **Audio**: keep, convert to mono, mute, or change volume (0–200%).
- **Format**: MP4 or GIF (choose the GIF frame rate).
- **Crop**: the crop button at the top-right of the preview.
- The estimated file size updates as you change options.
- **Convert** saves a new file; the original recording is never changed.

## More

- **Scrolling capture**: choose an area, then scroll slowly. Snapora stitches
  the frames and warns if a join may be inaccurate.
- **Capture text (OCR)**: ⌥⇧O, select an area, the text is copied.
- **Self-timer**: menu → Self-Timer (set the delay in Settings → Capture).
- **History**: menu → Capture History. Search, filter, favorite, reopen.
- **Pinned screenshots**: right-click a pin for opacity, lock (click-through),
  copy, or close. Unlock locked pins from the menu bar.

## Where files go

| What | Where |
|---|---|
| Captures and recordings | `~/Library/Application Support/Snapora/` |
| Saved copies | Your save folder (Desktop by default) |
| History database | `~/Library/Application Support/Snapora/history.sqlite` |

## Troubleshooting

**Captures fail or show only the wallpaper.** Screen Recording permission is
missing or stale. Reset it and grant it again:

```bash
tccutil reset ScreenCapture com.snapora.app
```

Then capture once, enable Snapora in System Settings, and relaunch Snapora.

**"Apple could not verify "Snapora" is free of malware…"** Release builds are
not notarized yet. Click **Done**, open **System Settings → Privacy &
Security**, scroll down, and click **Open Anyway** next to the Snapora message.
Or run:

```bash
xattr -dr com.apple.quarantine /Applications/Snapora.app
```
