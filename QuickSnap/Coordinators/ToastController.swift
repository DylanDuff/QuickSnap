//
//  ToastController.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Shows a brief, non-interactive toast pill centered near the bottom of a
/// screen (used for OCR results). Same panel discipline as the screenshot
/// preview — borderless, non-activating, floating — but simpler: it ignores
/// mouse events entirely and always auto-dismisses.
///
/// Under `NotificationPosition.notificationCenter` the same calls are handed
/// to `SystemNotifier` instead, so every confirmation in the app follows the
/// one setting without its caller knowing which presentation it got.
@MainActor
final class ToastController {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    /// Captured at show time from `AppSettings.toastPosition` so the
    /// dismiss animation slides back toward the same edge it entered from.
    private var slideOutOffset: CGFloat = -10

    private static let edgeMargin: CGFloat = 48

    /// `autoDismisses: false` leaves the pill up until it's replaced by
    /// another `show` or an explicit `hide` — used for in-progress states
    /// (an Immich upload) that have no known duration, where the normal
    /// timeout would make the toast vanish mid-operation.
    func show(
        message: String,
        systemImage: String,
        detail: String? = nil,
        autoDismisses: Bool = true,
        on screen: NSScreen
    ) {
        dismissWorkItem?.cancel()
        panel?.close()
        panel = nil

        guard AppSettings.toastPosition != .notificationCenter else {
            // An in-progress state has no Notification Center analogue — a
            // banner can't be updated in place or taken back, so posting one
            // would leave "Uploading…" sitting in the list after the upload
            // finished. Skip it; the result that replaces it still posts.
            guard autoDismisses else { return }

            SystemNotifier.shared.post(title: message, body: detail) { [weak self] delivered in
                guard !delivered else { return }
                self?.showPill(
                    message: message,
                    systemImage: systemImage,
                    detail: detail,
                    autoDismisses: true,
                    at: .bottom,
                    on: screen
                )
            }
            return
        }

        showPill(
            message: message,
            systemImage: systemImage,
            detail: detail,
            autoDismisses: autoDismisses,
            at: AppSettings.toastPosition,
            on: screen
        )
    }

    /// The in-app pill: the presentation for every `NotificationPosition` bar
    /// `.notificationCenter`, and the fallback when the system refuses a
    /// notification (permission never granted, or revoked since).
    private func showPill(
        message: String,
        systemImage: String,
        detail: String?,
        autoDismisses: Bool,
        at position: NotificationPosition,
        on screen: NSScreen
    ) {
        dismissWorkItem?.cancel()
        panel?.close()

        // Measured through an `NSHostingController` rather than the hosting
        // view's `fittingSize`: that property is a *minimum* size, so a
        // wrapping detail line collapses to its narrowest layout (a short
        // string comes back wrapped and truncated). `sizeThatFits(in:)` lets
        // us propose the pill's maximum width instead, which short details
        // still shrink-wrap under.
        let contentController = NSHostingController(
            rootView: ToastView(message: message, systemImage: systemImage, detail: detail)
        )
        let size = contentController.sizeThatFits(
            in: NSSize(width: ToastView.Layout.maxWidth, height: .greatestFiniteMagnitude)
        )
        let visible = screen.visibleFrame
        let finalFrame = NSRect(
            x: visible.midX - size.width / 2,
            y: position == .top
                ? visible.maxY - size.height - Self.edgeMargin
                : visible.minY + Self.edgeMargin,
            width: size.width,
            height: size.height
        )
        // Reduced motion: cross-fade in place instead of sliding in from the
        // screen edge (and back out the same way on dismiss).
        slideOutOffset = Motion.reduceMotion ? 0 : (position == .top ? 10 : -10)
        let startFrame = Motion.reduceMotion
            ? finalFrame
            : finalFrame.offsetBy(dx: 0, dy: position == .top ? 12 : -12)

        let newPanel = NSPanel(
            contentRect: startFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.isOpaque = false
        newPanel.backgroundColor = .clear
        newPanel.hasShadow = true
        newPanel.level = .floating
        newPanel.ignoresMouseEvents = true
        newPanel.isReleasedWhenClosed = false
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.contentViewController = contentController
        // Assigning a content view controller resizes the panel to the
        // controller's own fitting size, which is the narrow-wrap size we
        // just avoided — put the measured frame back.
        newPanel.setFrame(startFrame, display: false)
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        panel = newPanel

        NSAnimationContext.animate(Motion.panelSpring) {
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(finalFrame, display: true)
        }

        guard autoDismisses else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.toastAutoDismissSeconds, execute: workItem)
    }

    /// Dismisses a pill that's up, including one shown with
    /// `autoDismisses: false`.
    func hide() {
        dismissWorkItem?.cancel()
        dismiss()
    }

    private func dismiss() {
        guard let currentPanel = panel else { return }
        panel = nil

        let endFrame = currentPanel.frame.offsetBy(dx: 0, dy: slideOutOffset)
        NSAnimationContext.animate(Motion.panelSpring) {
            currentPanel.animator().alphaValue = 0
            currentPanel.animator().setFrame(endFrame, display: true)
        } completion: {
            currentPanel.close()
        }
    }
}
