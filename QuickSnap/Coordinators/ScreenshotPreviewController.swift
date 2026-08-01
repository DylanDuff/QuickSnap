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
    /// How the panel's frame moves while it fades out, captured at show
    /// time so the dismiss mirrors however the panel entered: back toward
    /// the screen edge it slid in from, or back down into the point it grew
    /// out of. Identity under Reduce Motion (a plain cross-fade).
    private var exitTransform: (CGRect) -> CGRect = { $0 }

    /// Long side the panel shows at by default for a typical screenshot.
    private static let maxDimension: CGFloat = 176
    /// Height floor for the panel, both on initial display (a tiny area
    /// capture gets grown up to this) and as the user-resize minimum. The
    /// width floor comes from the hover action bar's real size — see
    /// `ScreenshotPreviewView.ActionBarMetrics`.
    private static let minDimension: CGFloat = 90
    private static let maxLongSide: CGFloat = 480
    private static let margin: CGFloat = 16

    /// `file` carries a nil URL when the "Save" after-capture action is
    /// turned off — the preview then hides Reveal in Finder, and drag-out is
    /// backed by a temporary PNG instead of the saved file. It's a reference
    /// rather than a URL because a `{describe}` rename can land while the
    /// panel is still up (see `CaptureFile`).
    ///
    /// `onUpload` is nil when Immich uploading isn't available for this
    /// capture (not configured, button switched off, or it already uploaded
    /// automatically), which hides the upload button. Like `onEdit`, the
    /// panel doesn't know what the action does — the caller decides.
    ///
    /// `anchor` is the region the capture covered, in AppKit's global
    /// screen coordinates — the selected area or the captured window's
    /// frame. It's what `NotificationPosition.dynamic` centers the panel
    /// on, and is nil for a full-screen capture (which has no region worth
    /// pointing at, so dynamic falls back to the bottom corner).
    func show(
        image: CGImage,
        file: CaptureFile,
        on screen: NSScreen,
        scale: CGFloat,
        anchor: CGRect?,
        onUpload: ((CGImage) -> Void)?,
        onEdit: @escaping (CGImage, CaptureFile) -> Void
    ) {
        dismissWorkItem?.cancel()
        panel?.close()
        hasInteracted = false

        let fileURL = file.url
        // Written up front rather than lazily at drag time so a failure can
        // simply hide the drag handle instead of surfacing mid-drag.
        let temporaryDragFileURL = fileURL == nil ? try? ScreenshotSaver.writeTemporaryImage(image) : nil
        let dragFileURL = fileURL ?? temporaryDragFileURL

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
        // Dynamic without a region to point at (a full-screen capture) is
        // the bottom corner, which is also where it lands if the setting is
        // stale — hence resolving to a concrete edge up front.
        let position = AppSettings.previewPosition
        let dynamicAnchor = position == .dynamic ? anchor : nil
        let edge: NotificationPosition = position == .top ? .top : .bottom

        let finalFrame: CGRect
        // Reduced motion: cross-fade in place instead of sliding in from
        // the screen edge / growing out of the capture (and back out the
        // same way on dismiss).
        let startFrame: CGRect
        if let dynamicAnchor {
            finalFrame = Self.frame(ofSize: size, centeredOn: dynamicAnchor, within: visible)
            exitTransform = Motion.reduceMotion ? { $0 } : { Self.scaled($0, by: Self.growthScale) }
            startFrame = Motion.reduceMotion ? finalFrame : Self.scaled(finalFrame, by: Self.growthScale)
        } else {
            finalFrame = CGRect(
                x: visible.maxX - size.width - Self.margin,
                y: edge == .top
                    ? visible.maxY - size.height - Self.margin
                    : visible.minY + Self.margin,
                width: size.width,
                height: size.height
            )
            let offset: CGFloat = Motion.reduceMotion ? 0 : (edge == .top ? 16 : -16)
            exitTransform = { $0.offsetBy(dx: 0, dy: offset) }
            startFrame = Motion.reduceMotion
                ? finalFrame
                : finalFrame.offsetBy(dx: 0, dy: edge == .top ? 24 : -24)
        }

        let newPanel = ScreenshotPreviewPanel(contentRect: startFrame)
        newPanel.contentView = NSHostingView(rootView: ScreenshotPreviewView(
            image: nsImage,
            file: file,
            temporaryDragFileURL: temporaryDragFileURL,
            onOpenInFinder: { [weak self] in
                self?.cancelAutoDismiss()
                // Read now, not at show time: a rename may have moved it.
                if let currentURL = file.url {
                    NSWorkspace.shared.activateFileViewerSelecting([currentURL])
                }
            },
            onCopy: { [weak self] in
                self?.cancelAutoDismiss()
                ScreenshotSaver.copyToClipboard(image)
            },
            onEdit: { [weak self] in
                self?.cancelAutoDismiss()
                onEdit(image, file)
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

        let endFrame = exitTransform(currentPanel.frame)
        NSAnimationContext.animate(Motion.panelSpring) {
            currentPanel.animator().alphaValue = 0
            currentPanel.animator().setFrame(endFrame, display: true)
        } completion: {
            currentPanel.close()
        }
    }

    /// Centers the panel over the region the capture covered, then pulls it
    /// back inside the screen's usable area. The clamp matters more than it
    /// looks: a selection can run right up to a screen edge (or sit on a
    /// window that straddles two screens), and an uncorrected center would
    /// put half the thumbnail under the Dock or off the display entirely.
    private static func frame(ofSize size: CGSize, centeredOn anchor: CGRect, within visible: CGRect) -> CGRect {
        let origin = CGPoint(
            x: anchor.midX - size.width / 2,
            y: anchor.midY - size.height / 2
        )
        // `max(…, min)` last so a panel larger than the usable area (only
        // reachable on a very small display) overflows the far edge rather
        // than the origin edge.
        return CGRect(
            x: max(min(origin.x, visible.maxX - size.width - margin), visible.minX + margin),
            y: max(min(origin.y, visible.maxY - size.height - margin), visible.minY + margin),
            width: size.width,
            height: size.height
        )
    }

    /// How small the panel starts (and ends) relative to its resting size
    /// when it grows out of the capture instead of sliding in from an edge.
    private static let growthScale: CGFloat = 0.92

    /// `frame` scaled about its own center — so the panel grows into place
    /// from, and shrinks back toward, wherever the user last left it.
    private static func scaled(_ frame: CGRect, by factor: CGFloat) -> CGRect {
        CGRect(
            x: frame.midX - frame.width * factor / 2,
            y: frame.midY - frame.height * factor / 2,
            width: frame.width * factor,
            height: frame.height * factor
        )
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
