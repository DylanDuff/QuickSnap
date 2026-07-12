//
//  HoverTrackingArea.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Bridges an AppKit `.activeAlways` tracking area into SwiftUI. SwiftUI's
/// own `.onHover` tracks with `.activeInActiveApp`, which never fires while
/// QuickSnap isn't the frontmost app — the normal state for this panel,
/// which floats passively over whatever app the user was already in.
struct HoverTrackingArea: NSViewRepresentable {
    let cursor: NSCursor
    let onHover: (Bool) -> Void
    /// When true, mouseDown here never starts a window-background drag —
    /// use this behind controls that need their own mouseDown gesture (e.g.
    /// a `.draggable` file handle), since `isMovableByWindowBackground`
    /// otherwise wins the mouseDown race before SwiftUI's own gesture does.
    var blocksWindowDrag: Bool = false

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: TrackingView) {
        view.cursor = cursor
        view.onHover = onHover
        view.blocksWindowDrag = blocksWindowDrag
    }

    final class TrackingView: NSView {
        var cursor: NSCursor = .arrow
        var onHover: ((Bool) -> Void)?
        var blocksWindowDrag = false
        private var trackingArea: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { !blocksWindowDrag }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            // `.cursorUpdate` is the mechanism AppKit itself re-invokes as
            // needed (e.g. after the mouse returns from another app's
            // window), unlike a one-off `NSCursor.set()` in mouseEntered
            // which can get left stale by a focus change elsewhere.
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self
            )
            addTrackingArea(area)
            trackingArea = area
            // A tracking area only fires entered/exited on a boundary
            // crossing — if this view appears (e.g. the action bar fading
            // in on hover) with the cursor already inside its bounds, no
            // event ever fires and the hover state gets stuck. Sync once
            // immediately after (re)installing the tracking area.
            syncHoverStateWithCurrentMouseLocation()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            syncHoverStateWithCurrentMouseLocation()
        }

        override func cursorUpdate(with event: NSEvent) {
            cursor.set()
        }

        override func mouseEntered(with event: NSEvent) {
            onHover?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHover?(false)
        }

        private func syncHoverStateWithCurrentMouseLocation() {
            guard let window else { return }
            let pointInWindow = window.mouseLocationOutsideOfEventStream
            let pointInView = convert(pointInWindow, from: nil)
            let isInside = bounds.contains(pointInView)
            onHover?(isInside)
            if isInside {
                cursor.set()
            }
        }
    }
}
