//
//  CaptureSearchPanel.swift
//  QuickSnap
//

import AppKit

/// The floating window the capture search lives in — Spotlight-shaped: no
/// title bar, rounded, centered high on the screen, gone on Esc.
///
/// Unlike the preview panel and the toast, this one **takes key status**:
/// there's a text field in it, and a search box that can't be typed into is
/// nothing. `canBecomeKey` has to be overridden because a borderless window
/// returns false by default. The app activates around it (see
/// `CaptureSearchController`) — an accessory app can be frontmost without
/// gaining a Dock icon, so no activation-policy switch is needed here, which
/// is what keeps this feeling like a HUD rather than an app window.
final class CaptureSearchPanel: NSPanel {
    /// Called on Esc and on losing key status, so the controller can tear
    /// the panel down rather than leaving it floating unfocused.
    var onDismiss: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        // Visible over full-screen apps, and on whichever Space the user is
        // on — the opposite call from the preview panel, which belongs to
        // the Space its capture was taken on. A search box that opened on
        // another desktop would be useless.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { true }

    /// Esc. `cancelOperation` is the responder-chain path AppKit already
    /// routes Esc through, so this works whether or not the text field has
    /// focus.
    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    /// Clicking away is a dismissal too — the panel has no chrome to close
    /// it with, and one left behind on another app's window would be
    /// confusing.
    override func resignKey() {
        super.resignKey()
        onDismiss?()
    }
}
