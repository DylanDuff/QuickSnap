# Sensitive content and redaction

Auto-upload is the feature most likely to leak something. A capture reaches
an S3 bucket or an Immich shared link seconds after it's taken, and a visible
API key in the corner of a window becomes a public URL — with, unlike a bad
paste, no undo. That risk is the reason to leave auto-upload switched off,
which is the actual problem this solves.

- `Services/SensitiveContentDetector.swift` — what counts as sensitive.
- `Services/Redactor.swift` — burning it out of the pixels.
- `Views/Annotation/RedactionOverlay.swift` — the review surface.
- `UploadCoordinator` — the gate.
- Settings → Uploading → Before Uploading.

## The gate

`UploadCoordinator.upload` is the single choke point every upload already
went through — automatic, the preview panel's button, and the markup
toolbar's — so the check lives there and all three are covered by
construction, rather than by each caller remembering.

When a capture holds something high-confidence:

1. Nothing is sent.
2. A toast says the upload was held.
3. The annotation window opens with the findings under review.
4. The upload continues only from there, carrying **the image as the user
   left it** — redacted, or deliberately not.

Three details that took a second pass to get right:

- **The check runs before `beginUpload`.** A held upload is not an upload
  that started and stopped: showing the progress pill and taking it away
  would report a failure that never happened, and would disturb the
  reference count that keeps concurrent uploads reporting once.
- **`proceed` takes an image.** The first version closed over the original
  capture, so redacting and then continuing would have uploaded the
  unredacted pixels — the exact failure the feature exists to prevent. The
  continuation now carries the flattened current canvas.
- **The handler is passed per call, not stored on the coordinator.** It
  belongs to the caller's context (which window to review in), and a stored
  handler would be overwritten by a second upload starting during the first
  one's OCR pass.

Once a window has shown a review, uploads from it skip the check
(`MarkupCanvasController.hasReviewedSensitiveContent`). Without that, keeping
something flagged would hold the very next upload for the same reason and
stack a second review on the first.

## Reaching it without an upload

The markup toolbar has a redact button (`asterisk.circle`, in the default
layout next to crop, and movable or removable in Settings → Markup). It runs the same
check on the capture you're looking at and arms the same review — with
*Redact All* and *Keep* instead of the upload variants, since there's no
upload waiting.

That matters because uploading is off for most people: a screenshot shared
by drag-out, clipboard or Save As deserves the same one-click blackout, and
tying the whole feature to a provider being configured would have hidden it
from everyone who needs it most. The button always answers — "Nothing
sensitive found" is a toast rather than silence, or the button gets pressed
twice and then distrusted.

The scan lives in `AnnotationCoordinator`, not the canvas controller:
deciding when to run a Service is a coordinator's job. It reads the **base
image** rather than a flattened export, because findings are in image pixel
coordinates and that's what redaction paints into.

## What counts as sensitive

Regex over Vision's OCR. **The floor is the feature**: it needs no model, no
network and no settings, runs in microseconds, and is deterministic — which
is what makes it safe to *block* on. A model layer could only ever be
additive here (an upload held because a language model had a feeling is
impossible to reason about), and is not implemented; see issue #14's AI
layer.

| Holds an upload | Flagged only |
| --- | --- |
| AWS access keys, vendor-prefixed API tokens (`sk-`, `ghp_`, `xox…`, `AIza`, `sk_live_`, `glpat-`, `npm_`), JWTs, private-key headers, `Bearer …`, card numbers, IBANs | Email addresses, long hex strings |

The split is the difference between a feature people keep on and one they
switch off. Emails and hashes appear in a large share of screenshots;
stopping every one of those would train someone to disable the check within a
day, and then a real key goes out unchecked. Low-confidence kinds never
interrupt — but once something *has* interrupted, they're shown alongside it,
since the user is already looking.

Card numbers are Luhn-checked and IBANs mod-97-checked, or every order number
and reference code would hold uploads.

**Character classes are deliberately permissive**, because this text came out
of OCR. Verified: Vision transcribed `AKIAIOSFODNN7EXAMPLE` as
`AKIAIOSFODNNZEXAMPLE` — a `7` read as `Z` — and the match still fired,
because the pattern accepts any `[A-Z0-9]` run after the prefix. Matching a
slightly-wrong transcription of a real key is the entire point.

**The matched text is never kept.** Only a masked `preview`
(`AKIA••••••MPLE`) survives into the model, so a secret can't end up in a
toast, a log line or a diagnostics dump.

## Where the box goes

`redactionRect(for:in:)` paints the **union of two estimates**: Vision's
per-substring box (`RecognizedText.boundingBox(for:)`) and a proportional
estimate from character offsets, widened by a character either side.

That looks like belt and braces until you measure it. Against known text
(standalone probe, 2026-08-01) Vision's substring box was exact for one of
three fixtures and started ~500 px early on the other two, covering most of
the line. Every observed error over-covered — but "observed" isn't
"guaranteed", and a box landing slightly short leaves the tail of a key
readable, which is a silent leak. The union is covered under either model.
The cost is occasionally blacking out the label next to the secret, which is
the direction to err in.

## Redaction is destructive

`Redactor.redacting` replaces pixels in the base image, and
`MarkupCanvasController.redact` swaps that image in — the same mechanism as
crop, not an inserted shape.

**A black rectangle drawn as markup is not a redaction.** It's an object in
an editable document: it can be selected, moved and deleted, and any export
path that doesn't flatten it leaks what it was covering. Solid black rather
than blur or pixelation for a related reason — heavy pixelation of a short
string is theoretically recoverable, which is unacceptable for an API key,
and a black box reads unambiguously as "removed on purpose".

Not undoable — and it clears the whole undo history with it. Every snapshot
behind a redaction holds the pre-redaction image, so an undo that reached one
would put the credential back on screen and into whatever gets exported next.
An undo that can un-redact is not a feature; losing the earlier steps is the
price, and redaction is normally the last thing done before the capture goes
out anyway. (Crop, by contrast, *is* undoable — see the undo bullet in
`CLAUDE.md`.)

One consequence worth knowing: replacing the base image would normally
re-fit the viewport (that's what a crop needs), which would yank the user out
of wherever they'd zoomed in to read what they were redacting.
`MarkupCanvasView.Coordinator.applyBaseImage` now only re-fits when the
canvas *bounds* changed, which distinguishes a crop from a redaction.

## Verifying

The pieces are standalone-compilable — `TextRecognizer`,
`SensitiveContentDetector` and `Redactor` depend only on Vision, CoreGraphics
and Foundation. Two suites are worth keeping:

1. **Classification**, against fixture strings: every pattern above fires,
   and a set of near-misses (16 digits failing Luhn, a bad IBAN checksum, a
   short hex string, our own filename convention) do not.
2. **End-to-end**, which is the acceptance test: render a line of text into
   an image, run the real OCR path, detect, redact, then **read the redacted
   image again** and assert the secret is gone and the rest survived. Run
   across monospaced and proportional fonts at several sizes — the proportional
   ones are where a character-width estimate is weakest.

The second suite is what proves the property the feature claims. Any change
to the box maths should re-run it rather than eyeballing rectangles.
