//
//  SelectionOverlayWindow.swift
//  QuickSnap
//

import AppKit

/// A borderless, transparent, full-screen panel used to host the selection
/// overlay on a single display. One instance is created per connected screen.
///
/// `.nonactivatingPanel` so it can become key (for Esc) without activating
/// the app — activating would raise QuickSnap's other windows (annotation,
/// Settings) above whatever app the user was capturing over, and leave them
/// there after the session.
final class SelectionOverlayWindow: NSPanel {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        // NSPanel defaults this to true; the app is often not even active
        // while a session runs, so never let AppKit hide the overlay.
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
