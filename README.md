# QuickSnap

Menu bar screenshot utility for macOS, inspired by CleanShot X. Lives in the menu bar (no Dock icon), captures via ScreenCaptureKit, and keeps the whole flow on-device.

## Features

- **Capture modes** — area (drag to select), window (hover to highlight), and full screen, working across multiple displays.
- **Text recognition** — select an area and the recognized text (Vision OCR) goes straight to the clipboard.
- **After capture** — save to disk, copy to the clipboard, and show a floating preview thumbnail; each action individually toggleable.
- **Preview panel** — a PIP-style floating thumbnail with quick actions: reveal in Finder, copy, edit, or drag the file out into another app.
- **Annotation editor** — PencilKit-backed markup canvas (via PaperKit) with pen, highlighter, eraser, shapes, arrows, text, crop, color and stroke-width presets. Exports flattened at full resolution via Copy, one-click Save, Save As, or dragging the file straight into another app; the original file is never overwritten. Default color, default stroke size, and which export buttons show are configurable in Settings → Markup.
- **Uploading** — push captures to [Immich](https://immich.app) or any S3-compatible bucket (Cloudflare R2, Backblaze B2, MinIO, Wasabi, DigitalOcean Spaces, AWS), automatically after each capture or on demand from the preview panel and markup toolbar. Optionally copies a shareable link to the clipboard. Configured in Settings → Uploading; credentials are stored in the Keychain.
- **File naming & formats** — token-based filename templates (`{app}`, `{window}`, `{date}`, `{counter}`…) with a live preview, and PNG / JPEG / HEIC output with a quality setting.
- **Housekeeping** — optional retention that moves captures older than N days to the Trash, and only ever touches files QuickSnap itself saved.
- **Window backgrounds** — window captures can be composited onto your wallpaper or a solid color with padding and a soft shadow.
- **Global hotkeys** — configurable in Settings; defaults below.

| Action | Default shortcut |
| --- | --- |
| Capture area | ⌘⇧7 |
| Capture window | ⌘⇧8 |
| Capture full screen | ⌘⇧9 |
| Recognize text (OCR) | ⌘⇧0 |

Screenshots are saved as `QuickSnap yyyy-MM-dd at HH.mm.ss.png` in `~/Documents/QuickSnap` by default. The folder, filename template, and image format are all configurable in Settings.

## Requirements

- macOS 26.5 or later
- Xcode 26 to build

## Building

```
xcodebuild -project QuickSnap.xcodeproj -scheme QuickSnap -configuration Debug build
```

Or open `QuickSnap.xcodeproj` in Xcode and run the `QuickSnap` scheme.

## Permissions

QuickSnap needs **Screen Recording** access (System Settings → Privacy & Security). macOS often doesn't apply a freshly granted permission to an already-running process — relaunch QuickSnap after granting it.

The app is **not sandboxed** so it can write captures directly to the save folder without a save panel on every shot. This means it isn't Mac App Store-distributable as-is.

## Project layout

```
QuickSnap/
  QuickSnapApp.swift     — MenuBarExtra entry point
  Views/                 — UI only (overlay, preview, annotation, settings)
  Coordinators/          — state + window lifecycles; wire Views to Services
  Services/              — stateless operations: capture, file I/O, OCR, settings
```

Architecture notes, layering rules, and the non-obvious platform gotchas are documented in [CLAUDE.md](CLAUDE.md). Developer reference docs live in [docs/](docs/):

- [motion-design.md](docs/motion-design.md) — house animation and feedback conventions.
- [files-and-retention.md](docs/files-and-retention.md) — filename templates, image formats, and how retention safely deletes only QuickSnap's own files.
- [uploading.md](docs/uploading.md) — the upload provider architecture, the Immich and S3 integrations, how the SigV4 signing is verified, and the ATS setup for LAN servers.
