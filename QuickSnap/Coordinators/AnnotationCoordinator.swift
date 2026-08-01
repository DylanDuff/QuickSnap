//
//  AnnotationCoordinator.swift
//  QuickSnap
//

import AppKit
import Combine
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
    /// Per-window state. `aspect` is the image's ratio (width / height),
    /// used by the `NSWindowDelegate` resize hooks to keep the window locked
    /// to "canvas at that ratio + fixed chrome"
    /// (`AnnotationView.Layout.chromeSize`), so the mat always lines up with
    /// the window edges. The lock holds regardless of the canvas's internal
    /// zoom/pan (the viewport shape always matches the image); a crop
    /// re-locks to the new ratio via `canvasAspectChanged`.
    private struct AnnotationSession {
        var aspect: CGFloat
        /// The tools pill, a child window pinned below `window` — kept here
        /// so window moves/resizes can re-pin it and close can tear it down.
        let toolbar: MarkupToolbarPanel
        /// Keeps the window title following a `{describe}` rename of the
        /// capture, which can land after the window is already open.
        let fileObserver: AnyCancellable?
    }

    /// Open annotation windows.
    private var windows: [NSWindow: AnnotationSession] = [:]

    /// Confirmation for the toolbar's one-click Save (which has no other
    /// visible result — the file lands silently in the save folder).
    private let toastController = ToastController()

    /// Backs the toolbar's Upload button; owns its own progress/result
    /// toasts, so it isn't shared with `toastController`.
    private let uploadCoordinator = UploadCoordinator()

    /// An upload that was stopped because the capture looked like it carried
    /// credentials: what was found, and how to carry on once the user has
    /// dealt with it. The annotation window becomes the review surface.
    struct HeldUpload {
        let matches: [SensitiveMatch]
        /// Called with the image as it stands when the user chooses to go
        /// ahead — redacted, or not, depending on what they did.
        let proceed: (CGImage) -> Void
    }

    /// `file` carries a nil URL when the capture was never saved to disk
    /// (the "Save" after-capture action is off) — the window then falls back
    /// to the timestamped naming convention for its title and Save As…
    /// suggestion. It's a reference so a `{describe}` rename landing after
    /// the window opened moves the title and the suggested name with it
    /// (see `CaptureFile`).
    ///
    /// `heldUpload` opens the window straight into the redaction review,
    /// which is how an automatic upload that found credentials ends up in
    /// front of the user instead of on a server.
    func openAnnotationWindow(image: CGImage, file: CaptureFile, heldUpload: HeldUpload? = nil) {
        let imageSize = CGSize(width: image.width, height: image.height)
        let aspect = imageSize.width / imageSize.height
        let contentSize = Self.initialContentSize(forImageSize: imageSize)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = Self.windowTitle(for: file.url)
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

        // Owned here rather than by `AnnotationView`, because the canvas and
        // the toolbar pill now live in two different windows and share it.
        let canvas = MarkupCanvasController(
            image: image,
            defaultColor: Color(nsColor: AppSettings.markupDefaultColor),
            defaultStrokeStep: AppSettings.markupDefaultStrokeStep
        )

        if let heldUpload {
            canvas.continueHeldUpload = heldUpload.proceed
            // Assigned last: this is what mounts `RedactionOverlay`, and it
            // needs the continuation already in place to offer to finish the
            // upload.
            canvas.pendingRedactions = heldUpload.matches
        }

        let toolbar = MarkupToolbarPanel(
            controller: canvas,
            onCopy: { ScreenshotSaver.copyToClipboard($0) },
            onSave: { [weak self, weak window] flattened in
                guard let self, let window else { return }
                self.saveAnnotatedCopyToFolder(flattened, attachedTo: window)
            },
            onSaveAs: { [weak self, weak window] flattened in
                guard let self, let window else { return }
                self.saveAnnotatedCopy(flattened, originalFileURL: file.url, attachedTo: window)
            },
            onUpload: { [weak self, weak window] flattened in
                guard let self else { return }
                self.uploadCoordinator.upload(
                    flattened,
                    filename: "\(Self.annotatedName(forOriginal: file.url)).\(AppSettings.imageFormat.fileExtension)",
                    on: window?.screen ?? NSScreen.main,
                    // Already reviewed in this window — checking again would
                    // hold the upload for findings the user has just made a
                    // decision about, and stack a second review on the first.
                    checksForSensitiveContent: !canvas.hasReviewedSensitiveContent,
                    onHeld: { [weak canvas] _, matches, proceed in
                        // Review in the window the upload came from rather
                        // than opening another one onto the same capture.
                        canvas?.continueHeldUpload = proceed
                        canvas?.pendingRedactions = matches
                    }
                )
            },
            onScanForSensitiveContent: { [weak self, weak window, weak canvas] in
                guard let self, let canvas else { return }
                self.scanForSensitiveContent(in: canvas, attachedTo: window)
            },
            // Unlike its neighbours this closure is `@Sendable` and runs off
            // the main actor, so it can't read the `CaptureFile` box — it
            // takes the URL as it stands now. The only consequence of a
            // later rename is that a dragged-out file keeps the pre-rename
            // stem in its name; nothing reads the original file.
            onExportDragFile: { [originalFileURL = file.url] flattened in
                // Temp dir isn't TCC-protected, so this is safe wherever
                // the drop machinery calls it.
                // Always PNG: `AnnotatedFileDrag` declares a static
                // `.png` content type, so the file on disk has to match
                // what the drop destination was promised.
                try ScreenshotSaver.writeTemporaryImage(
                    flattened,
                    named: Self.annotatedName(forOriginal: originalFileURL),
                    format: .png
                )
            }
        )

        let annotationView = AnnotationView(
            canvas: canvas,
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

        let fileObserver = file.$url
            .dropFirst()
            .sink { [weak window] url in
                window?.title = Self.windowTitle(for: url)
            }

        windows[window] = AnnotationSession(aspect: aspect, toolbar: toolbar, fileObserver: fileObserver)
        if windows.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // As a child window the pill follows the annotation window's moves,
        // ordering, and miniaturization for free; only resizes need it
        // re-centered, which `windowDidResize` handles.
        window.addChildWindow(toolbar, ordered: .above)
        toolbar.reposition()
    }

    /// A crop changed the canvas's aspect ratio: re-lock the window to the
    /// new ratio and resize it in place — canvas width kept where possible,
    /// top-left corner anchored, clamped to the screen's visible area.
    private func canvasAspectChanged(for window: NSWindow, to aspect: CGFloat) {
        guard let oldAspect = windows[window]?.aspect else { return }
        windows[window]?.aspect = aspect
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

    /// Runs the credential check on demand and arms the review.
    ///
    /// The same review an upload trips (`docs/redaction.md`), reachable
    /// deliberately — you don't have to have uploading switched on, or be
    /// uploading at all, to black something out before sharing a screenshot
    /// some other way.
    ///
    /// The scan itself lives here rather than on `MarkupCanvasController`
    /// because it's the coordinator's job to call Services; the canvas only
    /// holds what to draw. It reads the **base image**, not a flattened
    /// export — findings are in image pixel coordinates, which is what
    /// redaction paints into.
    private func scanForSensitiveContent(in canvas: MarkupCanvasController, attachedTo window: NSWindow?) {
        guard !canvas.isScanningForSensitiveContent else { return }
        canvas.isScanningForSensitiveContent = true

        Task {
            let matches = await SensitiveContentDetector.detect(in: canvas.baseImage)
            canvas.isScanningForSensitiveContent = false

            guard !matches.isEmpty else {
                // A button that can silently do nothing gets pressed again,
                // and then distrusted — so it always answers.
                if let screen = window?.screen ?? NSScreen.main {
                    toastController.show(
                        message: "Nothing sensitive found",
                        systemImage: "checkmark.shield",
                        on: screen
                    )
                }
                return
            }
            canvas.pendingRedactions = matches
        }
    }

    /// One-click Save: writes the flattened image straight into the
    /// configured save folder under the timestamped naming convention (a
    /// new file — the original screenshot is never overwritten) and
    /// confirms with a toast, since the write is otherwise invisible.
    private func saveAnnotatedCopyToFolder(_ image: CGImage, attachedTo window: NSWindow) {
        Task {
            do {
                // Detached: a first write into a TCC-protected folder
                // blocks on the consent prompt (see CLAUDE.md).
                let url = try await Task.detached(priority: .userInitiated) {
                    try ScreenshotSaver.save(image)
                }.value
                if let screen = window.screen ?? NSScreen.main {
                    toastController.show(
                        message: "Saved to \(url.deletingLastPathComponent().lastPathComponent)",
                        systemImage: "checkmark.circle.fill",
                        on: screen
                    )
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't Save Annotated Screenshot"
                alert.informativeText = error.localizedDescription
                alert.beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    /// The file's own name, or the naming template's next name when the
    /// capture was never written to disk.
    private static func windowTitle(for fileURL: URL?) -> String {
        fileURL?.lastPathComponent
            ?? "\(ScreenshotSaver.name()).\(AppSettings.imageFormat.fileExtension)"
    }

    /// "<original> Annotated" — the naming shared by Save As…'s suggestion,
    /// the drag-out file, and the Immich upload's asset name; timestamped
    /// when there's no original on disk. `nonisolated` because the drag-out
    /// closure is `@Sendable` and calls this off the main actor.
    nonisolated private static func annotatedName(forOriginal fileURL: URL?) -> String {
        let baseName = fileURL?.deletingPathExtension().lastPathComponent ?? ScreenshotSaver.timestampedName()
        return baseName + " Annotated"
    }

    private func saveAnnotatedCopy(_ image: CGImage, originalFileURL: URL?, attachedTo window: NSWindow) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = ImageFormat.allCases.map(\.contentType)
        panel.directoryURL = ScreenshotSaver.saveDirectory
        panel.nameFieldStringValue = Self.annotatedName(forOriginal: originalFileURL)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    // Detached: a first write into a TCC-protected folder
                    // blocks on the consent prompt (see CLAUDE.md).
                    try await Task.detached(priority: .userInitiated) {
                        try ScreenshotSaver.write(image, to: url)
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

    /// Minimum window content width. The pill is its own window now, so this
    /// no longer has to fit it — but a window much narrower than the pill
    /// floating beneath it looks wrong, so the floor stays roughly there.
    /// The minimum height follows from the aspect lock instead of having its
    /// own floor.
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
        guard let aspect = windows[sender]?.aspect else { return frameSize }
        let chrome = AnnotationView.Layout.chromeSize
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        let current = sender.contentRect(forFrameRect: sender.frame).size

        // The canvas width each axis of the proposal asks for on its own.
        let fromWidth = proposed.width - chrome.width
        let fromHeight = (proposed.height - chrome.height) * aspect
        // AppKit proposes a change on the dragged axis only, so an edge drag
        // leaves the other one untouched (bar rounding).
        let widthMoved = abs(proposed.width - current.width) > 0.5
        let heightMoved = abs(proposed.height - current.height) > 0.5

        let canvasWidth: CGFloat
        if widthMoved && heightMoved {
            // Corner drag: project the proposal onto the constraint line
            // (least squares) instead of letting one axis drive outright.
            // Picking the axis that moved more made corner drags judder —
            // on a diagonal the winner flips from frame to frame, so width
            // and height take turns overshooting the mouse. A projection
            // has no branch to flip, so it stays continuous.
            let weight = 1 / (aspect * aspect)
            canvasWidth = (fromWidth + fromHeight * weight) / (1 + weight)
        } else if heightMoved {
            canvasWidth = fromHeight
        } else {
            // Also the no-op case, where this reproduces the current size.
            canvasWidth = fromWidth
        }

        let clampedCanvasWidth = max(canvasWidth, Self.minContentWidth - chrome.width)
        let content = Self.conformingContentSize(forCanvasWidth: clampedCanvasWidth, aspect: aspect)
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    /// Re-pin the tools pill: a resize can change the window's width (so the
    /// pill is no longer centered) and its origin (which AppKit tracks for
    /// child windows, but relative to the *old* frame).
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows[window]?.toolbar.reposition()
    }

    /// Zoom (green traffic light / double-click title bar): largest
    /// conforming frame that fits the screen's visible area, kept at the
    /// top of that area and horizontally centered.
    func windowWillUseStandardFrame(_ window: NSWindow, defaultFrame: NSRect) -> NSRect {
        guard let aspect = windows[window]?.aspect else { return defaultFrame }
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
        if let toolbar = windows[window]?.toolbar {
            window.removeChildWindow(toolbar)
            toolbar.close()
        }
        windows.removeValue(forKey: window)
        if windows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
