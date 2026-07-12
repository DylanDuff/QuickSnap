//
//  ScreenshotPreviewController.swift
//  QuickSnap
//

import AppKit
import QuartzCore
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
    /// Floor for the panel's long side, both on initial display (a tiny area
    /// capture gets grown up to this) and as the user-resize minimum.
    private static let minDimension: CGFloat = 90
    private static let maxLongSide: CGFloat = 480
    private static let margin: CGFloat = 16
    private static let animationDuration: TimeInterval = 0.28

    /// `fileURL` is nil when the "Save" after-capture action is turned off —
    /// the preview then hides Reveal in Finder, and drag-out is backed by a
    /// temporary PNG instead of the saved file.
    func show(image: CGImage, fileURL: URL?, on screen: NSScreen, scale: CGFloat, onEdit: @escaping (CGImage, URL?) -> Void) {
        dismissWorkItem?.cancel()
        panel?.close()
        hasInteracted = false

        // Written up front rather than lazily at drag time so a failure can
        // simply hide the drag handle instead of surfacing mid-drag.
        let dragFileURL = fileURL ?? (try? ScreenshotSaver.writeTemporaryPNG(image))

        let fullPointSize = CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let size = Self.thumbnailSize(for: fullPointSize)
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
        slideOutOffset = position == .top ? 16 : -16
        let startFrame = finalFrame.offsetBy(dx: 0, dy: position == .top ? 24 : -24)

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
        newPanel.contentMinSize = Self.sizeForLongSide(Self.minDimension, matching: size)
        newPanel.contentMaxSize = Self.sizeForLongSide(Self.maxLongSide, matching: size)
        newPanel.onInteractionBegan = { [weak self] in
            guard let self else { return }
            hasInteracted = true
            cancelAutoDismiss()
        }
        newPanel.alphaValue = 0
        newPanel.orderFrontRegardless()
        panel = newPanel

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
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
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.animationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            currentPanel.animator().alphaValue = 0
            currentPanel.animator().setFrame(endFrame, display: true)
        }, completionHandler: {
            currentPanel.close()
        })
    }

    private static func thumbnailSize(for imageSize: CGSize) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return CGSize(width: minDimension, height: minDimension) }

        let fitScale = min(maxDimension / imageSize.width, maxDimension / imageSize.height, 1)
        var size = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)

        let longestSide = max(size.width, size.height)
        if longestSide < minDimension {
            let growScale = minDimension / longestSide
            size = CGSize(width: size.width * growScale, height: size.height * growScale)
        }
        return size
    }

    /// A size with the same aspect ratio as `size`, scaled so its longest
    /// side equals `longSide`. Used to derive `contentMinSize`/`contentMaxSize`
    /// bounds that stay consistent with the locked `contentAspectRatio`.
    private static func sizeForLongSide(_ longSide: CGFloat, matching size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: longSide, height: longSide) }
        if size.width >= size.height {
            return CGSize(width: longSide, height: longSide * size.height / size.width)
        } else {
            return CGSize(width: longSide * size.width / size.height, height: longSide)
        }
    }
}
