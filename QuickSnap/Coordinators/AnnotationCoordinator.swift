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
    /// Per-window state.
    ///
    /// There is deliberately no aspect ratio here any more: the window
    /// resizes freely and the canvas inside it is a viewport onto the
    /// capture, not a frame around it.
    private struct AnnotationSession {
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
        window.contentMinSize = Self.minContentSize
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
            onSave: { [weak self, weak window] flattened in
                guard let self, let window else { return }
                self.saveAnnotatedCopyToFolder(flattened, attachedTo: window)
            },
            onSaveAs: { [weak self, weak window] flattened in
                guard let self, let window else { return }
                self.saveAnnotatedCopy(flattened, originalFileURL: file.url, attachedTo: window)
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

        windows[window] = AnnotationSession(toolbar: toolbar, fileObserver: fileObserver)
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
                closeAfterSaveIfEnabled(window)
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
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    // Detached: a first write into a TCC-protected folder
                    // blocks on the consent prompt (see CLAUDE.md).
                    try await Task.detached(priority: .userInitiated) {
                        try ScreenshotSaver.write(image, to: url)
                    }.value
                    self?.closeAfterSaveIfEnabled(window)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = "Couldn't Save Annotated Screenshot"
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    /// Closes the window a save came from, if the user has left that setting
    /// on. Called only once the write has actually succeeded — a failed save
    /// keeps the window (and the work in it) around, and a cancelled Save As…
    /// never gets here at all.
    ///
    /// The setting is read here, at save time, rather than captured when the
    /// window opened, so changing it applies to windows already on screen.
    /// `close()` runs the same teardown path as the close button
    /// (`windowWillClose` drops the toolbar pill and reverts the activation
    /// policy), so there's nothing extra to unwind.
    private func closeAfterSaveIfEnabled(_ window: NSWindow) {
        guard AppSettings.markupClosesAfterSave, windows[window] != nil else { return }
        window.close()
    }

    /// Floor for a freely-resizable window. The pill is its own window, so
    /// this no longer has to fit it — but a window much narrower than the
    /// pill floating beneath it looks wrong, so the width floor stays
    /// roughly there. Height needs its own floor now that it doesn't follow
    /// from an aspect ratio.
    private static let minContentSize = CGSize(width: 480, height: 320)

    /// Windows open showing the capture at actual size where that fits, so
    /// what you see is the size the thing really was. Big captures are
    /// capped to a comfortable share of the screen rather than opening
    /// enormous — the canvas is then simply larger than the viewport, which
    /// costs nothing now that zoom and window size are independent.
    private static func initialContentSize(forImageSize imageSize: CGSize) -> CGSize {
        let chrome = AnnotationView.Layout.chromeSize
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2
        let actualSize = CGSize(
            width: imageSize.width / backingScale,
            height: imageSize.height / backingScale
        )
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
        return CGSize(
            width: min(max(actualSize.width + chrome.width, minContentSize.width), visible.width * 0.7),
            height: min(max(actualSize.height + chrome.height, minContentSize.height), visible.height * 0.7)
        )
    }
}

extension AnnotationCoordinator: NSWindowDelegate {
    /// No `windowWillResize` / `windowWillUseStandardFrame` here on purpose.
    /// The window used to be locked to "canvas at the image's aspect ratio +
    /// fixed chrome", which is what made it a frame around the capture; now
    /// it resizes freely and the canvas is a viewport, so AppKit's own
    /// behaviour (including the zoom button) is exactly right and every
    /// constraint that fought it — including the least-squares projection
    /// that stopped corner drags juddering — is gone with the lock.

    /// Re-pin the tools pill: a resize can change the window's width (so the
    /// pill is no longer centered) and its origin (which AppKit tracks for
    /// child windows, but relative to the *old* frame).
    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        windows[window]?.toolbar.reposition()
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
