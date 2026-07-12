//
//  ScreenshotPreviewPanel.swift
//  QuickSnap
//

import AppKit
import Combine

/// Shared with `ScreenshotPreviewView` so it can hide the hover action bar
/// while the panel is actually being dragged or resized.
final class PreviewDragState: ObservableObject {
    @Published var isDragging = false
}

/// Borderless floating panel that hosts the post-capture thumbnail. Uses
/// `.nonactivatingPanel` so it can be dragged/resized without stealing focus
/// or key window status from whatever app the user is currently in.
final class ScreenshotPreviewPanel: NSPanel {
    /// Fired on mouse-down inside the panel so the controller can cancel the
    /// auto-dismiss timer — the panel shouldn't vanish while the user is
    /// actively repositioning, resizing, or clicking an action on it.
    var onInteractionBegan: (() -> Void)?

    let dragState = PreviewDragState()

    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var isMouseDown = false
    private var isDragTransitionPending = false

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        isMovableByWindowBackground = true
        // No `.canJoinAllSpaces` — the panel should stay on the Space it was
        // created on, not follow the user to every Space they switch to.
        // `.fullScreenDisallowsTiling` opts out of the older Split View
        // full-screen tiling. There is no documented/public API to opt out
        // of macOS Sequoia's newer edge-drag window tiling/snapping — see
        // CLAUDE.md for details; this is the closest supported flag.
        collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary, .fullScreenDisallowsTiling]

        installDragMonitors()
    }

    deinit {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
        if let moveObserver {
            NotificationCenter.default.removeObserver(moveObserver)
        }
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Window-background dragging (and edge resizing) is handled by AppKit
    /// before it reliably reaches a `mouseDown`/`mouseUp` override on the
    /// window or its content views, so mouse state is tracked with app-level
    /// event monitors instead — these see every mouse-down/up regardless of
    /// how the drag itself ends up being handled internally. `dragState`
    /// only flips to `true` once the frame actually changes while the mouse
    /// is down (a plain click never moves the frame), not on mouseDown
    /// itself, so a click alone doesn't hide the action bar.
    private func installDragMonitors() {
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === self else { return event }
            onInteractionBegan?()
            isMouseDown = true
            return event
        }
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self else { return event }
            isMouseDown = false
            if dragState.isDragging {
                dragState.isDragging = false
                NSCursor.openHand.set()
            }
            return event
        }

        moveObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            self?.handleFrameChangeWhileMouseDown()
        }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: .main) { [weak self] _ in
            self?.handleFrameChangeWhileMouseDown()
        }
    }

    /// `didMoveNotification`/`didResizeNotification` fire synchronously from
    /// deep inside AppKit's own window-drag tracking loop. Mutating
    /// `dragState` (and its SwiftUI-side `withAnimation`) directly from that
    /// call stack lands the transition awkwardly and it doesn't animate —
    /// bouncing off `DispatchQueue.main` gives SwiftUI a clean top-level
    /// turn to actually animate the change (this still runs promptly, since
    /// GCD's main-queue dispatch is serviced during tracking loops, unlike a
    /// plain `Timer`).
    private func handleFrameChangeWhileMouseDown() {
        guard isMouseDown, !dragState.isDragging, !isDragTransitionPending else { return }
        isDragTransitionPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isDragTransitionPending = false
            guard isMouseDown, !dragState.isDragging else { return }
            dragState.isDragging = true
            NSCursor.closedHand.set()
        }
    }
}
