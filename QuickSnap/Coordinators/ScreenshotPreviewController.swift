//
//  ScreenshotPreviewController.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Shows the brief floating thumbnail in the bottom-right corner after a
/// capture, mirroring macOS's built-in screenshot preview: slides/fades in
/// and auto-dismisses after a few seconds. The panel can be dragged and
/// resized (aspect ratio locked, like a video PIP window). The auto-dismiss
/// timer is paused while hovered and restarts fresh once the mouse leaves —
/// otherwise the dismiss fade can start while the action bar is
/// mid-hide-animation and visibly cut it short. Once the panel has actually
/// been interacted with (clicked, dragged, resized), auto-dismiss is
/// disabled permanently — the user is now in control of it.
@MainActor
final class ScreenshotPreviewController {
    private var panel: ScreenshotPreviewPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var hasInteracted = false
    /// Captured at show time from `AppSettings.notificationPosition` so the
    /// dismiss animation slides back toward the same edge it entered from.
    private var slideOutOffset: CGFloat = -16

    /// Long side the panel shows at by default for a typical screenshot.
    private static let maxDimension: CGFloat = 176
    /// Height floor for the panel, both on initial display (a tiny area
    /// capture gets grown up to this) and as the user-resize minimum. The
    /// width floor comes from the hover action bar's real size — see
    /// `ScreenshotPreviewView.ActionBarMetrics`.
    private static let minDimension: CGFloat = 90
    private static let maxLongSide: CGFloat = 480
    private static let margin: CGFloat = 16

    /// `fileURL` is nil when the "Save" after-capture action is turned off —
    /// the preview then hides Reveal in Finder, and drag-out is backed by a
    /// temporary PNG instead of the saved file.
    ///
    /// `onUpload` is nil when Immich uploading isn't available for this
    /// capture (not configured, button switched off, or it already uploaded
    /// automatically), which hides the upload button. Like `onEdit`, the
    /// panel doesn't know what the action does — the caller decides.
    func show(
        image: CGImage,
        fileURL: URL?,
        on screen: NSScreen,
        scale: CGFloat,
        onUpload: ((CGImage) -> Void)?,
        onEdit: @escaping (CGImage, URL?) -> Void
    ) {
        dismissWorkItem?.cancel()
        panel?.close()
        hasInteracted = false

        // Written up front rather than lazily at drag time so a failure can
        // simply hide the drag handle instead of surfacing mid-drag.
        let dragFileURL = fileURL ?? (try? ScreenshotSaver.writeTemporaryPNG(image))

        let fullPointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        // Floor the panel at whatever the hover action bar actually needs
        // (button count varies with save/drag availability) so the actions
        // never press the preview's bounds.
        let actionButtonCount = 2
            + (dragFileURL != nil ? 1 : 0)
            + (fileURL != nil ? 1 : 0)
            + (onUpload != nil ? 1 : 0)
        let minContentSize = CGSize(
            width: ScreenshotPreviewView.ActionBarMetrics.minimumPanelWidth(buttonCount: actionButtonCount),
            height: Self.minDimension
        )
        let size = Self.thumbnailSize(for: fullPointSize, minimum: minContentSize)
        let nsImage = NSImage(cgImage: image, size: fullPointSize)

        let visible = screen.visibleFrame
        let position = AppSettings.notificationPosition
        let finalFrame = CGRect(
            x: visible.maxX - size.width - Self.margin,
            y: position == .top
                ? visible.maxY - size.height - Self.margin
                : visible.minY + Self.margin,
            width: size.width,
            height: size.height
        )
        // Reduced motion: cross-fade in place instead of sliding in from the
        // screen edge (and back out the same way on dismiss).
        slideOutOffset = Motion.reduceMotion ? 0 : (position == .top ? 16 : -16)
        let startFrame = Motion.reduceMotion
            ? finalFrame
            : finalFrame.offsetBy(dx: 0, dy: position == .top ? 24 : -24)

        let newPanel = ScreenshotPreviewPanel(contentRect: startFrame)
        newPanel.contentView = NSHostingView(rootView: ScreenshotPreviewView(
            image: nsImage,
            showsRevealInFinder: fileURL != nil,
            dragFileURL: dragFileURL,
            onOpenInFinder: { [weak self] in
                self?.cancelAutoDismiss()
                if let fileURL {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            },
            onCopy: { [weak self] in
                self?.cancelAutoDismiss()
                ScreenshotSaver.copyToClipboard(image)
            },
            onEdit: { [weak self] in
                self?.cancelAutoDismiss()
                onEdit(image, fileURL)
                self?.dismiss()
            },
            onUpload: onUpload.map { upload in
                { [weak self] in
                    self?.cancelAutoDismiss()
                    upload(image)
                }
            },
            onClose: { [weak self] in
                self?.cancelAutoDismiss()
                self?.dismiss()
            },
            onHoverChanged: { [weak self] hovering in
                guard let self else { return }
                if hovering {
                    cancelAutoDismiss()
                } else if !hasInteracted {
                    scheduleDismiss()
                }
            },
            dragState: newPanel.dragState
        ))
        newPanel.contentAspectRatio = size
        newPanel.contentMinSize = Self.minimumPanelSize(matching: size, minimum: minContentSize)
        newPanel.contentMaxSize = Self.sizeForLongSide(Self.maxLongSide, matching: size)
        newPanel.onInteractionBegan = { [weak self] in
            guard let self else { return }
            hasInteracted = true
            cancelAutoDismiss()
        }
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        panel = newPanel

        NSAnimationContext.animate(Motion.panelSpring) {
            newPanel.animator().alphaValue = 1
            newPanel.animator().setFrame(finalFrame, display: true)
        }

        scheduleDismiss()
    }

    private func cancelAutoDismiss() {
        dismissWorkItem?.cancel()
    }

    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        // Nil duration = the "Never" end of the settings slider: the panel
        // stays until closed or replaced by the next capture.
        guard let duration = AppSettings.previewAutoDismissSeconds else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.dismiss()
        }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
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

    private static func thumbnailSize(for imageSize: CGSize, minimum: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return minimum }

        let fitScale = min(maxDimension / imageSize.width, maxDimension / imageSize.height, 1)
        var size = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)

        // Grow until both axes clear the minimum (aspect preserved, so one
        // axis will usually overshoot its own floor)…
        let growScale = max(minimum.width / size.width, minimum.height / size.height, 1)
        size = CGSize(width: size.width * growScale, height: size.height * growScale)

        // …but never past the long-side cap: an extreme aspect ratio gives
        // up some breathing room rather than towering across the screen.
        let longestSide = max(size.width, size.height)
        if longestSide > maxLongSide {
            let capScale = maxLongSide / longestSide
            size = CGSize(width: size.width * capScale, height: size.height * capScale)
        }
        return size
    }

    /// The smallest size with `size`'s aspect ratio satisfying `minimum` on
    /// both axes — the panel's user-resize floor. Clamped so it never
    /// exceeds the initial display size (which the long-side cap can pull
    /// under the minimum for extreme aspect ratios).
    private static func minimumPanelSize(matching size: CGSize, minimum: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return minimum }
        let factor = min(max(minimum.width / size.width, minimum.height / size.height), 1)
        return CGSize(width: size.width * factor, height: size.height * factor)
    }

    /// A size with the same aspect ratio as `size`, scaled so its longest
    /// side equals `longSide`. Used to derive a `contentMaxSize` bound that
    /// stays consistent with the locked `contentAspectRatio`.
    private static func sizeForLongSide(_ longSide: CGFloat, matching size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: longSide, height: longSide) }
        if size.width >= size.height {
            return CGSize(width: longSide, height: longSide * size.height / size.width)
        } else {
            return CGSize(width: longSide * size.width / size.height, height: longSide)
        }
    }
}
