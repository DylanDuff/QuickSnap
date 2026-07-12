# TODO

## Revisit: annotation-window zoom preservation across resizes (2026-07-13)

The verify-and-retry enforcement (`MarkupCanvasView.Coordinator.enforceViewport`) passes the
automated probe (`Probe/ZoomResizeProbe.swift`, all 3 scenarios, stable across runs), but still
doesn't feel fully reliable in real use.

When picking this up:

1. Reproduce by hand first, then encode whatever failed as a new probe scenario — the probe's
   zoom is programmatic (`setContentVisibleFrame`); real pinch state, resizes from corners /
   top-left edges, double-click title-bar zoom, and resize-while-crop-overlay-open are all
   uncovered gaps a manual repro might hit.
2. Known cosmetic limit (platform boundary, not a bug): the remote canvas freezes its zoom
   during the drag and drops all host commands until after mouse-up, so the correction snaps in
   at release rather than tracking live. If the complaint is the snap itself, that needs a
   different idea (e.g. hiding the canvas behind a scaled snapshot during live resize), not
   enforcement tuning.
3. Empirical facts about the remote canvas (drop windows, stale-range clamping, report
   semantics) are documented under "Non-obvious things" in `CLAUDE.md` — read those before
   changing anything; every theorized-but-unmeasured design failed.
