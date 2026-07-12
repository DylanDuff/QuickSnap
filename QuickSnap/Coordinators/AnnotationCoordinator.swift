//
//  AnnotationCoordinator.swift
//  QuickSnap
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Owns the lifecycle of annotation windows opened from "Edit" on a
/// screenshot. Multiple can be open at once (one per screenshot being
/// viewed/edited) — not a singleton like the preview panel.
///
/// This is a standard titled `NSWindow` — a fully custom borderless window
/// (own drag-to-move, own close button, `canBecomeKey` override) was tried
/// first and kept fighting us (jittery custom dragging, layout bugs); native
/// window chrome gives title bar, close button, and resize for free and
/// reliably. Content is SwiftUI hosted via `NSHostingView`; the markup
/// canvas inside it is PaperKit hosted via `NSViewControllerRepresentable`
/// — see `AnnotationView` / `MarkupCanvasView`.
///
/// The annotation window's output actions are wired here: Copy puts the
/// flattened image on the clipboard; Save As… runs an `NSSavePanel` and
/// writes a PNG. The original screenshot file is never overwritten.
///
/// QuickSnap normally runs as an accessory app (`LSUIElement`, no Dock
/// icon), but an annotation window is a real, standard editing surface —
/// while at least one is open, the app temporarily switches to `.regular`
/// activation policy so it gets a Dock icon and shows up in Cmd-Tab, then
/// reverts to `.accessory` once the last one closes.
@MainActor
final class AnnotationCoordinator: NSObject {
    /// Open annotation windows, each mapped to its image's aspect ratio
    /// (width / height) — used by the `NSWindowDelegate` resize hooks to
    /// keep the window locked to "canvas at that ratio + fixed chrome"
    /// (`AnnotationView.Layout.chromeSize`), so the mat and toolbar always
    /// line up with the window edges. The lock holds regardless of the
    /// canvas's internal zoom/pan (the viewport shape always matches the
    /// image); a crop re-locks to the new ratio via `canvasAspectChanged`.
    private var windows: [NSWindow: CGFloat] = [:]

    /// `fileURL` is nil when the capture was never saved to disk (the "Save"
    /// after-capture action is off) — the window then falls back to the
    /// timestamped naming convention for its title and Save As… suggestion.
    func openAnnotationWindow(image: CGImage, fileURL: URL?) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let aspect = imageSize.width / imageSize.height
        let contentSize = Self.initialContentSize(forImageSize: imageSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = fileURL?.lastPathComponent ?? "\(ScreenshotSaver.timestampedName()).png"
        window.titleVisibility = .hidden
        // A titled window is opaque by default, which leaves the SwiftUI
        // `.regularMaterial` backgrounds nothing translucent to blur —
        // they render flat instead of frosted. Transparent content area +
        // native title bar is a standard, safe combination.
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.conformingContentSize(
            forCanvasWidth: Self.minContentWidth - AnnotationView.Layout.chromeSize.width,
            aspect: aspect
        )
        window.delegate = self

        let annotationView = AnnotationView(
            image: image,
            onCopy: { ScreenshotSaver.copyToClipboard($0) },
            onSaveAs: { [weak self, weak window] flattened in
                guard let self, let window else { return }
                self.saveAnnotatedCopy(flattened, originalFileURL: fileURL, attachedTo: window)
            },
            onCanvasAspectChanged: { [weak self, weak window] aspect in
                // Fired from a SwiftUI onChange during view update — defer
                // the window mutation out of that pass.
                DispatchQueue.main.async {
                    guard let self, let window else { return }
                    self.canvasAspectChanged(for: window, to: aspect)
                }
            }
        )
        let hostingView = NSHostingView(rootView: annotationView)
        window.contentView = hostingView
        // `.fullSizeContentView` alone only makes the hosting view's frame
        // span behind the title bar — NSHostingView still reports a
        // container safe-area inset for that title-bar region to its
        // SwiftUI content by default, so content still stops short of the
        // top unless that reporting itself is turned off here. Set after
        // attaching to the window, since safe-area computation is derived
        // from the window context and setting it beforehand didn't fully
        // take effect.
        hostingView.safeAreaRegions = []
        window.center()

        windows[window] = aspect
        if windows.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// A crop changed the canvas's aspect ratio: re-lock the window to the
    /// new ratio and resize it in place — canvas width kept where possible,
    /// top-left corner anchored, clamped to the screen's visible area.
    private func canvasAspectChanged(for window: NSWindow, to aspect: CGFloat) {
        guard let oldAspect = windows[window] else { return }
        windows[window] = aspect
        guard abs(oldAspect - aspect) > 0.0001 else { return }

        let chrome = AnnotationView.Layout.chromeSize
        window.contentMinSize = Self.conformingContentSize(
            forCanvasWidth: Self.minContentWidth - chrome.width,
            aspect: aspect
        )

        var canvasWidth = window.contentRect(forFrameRect: window.frame).width - chrome.width
        if let screen = window.screen {
            let maxContentHeight = window.contentRect(
                forFrameRect: NSRect(origin: .zero, size: screen.visibleFrame.size)
            ).height
            canvasWidth = min(canvasWidth, (maxContentHeight - chrome.height) * aspect)
        }
        canvasWidth = max(canvasWidth, Self.minContentWidth - chrome.width)
        let content = Self.conformingContentSize(forCanvasWidth: canvasWidth, aspect: aspect)

        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin.x = window.frame.origin.x
        frame.origin.y = window.frame.maxY - frame.height
        if let screen = window.screen {
            frame.origin.y = max(frame.origin.y, screen.visibleFrame.minY)
            frame.origin.x = min(frame.origin.x, screen.visibleFrame.maxX - frame.width)
        }
        window.setFrame(frame, display: true, animate: true)
    }

    private func saveAnnotatedCopy(_ image: CGImage, originalFileURL: URL?, attachedTo window: NSWindow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.directoryURL = ScreenshotSaver.saveDirectory
        let baseName = originalFileURL?.deletingPathExtension().lastPathComponent ?? ScreenshotSaver.timestampedName()
        panel.nameFieldStringValue = baseName + " Annotated"
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    // Detached: a first write into a TCC-protected folder
                    // blocks on the consent prompt (see CLAUDE.md).
                    try await Task.detached(priority: .userInitiated) {
                        try ScreenshotSaver.writePNG(image, to: url)
                    }.value
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't Save Annotated Screenshot"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    /// Minimum window content width — must comfortably fit the toolbar
    /// pill's intrinsic width. The minimum height follows from the aspect
    /// lock instead of having its own floor.
    private static let minContentWidth: CGFloat = 480

    /// The one true window content size for a given canvas width: the image
    /// at its aspect ratio plus the fixed chrome (mat padding + toolbar).
    private static func conformingContentSize(forCanvasWidth canvasWidth: CGFloat, aspect: CGFloat) -> CGSize {
        let chrome = AnnotationView.Layout.chromeSize
        return CGSize(
            width: canvasWidth + chrome.width,
            height: canvasWidth / aspect + chrome.height
        )
    }

    /// Windows open at a fixed compact width regardless of image size (the
    /// canvas fit-zooms to whatever viewport it gets); very tall captures
    /// narrow further to cap the height, and `minContentWidth` wins over
    /// that cap so the toolbar always fits.
    private static func initialContentSize(forImageSize imageSize: CGSize) -> CGSize {
        let targetContentWidth: CGFloat = 550
        let maxCanvasHeight: CGFloat = 900
        let chrome = AnnotationView.Layout.chromeSize
        let aspect = imageSize.width / imageSize.height
        var canvasWidth = min(targetContentWidth - chrome.width, maxCanvasHeight * aspect)
        canvasWidth = max(canvasWidth, minContentWidth - chrome.width)
        return conformingContentSize(forCanvasWidth: canvasWidth, aspect: aspect)
    }
}

extension AnnotationCoordinator: NSWindowDelegate {
    /// Aspect-ratio lock. `NSWindow.contentAspectRatio` can't express
    /// "image ratio plus a fixed chrome offset", so user resizes are
    /// constrained here instead: whichever axis the user is dragging more
    /// drives, and the other follows from the image's aspect ratio.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard let aspect = windows[sender] else { return frameSize }
        let chrome = AnnotationView.Layout.chromeSize
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let current = sender.contentRect(forFrameRect: sender.frame).size
        let widthDriven = abs(proposed.width - current.width) >= abs(proposed.height - current.height)
        let canvasWidth = widthDriven
            ? proposed.width - chrome.width
            : (proposed.height - chrome.height) * aspect
        let clampedCanvasWidth = max(canvasWidth, Self.minContentWidth - chrome.width)
        let content = Self.conformingContentSize(forCanvasWidth: clampedCanvasWidth, aspect: aspect)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    /// Zoom (green traffic light / double-click title bar): largest
    /// conforming frame that fits the screen's visible area, kept at the
    /// top of that area and horizontally centered.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard let aspect = windows[window] else { return defaultFrame }
        let chrome = AnnotationView.Layout.chromeSize
        let maxContent = window.contentRect(forFrameRect: defaultFrame).size
        let fitCanvasWidth = min(maxContent.width - chrome.width, (maxContent.height - chrome.height) * aspect)
        let canvasWidth = max(fitCanvasWidth, Self.minContentWidth - chrome.width)
        let content = Self.conformingContentSize(forCanvasWidth: canvasWidth, aspect: aspect)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin.x = defaultFrame.midX - frame.width / 2
        frame.origin.y = defaultFrame.maxY - frame.height
        return frame
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows.removeValue(forKey: window)
        if windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
