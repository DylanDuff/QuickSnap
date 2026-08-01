# Intelligence

Three separate things live under this heading, and it's worth keeping them
apart:

- **Copy for AI** — a capture action that hands a screenshot *and its
  context* to whatever AI tool the user already uses. No model runs in
  QuickSnap at all.
- **The `AIProvider` seam** — the shared way features ask a model about a
  capture, with an on-device conformer.
- **`CaptureAnalyzer`** — the one pass that reads a capture (OCR plus a
  description), shared by everything downstream of a save.

---

## Copy for AI

`HotkeyAction.copyForAI`, default ⌘⇧1, also in the menu bar. Reuses the
drag-to-select overlay (`SelectionSessionKind.copyForAI`) and ends in
`CaptureCoordinator.copyContextForAI`.

The problem it solves: pasting a bare screenshot into a chat tool throws away
everything around it — which app it came from, what the window was called,
and any text in the image the model then has to re-read out of pixels. People
retype that by hand.

What lands on the clipboard:

```
![Screenshot](</var/folders/…/QuickSnap 2026-08-01 at 14.32.07.png>)
App: Xcode
Captured: 2026-08-01 14:32

Text in image:
error: value of type 'PaperMarkup' has no member 'insertNewShape'
```

Rendered by `CaptureContextMarkdown` (Services, pure function, no I/O).

### Decisions worth not re-litigating

**The image is referenced by path, not described as "attached."** The most
valuable reader is a coding agent that can open the file itself. Markdown
link destinations can't hold bare spaces and a default capture filename has
several, so the path is wrapped in `<…>` — the spec's own escape.

**One pasteboard item, two representations.** `ScreenshotSaver.copyToClipboard(_:text:)`
writes the markdown as `.string` and the PNG as `.png` on a single
`NSPasteboardItem`, so a terminal takes the text and a chat window takes the
picture. Two *items* wouldn't work — most readers only look at the first.
There is no way to control which representation a given app prefers, which is
the one real weakness here: an app that pastes images and ignores text will
silently drop the context. **This wants a real paste test against the tools
you actually use** (Claude Code, Claude desktop, a browser textarea) before
the format is considered settled.

This is also why `copyToClipboard(_ image:)` was left alone rather than
folded into the new call: it writes an `NSImage` and lets AppKit offer its
full set of representations, which is the more compatible write when there's
no text to carry.

**Captures go to a temp file, never the save folder.** Like the OCR flow, the
after-screenshot toggles deliberately don't apply — the clipboard *is* the
output. But the markdown needs a path to point at, so the image is written
via `ScreenshotSaver.writeTemporaryImage`. The user didn't ask to archive
this, and quietly filling their save folder with clipboard hand-offs would be
a surprise. Consequence: the path is valid for the OS's temp-file lifetime,
which is fine for a hand-off happening seconds later and wrong for anything
durable.

**Not ⌘⇧6**, the obvious neighbour of the existing ⌘⇧7/8/9/0 run: macOS
reserves it for capturing the Touch Bar, and `RegisterEventHotKey` fails
silently on a shortcut the system already owns.

The OCR pass is skipped entirely when Settings → General → Copy for AI →
"Include the text in the image" is off, and its failure is non-fatal — a
capture with no readable text still copies with its app and timestamp.

---

## The `AIProvider` seam

`Services/AIProvider.swift` — the protocol; `Services/FoundationModelsProvider.swift`
— the on-device conformer; `AppSettings.aiProvider` — the single place a
provider is built from settings.

Deliberately the same shape as `UploadDestination`, for the same reason.
Four proposed features (semantic filenames, capture search, redaction
suggestions, step docs) all need "ask a model about a capture"; without one
seam each grows its own client, settings and key handling.

### On-device first, and what that costs

The deployment target is macOS 26.5, so Apple's Foundation Models framework
is available unconditionally. For a tool that sees the user's screen that's
the right default: nothing leaves the machine, no API key, no per-capture
cost, so features can be offered without a privacy conversation.

**The system model takes no image input.** Its `respond` overloads accept
only `Prompt`/`String` — no image or attachment parameter. Verified against
the SDK's `.swiftinterface`, which is ground truth here:

```
$(xcrun --show-sdk-path --sdk macosx)/System/Library/Frameworks/\
FoundationModels.framework/Versions/A/Modules/FoundationModels.swiftmodule/\
arm64e-apple-macos.swiftinterface
```

This is a hard ceiling, not an oversight to work around. Every on-device
task therefore describes the capture *in text*: Vision's OCR plus the app and
window it came from. It's why `CaptureDescriptionRequest` carries
`recognizedText` rather than a `CGImage`, and why anything genuinely needing
to *see* the picture will need a remote provider.

### Protocol shape

Requirements are **narrow, named tasks** (`describeCapture`), not a
free-form `prompt(_:)`. A general prompt method would put prompt wording at
every call site and make each feature's behaviour a property of its caller;
keeping the task in the provider means the prompt, its guardrails and its
output shape live in one place per feature and can change without touching
the UI that asked. Each new feature adds its own requirement.

`describeCapture` returns plain prose ("login form validation error"), not a
slug — turning it into a filename is `FilenameTemplate`'s business.

### Implementation notes

- **Availability is re-read every time**, never cached: it changes outside
  the app (Apple Intelligence toggled in System Settings, model finishes
  downloading). `SystemLanguageModel.Availability.UnavailableReason` maps to
  `AIUnavailableReason`, which carries a user-facing message and whether
  System Settings can fix it.
- **Guided generation** (`@Generable` + `@Guide`) constrains output to one
  named field. Without it the model wraps the phrase in a sentence of
  preamble.
- **Greedy sampling.** These descriptions end up in filenames and indexes,
  where churn between runs is worse than dullness.
- **OCR input is truncated to 4000 characters.** A full-screen capture's
  transcript overflows the context window and fails the whole request. The
  head of a screen is where its identifying text almost always is, so taking
  the prefix is both the cheap fix and the right one.
- **Degrade, never error at the user.** Anything built on this must fall back
  to its non-AI behaviour when the provider is unavailable. That's the whole
  point of `availability` being a first-class part of the protocol.

### Settings

`AppSettings.aiEnabled` defaults to **off** — nothing runs a model behind
the user's back, even on-device. The seam originally shipped with no
consumers and therefore no UI (a master toggle that controls nothing is dead
UI); `{describe}` is the first consumer, so Settings → Intelligence now
holds the switch, the live availability status, and the features built on
it.

There's still no provider picker: there's one conformer. A second
provider adds an enum, a picker, a Keychain-backed key
(`KeychainStore`, never UserDefaults) and a branch in
`AppSettings.aiProvider` — and nothing upstream changes, which is the
property the seam exists to guarantee.

---

## `CaptureAnalyzer`

`Services/CaptureAnalyzer.swift` — one pass over a capture returning its
on-screen text and a prose description of what it shows.

It exists because the expensive half is shared. The on-device model takes no
image input, so a description *is* OCR plus the window it came from; running
Vision once for the filename and again for anything else would double the
cost of every capture for the same answer. `describes: false` skips the
model and returns OCR alone.

**Nothing here throws.** Both halves are enrichment — a capture whose text
can't be read, or whose description the model declines to produce, is still
a perfectly good screenshot. Callers fall back to their non-AI behaviour on
a nil description; that's the "degrade, never error at the user" rule above,
made structural.

---

## `{describe}` filenames

The seam's first consumer: `QuickSnap 2026-08-01 login-form-validation-error.png`.
Switched on in Settings → Intelligence, which appends the token to the
filename template rather than storing a second flag — the template stays the
single source of truth for naming.

The mechanics (deferred rename, `ResolvedFilename`, `CaptureFile`, xattr
survival, slug hygiene) are naming concerns and live in
`docs/files-and-retention.md`. What belongs here is the shape of the
dependency: **the capture is complete before the model is consulted**. A
description is a nicety layered on top of a file that is already saved,
copied and previewed, and every failure path leaves that file exactly as it
was.

### Verifying

`SystemLanguageModel` can't be exercised without Apple Intelligence enabled
on the machine. A standalone `swift` script against the same API is the
quickest check — the availability mapping and the guided-generation call
compile and run identically outside the app:

```swift
switch SystemLanguageModel.default.availability {
case .available: print("available")
case .unavailable(let reason): print("unavailable(\(reason))")
}
```

As of the seam landing, this repo's development machine reports
`appleIntelligenceNotEnabled`, so the unavailable path is verified and the
generation path is not. Turn Apple Intelligence on before trusting prompt
wording or output quality.
