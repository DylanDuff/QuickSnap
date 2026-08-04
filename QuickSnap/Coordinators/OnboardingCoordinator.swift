//
//  OnboardingCoordinator.swift
//  QuickSnap
//

import AppKit
import Combine
import SwiftUI

/// Owns the first-run window: when it opens, what happens when it finishes,
/// and the activation policy while it's up.
///
/// A singleton, like `CaptureIndexer` and for the same reason — the Settings
/// scene needs to reopen the same flow the capture path launches on first
/// run, and neither owns the other.
///
/// Two things it deliberately is *not*. It isn't a gate: every step can be
/// skipped, and closing the window counts as finishing, because a capture
/// utility that won't let you take a screenshot until you've read six panels
/// is worse than one you have to configure later. And it isn't the Settings
/// window — it can't be, since `NSApp.sendAction(Selector(("showSettingsWindow:")))`
/// silently does nothing and the `Settings` scene can only be opened from
/// SwiftUI's `openSettings` (see CLAUDE.md).
@MainActor
final class OnboardingCoordinator: NSObject {
    static let shared = OnboardingCoordinator()

    private var window: NSWindow?

    private override init() {}

    /// Shows the flow if it has never been completed. Called once at launch.
    func showIfFirstRun() {
        guard !AppSettings.hasCompletedOnboarding else { return }
        show()
    }

    /// Opens the flow, or brings it forward if it's already up.
    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to QuickSnap"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Both halves, same as the Settings and annotation windows: a
        // SwiftUI Material samples the *window's* backdrop, so on an opaque
        // window it has nothing to blur and renders as a flat tint instead
        // of glass. Clearing the background without also clearing `isOpaque`
        // leaves black behind everything the system composites over it.
        window.isOpaque = false
        window.backgroundColor = .clear
        // Deliberately not `isMovableByWindowBackground` — see the same note
        // in `QuickSnapApp`'s window configuration. It would eat the
        // drag-to-reorder in the toolbar step, which is the whole point of
        // that screen. The (transparent) title bar strip still drags.
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Deliberately not `.resizable` and not `.miniaturizable`: the flow is
        // laid out for one size, and a first-run window that can be sent to
        // the Dock by an app with no Dock icon is a window you can't get back.

        let hostingView = NSHostingView(
            rootView: OnboardingView(onFinish: { [weak self] in self?.finish() })
        )
        // **Must be empty.** `NSHostingView` otherwise pushes SwiftUI's
        // computed min/max size onto the window as `contentMinSize` — and it
        // computes the minimum by laying the content out at its narrowest,
        // where every `Text(…).fixedSize(horizontal: false, vertical: true)`
        // wraps into a column and grows without bound. Measured: a minimum of
        // 156 × 3380 pt, which opened the window taller than the display with
        // the content off-screen. The flow is a fixed-size window; its size is
        // ours to set.
        hostingView.sizingOptions = []
        window.contentView = hostingView
        window.setContentSize(Self.contentSize)
        // Same recipe as the annotation window: `.fullSizeContentView` alone
        // still leaves NSHostingView reporting a title-bar safe-area inset to
        // its SwiftUI content, and this has to be set *after* the view is in
        // the window.
        hostingView.safeAreaRegions = []
        window.center()

        self.window = window
        // An accessory app's window opens behind whatever the user is looking
        // at unless the app activates first — the same trap the Settings menu
        // item hit. On first run there is nothing else of ours on screen, so
        // this is the app's entire first impression.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// Marks the flow done and closes it. Closing the window by hand runs the
    /// same path (see `windowWillClose`) — there's no way to leave it half
    /// finished and be asked again next launch, which would be nagging.
    private func finish() {
        AppSettings.hasCompletedOnboarding = true
        window?.close()
    }

    /// Lets the flow be replayed from Settings: forgets the completion flag
    /// so the next `showIfFirstRun` would run too.
    func replay() {
        AppSettings.hasCompletedOnboarding = false
        show()
    }

    private static let contentSize = CGSize(width: 620, height: 560)
}

extension OnboardingCoordinator: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        AppSettings.hasCompletedOnboarding = true
        window = nil
        // Back to a menu-bar-only app, unless an annotation window is up and
        // still wants a Dock icon.
        if !NSApp.windows.contains(where: { $0.isVisible && $0.delegate is AnnotationCoordinator }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
