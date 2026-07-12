//
//  ToastController.swift
//  QuickSnap
//

import AppKit
import QuartzCore
import SwiftUI

/// Shows a brief, non-interactive toast pill centered near the bottom of a
/// screen (used for OCR results). Same panel discipline as the screenshot
/// preview — borderless, non-activating, floating — but simpler: it ignores
/// mouse events entirely and always auto-dismisses.
@MainActor
final class ToastController {
    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    /// Captured at show time from `AppSettings.notificationPosition` so the
    /// dismiss animation slides back toward the same edge it entered from.
    private var slideOutOffset: CGFloat = -10

    private static let edgeMargin: CGFloat = 48
    private static let animationDuration: TimeInterval = 0.25

    func show(message: String, systemImage: String, detail: String? = nil, on screen: NSScreen) {
        dismissWorkItem?.cancel()
        panel?.close()

        let hostingView = NSHostingView(rootView: ToastView(message: message, systemImage: systemImage, detail: detail))
        let size = hostingView.fittingSize
        let visible = screen.visibleFrame
        let position = AppSettings.notificationPosition
        let finalFrame = NSRect(
            x: visible.midX - size.width / 2,
            y: position == .top
                ? visible.maxY - size.height - Self.edgeMargin
                : visible.minY + Self.edgeMargin,
            width: size.width,
            height: size.height
        )
        slideOutOffset = position == .top ? 10 : -10
        let startFrame = finalFrame.offsetBy(dx: 0, dy: position == .top ? 12 : -12)

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
        newPanel.contentView = hostingView
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        panel = newPanel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(finalFrame, display: true)
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + AppSettings.toastAutoDismissSeconds, execute: workItem)
    }

    private func dismiss() {
        guard let currentPanel = panel else { return }
        panel = nil

        let endFrame = currentPanel.frame.offsetBy(dx: 0, dy: slideOutOffset)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            currentPanel.animator().alphaValue = 0
            currentPanel.animator().setFrame(endFrame, display: true)
        }, completionHandler: {
            currentPanel.close()
        })
    }
}
