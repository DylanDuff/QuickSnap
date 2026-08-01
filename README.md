# QuickSnap

Menu bar screenshot utility for macOS, inspired by CleanShot X. Lives in the menu bar (no Dock icon), captures via ScreenCaptureKit, and keeps the whole flow on-device.

## Features

- **Capture modes** — area (drag to select), window (hover to highlight), and full screen, working across multiple displays.
- **Text recognition** — select an area and the recognized text (Vision OCR) goes straight to the clipboard.
- **MCP server** — let an AI coding agent capture through QuickSnap: screenshot a named window or display, read text off the screen with on-device OCR, search your saved captures by what's in them, or fetch a capture you just took, without you handling a single file. Off by default; enable it in Settings → Intelligence, which prints the client configuration to paste. Listens only on `127.0.0.1`, behind a token kept in the Keychain.
- **Copy for AI** — one shortcut copies the screenshot *and* its context (the app it came from, when it was taken, and the text QuickSnap can read in it) as a markdown block, so a single paste gives a chat or coding tool the whole picture instead of a bare image.
- **Search your captures** — everything QuickSnap saves is indexed on the way to disk (the text in the image, plus what it shows when Apple Intelligence is on), so ⌘⇧2 opens a Spotlight-style panel that finds "that Immich settings page from last week" by what was written in it. Return reveals it in the Finder, ⌘Return opens it for markup. The index is a local SQLite database in Application Support and only ever reads files QuickSnap itself saved.
- **After capture** — save to disk, copy to the clipboard, and show a floating preview thumbnail; each action individually toggleable.
- **Preview panel** — a PIP-style floating thumbnail with quick actions: reveal in Finder, copy, edit, or drag the file out into another app.
- **Annotation editor** — PencilKit-backed markup canvas (via PaperKit) with pen, highlighter, eraser, shapes, arrows, text, crop, color and stroke-width presets. Exports flattened at full resolution via Copy, one-click Save, Save As, or dragging the file straight into another app; the original file is never overwritten. Default color, default stroke size, and which export buttons show are configurable in Settings → Markup.
- **Uploading** — push captures to [Immich](https://immich.app) or any S3-compatible bucket (Cloudflare R2, Backblaze B2, MinIO, Wasabi, DigitalOcean Spaces, AWS), automatically after each capture or on demand from the preview panel and markup toolbar. Optionally copies a shareable link to the clipboard. Configured in Settings → Uploading; credentials are stored in the Keychain.
- **File naming & formats** — token-based filename templates (`{app}`, `{window}`, `{date}`, `{counter}`…) with a live preview, and PNG / JPEG / HEIC output with a quality setting. With Apple Intelligence on, `{describe}` names a capture for what it shows — `QuickSnap 2026-08-01 login-form-validation-error.png` — resolved after the file is written, so a save never waits on a model.
- **Housekeeping** — optional retention that moves captures older than N days to the Trash, and only ever touches files QuickSnap itself saved.
- **Window backgrounds** — window captures can be composited onto your wallpaper or a solid color with padding and a soft shadow.
- **Global hotkeys** — configurable in Settings; defaults below.

| Action | Default shortcut |
| --- | --- |
| Capture area | ⌘⇧7 |
| Capture window | ⌘⇧8 |
| Capture full screen | ⌘⇧9 |
| Recognize text (OCR) | ⌘⇧0 |
| Copy for AI | ⌘⇧1 |
| Search captures | ⌘⇧2 |

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
- [mcp.md](docs/mcp.md) — the MCP server: why it's HTTP rather than stdio, what the tools do, and how the socket is secured.
- [intelligence.md](docs/intelligence.md) — the Copy for AI clipboard hand-off, the on-device `AIProvider` seam (including what the system model can't do), and `{describe}` filenames.
- [search.md](docs/search.md) — the FTS5 capture index, how it keeps up with the folder, and the search panel.
