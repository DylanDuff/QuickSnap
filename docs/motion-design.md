# Motion & interaction feedback

House motion style, based on Apple's fluid-interface guidance (*Designing
Fluid Interfaces*, WWDC 2018). The rules, in priority order:

1. **Springs by default, critically damped.** No overshoot unless the motion
   follows a gesture that carried momentum (we currently have none of those).
2. **Feedback on mouse-down, not release.** Buttons visibly react the instant
   they're pressed.
3. **Enter and exit along the same path.** A panel that slides up from the
   bottom edge dismisses back toward the bottom edge.
4. **Reduced motion means cross-fade, not nothing.** Slides and scales degrade
   to opacity-only equivalents; hover/press feedback stays.
5. **Never animate 1:1 gesture tracking.** Drag-driven geometry (crop rect,
   area selection) updates unanimated so it stays glued to the pointer.

## Where it lives

- `Views/Motion.swift` — the shared vocabulary:
  - `Motion.panelSpring` (`.smooth(duration: 0.35)`) — floating panel/toast
    enter & exit. `.smooth` is SwiftUI's critically damped spring (Apple's
    "damping 1.0"); `.snappy` adds slight bounce, `.bouncy` more.
  - `Motion.revealSpring` (`.smooth(duration: 0.2)`) — small in-view reveals
    (the preview panel's hover action bar).
  - `Motion.reduceMotion` — AppKit-side check
    (`NSWorkspace.accessibilityDisplayShouldReduceMotion`) for coordinators
    animating `NSWindow`s. SwiftUI views use
    `@Environment(\.accessibilityReduceMotion)` instead.
  - `PressScaleButtonStyle` — press-down scale feedback (0.9 by default,
    ~100 ms ease-out). Use it instead of `.plain` on icon-ish buttons.
- `Views/Annotation/ToolbarIconButton.swift` — the circular icon button used
  across the markup toolbar and crop confirm bar: hover highlight
  (`primary.opacity(0.08)` circle), press scale, accent-tinted active state
  (`accentColor.opacity(0.25)` fill). New toolbar-style buttons should use
  this rather than hand-rolling the 28×28 circle.

## Window-level springs

`NSAnimationContext.animate(_:changes:completion:)` (macOS 15+) accepts a
SwiftUI `Animation`, so `ScreenshotPreviewController` and `ToastController`
drive their panels' frame+alpha enter/exit with `Motion.panelSpring` through
the ordinary `animator()` proxies. Under reduced motion both controllers zero
the slide offsets (`startFrame = finalFrame`, `slideOutOffset = 0`) so the
same code path becomes a pure cross-fade.

## Deliberate non-animations

- Selection overlay (area drag, window highlight) is instant by design —
  response beats animation during aiming.
- Crop rect / shape insertion drags are 1:1 with the pointer; only the
  chrome around them (confirm bar, hint) may fade.
- The markup toolbar's preset-row swap uses `.snappy(duration: 0.25)` with a
  slide-up transition (opacity-only under reduced motion).
