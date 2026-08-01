# Files, naming and retention

How a capture becomes a file: what it's called, how it's encoded, and when
it's cleaned up.

## Filename templates

`Services/FilenameTemplate.swift` renders the user's template
(`AppSettings.filenameTemplate`) against a `FilenameContext` built by
`CaptureCoordinator` at capture time.

The default template is `QuickSnap {date} at {time}`, which reproduces the
original hardcoded convention **byte for byte** — anyone who never opens the
setting sees no change.

| Token | Value |
| --- | --- |
| `{date}` `{time}` | `2026-08-01`, `12.30.45` |
| `{year}` `{month}` `{day}` | Individually, zero-padded |
| `{app}` | Captured window's app, else the frontmost app |
| `{window}` | Captured window's title |
| `{width}` `{height}` | Pixel dimensions of the final image |
| `{counter}` | Persisted, increments per capture |
| `{random}` | Six random characters |
| `{describe}` | What the capture shows, as a slug — see below |

Design decisions worth not re-litigating:

- **Unknown tokens are left visible** (`{nope}` renders as `{nope}`) rather
  than silently deleted, so a typo shows up in the settings preview instead
  of quietly producing the wrong name.
- **Unavailable tokens collapse cleanly.** `{app} shot {window}` with
  neither available renders `shot`, not `" shot "` — sanitization collapses
  whitespace runs and trims.
- **Empty results fall back to the default template.** A template of only
  unavailable tokens would otherwise produce a nameless file.
- **Local time, not UTC.** A capture taken at 12:30 is named `12.30`.
- **Collisions get a numeric suffix** (`name 2.png`). Templates without a
  time or counter token — `{app}` alone — collide constantly, and silently
  overwriting the previous capture would be the worst outcome.
- Illegal characters (`/ : \ ? % * | " < >`) are stripped, leading dots
  removed (they'd hide the file), and the name capped at 200 bytes.

`{app}` resolves correctly because the selection overlays are
**non-activating panels** — the user's app stays frontmost during a capture
session, so `NSWorkspace.frontmostApplication` is what they were actually
looking at. Don't reintroduce an `NSApp.activate` on the capture path (see
CLAUDE.md) or this silently starts naming everything "QuickSnap".

## `{describe}` — naming a capture for what it shows

`QuickSnap 2026-08-01 login-form-validation-error.png`. Switched on from
Settings → Intelligence (which appends the token to the template — the
template stays the single source of truth), and dependent on the
`AIProvider` seam; see `docs/intelligence.md`.

**The save never waits on a model.** A capture that isn't on disk until a
model answers is a capture that can be lost, and the round trip is seconds.
So the file is written immediately with the token rendered empty, and
renamed in place once the description arrives —
`CaptureCoordinator.describeAndRename`.

Three things make that work:

- **`ResolvedFilename`** keeps a name as its *inputs* (template, context,
  counter, random suffix) rather than as a finished string, so the second
  render reproduces the first exactly. Both `{counter}` and `{random}` would
  otherwise drift — `nextFilenameCounter()` advances on every call, and the
  random suffix used to be drawn inside `render`. That last one was a real
  bug caught by the standalone test below: the rename moved the file to a
  name sharing nothing with the one it was written under. `render` now takes
  the suffix as a parameter and is fully deterministic.
- **The rename is a move within the folder** (`ScreenshotSaver.rename`), so
  the `FileTag` xattr rides along and retention still recognises the file.
  Verified, not assumed: `FileManager.moveItem` preserves extended
  attributes within a volume. **Don't reimplement this as copy-then-delete**
  — that drops the tag and orphans the file from cleanup.
- **`CaptureFile`** is a reference box holding where the capture currently
  is. The preview panel is on screen and an annotation window may already be
  open when the rename lands, both holding the original URL; they observe
  the box instead, so Reveal in Finder, drag-out and the window title follow
  the file. The one exception is the annotation toolbar's drag-out *name*,
  whose closure is `@Sendable` and off-main — it keeps the pre-rename stem,
  which is cosmetic (nothing reads the original file).

Every failure falls back to the name the file already has, which is a
complete name in its own right: intelligence off, provider unavailable,
model returns nothing, or a slug that sanitizes away to nothing (an
all-emoji description). The rename is skipped when the re-rendered name
equals the original.

**Slug hygiene is a whitelist, not a blacklist.** The description is model
output going into a filesystem call, so `FilenameTemplate.slug` keeps only
`a`–`z` and `0`–`9`, turns every other character into a separator, folds
accents, and truncates on a word boundary at 48 characters. Path
separators, leading dots and Finder-hostile characters can't get through by
construction.

### Verifying

`FilenameTemplate` depends only on Foundation, so it compiles standalone:

```
swiftc -O FilenameTemplate.swift main.swift -o fntest && ./fntest
```

Build the date fixture with `TimeZone.current`, not UTC — the formatter
renders local time by design, and a UTC fixture produces four confusing
false failures.

## Image formats

`ImageFormat` (PNG / JPEG / HEIC) with `AppSettings.imageFormat` and
`imageQuality`. `ScreenshotSaver.imageData(_:format:quality:)` is the single
encoder for disk writes, drag-out files and uploads alike.

Two behaviours that aren't obvious:

- **Transparency wins over the format setting.** `effectiveFormat(for:)`
  silently keeps a capture as PNG when it has real alpha and the requested
  format is JPEG. A transparent window capture flattened onto black is never
  what someone wants; the file is just bigger than asked for.
- **Annotation drag-out is always PNG.** `AnnotatedFileDrag` declares a
  *static* `FileRepresentation(exportedContentType: .png)`, so the file on
  disk has to match what the drop destination was promised. The preview
  panel's drag has no such constraint (it drags a real file URL) and follows
  the format setting.

HEIC goes through `CGImageDestination` because `NSBitmapImageRep` has no
HEIC writer.

## Retention

`Services/SaveFolderCleaner.swift`, off by default, run once at launch from
`CaptureCoordinator` and on demand from Settings → Advanced.

This deletes files from a **user-chosen folder** in an **unsandboxed** app,
so it has two non-negotiable safety properties:

1. **Only files carrying QuickSnap's extended attribute are touched.**
   `FileTag` sets `com.dylanduff.quicksnap.managed` on every file the app
   writes; the cleaner refuses to consider anything without it. Point the
   save folder at `~/Documents` and your own files are still safe.
2. **Never recursive.** Only the folder's immediate contents are scanned, so
   a nested project directory can't be walked into.

Plus: files go to the **Trash** (`trashItem`), not `removeItem`.

Matching on the filename template instead was rejected as fragile — the
template is user-editable and changes over time, so yesterday's captures
wouldn't match today's pattern.

The failure mode is deliberately one-directional: if the xattr is lost (a
copy across a filesystem that doesn't support extended attributes, some
backup restores), the file is treated as *not ours* and kept. **Retention
under-deletes rather than over-deletes.**

`countExpired(olderThan:in:)` backs the settings preview so the blast radius
is visible before anything happens, and the action is confirmation-gated.

Both entry points run off the main thread — enumerating a TCC-protected
folder can block inside the syscall on first access (see CLAUDE.md).

## Advanced settings, and what doesn't belong there

Settings → Advanced is deliberately **not** a bucket for power-user
features. Anything a user would go looking for belongs on the page it
relates to — filename templates and image format are in General, next to the
save folder, because burying them would hurt discoverability.

What lands in Advanced is the narrow category of *diagnostic or
destructive*:

- **Permissions** — live Screen Recording status, re-check, open System
  Settings, and the relaunch caveat. This targets the app's most common
  source of "it's broken" confusion: macOS keeps reporting the old answer to
  an already-running process.
- **Upload timeout and retries** — tuning, not configuration.
- **Retention** — destructive.
- **Copy Diagnostics** — a redacted summary for bug reports. Deliberately
  excludes server addresses, bucket names, key prefixes and the save folder
  path, because people paste this into public issue trackers; it reports
  *whether* a custom save folder is set, not what it is.
- **Reset All Settings** — enumerates `AppSettings.Keys` explicitly rather
  than wiping the whole UserDefaults domain, so nothing outside our own keys
  is removed. Also clears both Keychain secrets.

## Launch at login

`Services/LoginItem.swift` wraps `SMAppService.mainApp` — the modern
replacement for the deprecated helper-app dance; the app registers itself,
no helper bundle.

State lives with the **system**, not UserDefaults: the user can revoke it in
System Settings → General → Login Items, so `isEnabled` reads
`SMAppService.mainApp.status` every time rather than trusting a stored flag.
`setEnabled` returns whether it actually took, and the toggle snaps back if
registration throws. `requiresApproval` surfaces its own row with a button
into System Settings.
