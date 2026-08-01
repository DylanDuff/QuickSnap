//
//  CaptureCoordinator.swift
//  QuickSnap
//

import AppKit
import Combine
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator: ObservableObject {
    /// What the current overlay session is for. Everything except `.window`
    /// shares the drag-to-select overlay; they diverge in what happens with
    /// the selected rect.
    private enum SelectionSessionKind {
        case area
        case window
        case textRecognition
        case copyForAI

        /// Whether the session can end in a file in the user's save folder.
        /// The two clipboard-only flows never do, so they skip the save
        /// folder's TCC warm-up entirely.
        var writesToSaveFolder: Bool {
            switch self {
            case .area, .window: return true
            case .textRecognition, .copyForAI: return false
            }
        }
    }

    private var overlayWindows: [SelectionOverlayWindow] = []
    private var isSessionActive = false
    private var sessionKind: SelectionSessionKind = .area
    private let previewController = ScreenshotPreviewController()
    private let annotationCoordinator = AnnotationCoordinator()
    private let hotkeyCoordinator = HotkeyCoordinator()
    private let toastController = ToastController()
    private let uploadCoordinator = UploadCoordinator()

    init() {
        AppSettings.migrateLegacySettings()
        AppSettings.registerDefaultHotkeys()
        hotkeyCoordinator.onAction = { [weak self] action in
            switch action {
            case .captureArea: self?.startAreaCapture()
            case .captureWindow: self?.startWindowCapture()
            case .captureFullScreen: self?.captureFullScreen()
            case .captureText: self?.startTextCapture()
            case .copyForAI: self?.startCopyForAI()
            }
        }
        hotkeyCoordinator.start()
        ZoomResizeProbe.startIfEnabled(annotationCoordinator: annotationCoordinator)
        runRetentionCleanup()
    }

    func startAreaCapture() {
        beginSelectionSession(kind: .area)
    }

    func startWindowCapture() {
        beginSelectionSession(kind: .window)
    }

    func startTextCapture() {
        beginSelectionSession(kind: .textRecognition)
    }

    func startCopyForAI() {
        beginSelectionSession(kind: .copyForAI)
    }

    func captureFullScreen() {
        Task { await performFullScreenCapture() }
    }

    func openSaveFolder() {
        Task {
            await prepareSaveFolderAccess()
            NSWorkspace.shared.open(ScreenshotSaver.saveDirectory)
        }
    }

    /// Touches the save folder off the main thread, and before any capture
    /// UI goes up. The first access to a TCC-protected folder (~/Documents)
    /// blocks inside the file syscall until the user answers the system
    /// privacy prompt — doing that mid-capture on the main thread froze the
    /// app under its own full-screen overlays. Failure is ignored here; an
    /// actual save failure still surfaces as an error alert.
    private func prepareSaveFolderAccess() async {
        await Task.detached(priority: .userInitiated) {
            try? ScreenshotSaver.prepareSaveDirectory()
        }.value
    }

    /// Applies the retention setting once per launch, off the main thread.
    /// Only ever removes files QuickSnap tagged as its own, and moves them
    /// to the Trash rather than deleting outright — see `SaveFolderCleaner`.
    private func runRetentionCleanup() {
        let days = AppSettings.retentionDays
        guard days > 0 else { return }
        Task.detached(priority: .background) {
            SaveFolderCleaner.clean(olderThan: days)
        }
    }

    // MARK: - Permission

    private func ensurePermission() -> Bool {
        if ScreenRecordingPermission.isGranted { return true }
        ScreenRecordingPermission.request()
        if ScreenRecordingPermission.isGranted { return true }

        let alert = NSAlert()
        alert.messageText = "Screen Recording Access Needed"
        // macOS TCC often doesn't recognize a freshly granted permission until the
        // process is relaunched, so we set that expectation up front.
        alert.informativeText = "QuickSnap needs Screen Recording permission to take screenshots. After granting access in System Settings, you may need to quit and reopen QuickSnap."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            ScreenRecordingPermission.openSystemSettings()
        }
        return false
    }

    // MARK: - Area / Window selection

    private func beginSelectionSession(kind: SelectionSessionKind) {
        guard !isSessionActive else { return }
        guard ensurePermission() else { return }

        Task {
            if kind.writesToSaveFolder, AppSettings.savesAfterCapture {
                await prepareSaveFolderAccess()
            }
            do {
                let content = try await ScreenCaptureManager.shareableContent()
                startOverlaySession(kind: kind, content: content)
            } catch {
                presentError(error)
            }
        }
    }

    private func startOverlaySession(kind: SelectionSessionKind, content: SCShareableContent) {
        isSessionActive = true
        sessionKind = kind
        // Deliberately no NSApp.activate here: the overlay panels are
        // non-activating so they can take key status for Esc on their own,
        // and activating would shove any open annotation/Settings windows
        // above the app the user is capturing over.

        for screen in NSScreen.screens {
            let window = SelectionOverlayWindow(screen: screen)
            let mode: SelectionMode

            if kind == .window {
                let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
                let displayBounds = CGDisplayBounds(displayID)
                let candidates = ScreenCaptureManager.capturableWindows(in: content).map { candidateWindow -> SelectionWindowCandidate in
                    let localFrame = candidateWindow.frame.offsetBy(dx: -displayBounds.origin.x, dy: -displayBounds.origin.y)
                    return SelectionWindowCandidate(window: candidateWindow, localFrame: localFrame)
                }
                mode = .window(candidates: candidates)
            } else {
                mode = .area
            }

            let view = SelectionOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size), mode: mode)
            view.delegate = self
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            overlayWindows.append(window)
        }
    }

    private func endSelectionSession() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        isSessionActive = false
    }

    private func screen(forOverlay view: SelectionOverlayView) -> NSScreen? {
        guard let window = view.window else { return nil }
        return NSScreen.screens.first { $0.frame == window.frame }
    }

    // MARK: - Capture execution

    private func performFullScreenCapture() async {
        guard ensurePermission() else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screen else { return }

        if AppSettings.savesAfterCapture {
            await prepareSaveFolderAccess()
        }

        do {
            let content = try await ScreenCaptureManager.shareableContent()
            guard let display = ScreenCaptureManager.display(for: screen, in: content) else {
                throw ScreenCaptureManagerError.displayNotFound
            }
            let image = try await ScreenCaptureManager.captureFullScreen(
                display: display,
                scale: screen.backingScaleFactor,
                showsCursor: AppSettings.showsCursorInCaptures
            )
            await finish(with: image, screen: screen, context: Self.filenameContext(for: image))
        } catch {
            presentError(error)
        }
    }

    private func captureSelectedArea(_ rect: CGRect, on screen: NSScreen) {
        Task {
            do {
                let content = try await ScreenCaptureManager.shareableContent()
                guard let display = ScreenCaptureManager.display(for: screen, in: content) else {
                    throw ScreenCaptureManagerError.displayNotFound
                }
                let image = try await ScreenCaptureManager.captureArea(
                    rect: rect,
                    display: display,
                    scale: screen.backingScaleFactor,
                    showsCursor: AppSettings.showsCursorInCaptures
                )
                await finish(
                    with: image,
                    screen: screen,
                    context: Self.filenameContext(for: image),
                    anchor: Self.screenFrame(forOverlayRect: rect, on: screen)
                )
            } catch {
                presentError(error)
            }
        }
    }

    /// OCR flow: capture the selected area, recognize text on-device, copy
    /// it to the clipboard, and confirm with a toast. Nothing is saved and
    /// no preview is shown — the after-screenshot toggles don't apply here.
    private func recognizeTextInArea(_ rect: CGRect, on screen: NSScreen) {
        Task {
            do {
                let content = try await ScreenCaptureManager.shareableContent()
                guard let display = ScreenCaptureManager.display(for: screen, in: content) else {
                    throw ScreenCaptureManagerError.displayNotFound
                }
                let image = try await ScreenCaptureManager.captureArea(rect: rect, display: display, scale: screen.backingScaleFactor)
                let text = try await TextRecognizer.recognizeText(in: image)

                if text.isEmpty {
                    toastController.show(message: "No text found", systemImage: "text.magnifyingglass", on: screen)
                } else {
                    ScreenshotSaver.copyToClipboard(text)
                    let preview = AppSettings.showsTextPreviewInToast
                        ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                        : nil
                    toastController.show(message: "Text copied to clipboard", systemImage: "checkmark.circle.fill", detail: preview, on: screen)
                }
            } catch {
                presentError(error)
            }
        }
    }

    /// Copy for AI: capture the selected area and put it on the clipboard as
    /// a markdown block — image path, source app, timestamp and (optionally)
    /// the on-screen text — alongside the image itself. One paste then hands
    /// a chat tool or coding agent the context the user would otherwise
    /// retype.
    ///
    /// Like the OCR flow, the after-screenshot toggles deliberately don't
    /// apply: the clipboard *is* the output. The image still needs to exist
    /// somewhere for the markdown to point at, so it goes to a temp file
    /// rather than the save folder — the user didn't ask to archive this.
    private func copyContextForAI(_ rect: CGRect, on screen: NSScreen) {
        Task {
            do {
                let content = try await ScreenCaptureManager.shareableContent()
                guard let display = ScreenCaptureManager.display(for: screen, in: content) else {
                    throw ScreenCaptureManagerError.displayNotFound
                }
                let image = try await ScreenCaptureManager.captureArea(
                    rect: rect,
                    display: display,
                    scale: screen.backingScaleFactor,
                    showsCursor: AppSettings.showsCursorInCaptures
                )
                // Read before awaiting anything else: the frontmost app is
                // what the user was looking at, and an alert or another app
                // stealing focus mid-flow would change the answer.
                let appName = NSWorkspace.shared.frontmostApplication?.localizedName

                let recognizedText = AppSettings.copyForAIIncludesText
                    ? try? await TextRecognizer.recognizeText(in: image)
                    : nil

                // Encoding a retina capture is real work; keep it off main.
                let imageURL = await Task.detached(priority: .userInitiated) {
                    try? ScreenshotSaver.writeTemporaryImage(image, format: .png)
                }.value

                let markdown = CaptureContextMarkdown.render(
                    imageURL: imageURL,
                    appName: appName,
                    windowTitle: nil,
                    recognizedText: recognizedText
                )
                ScreenshotSaver.copyToClipboard(image, text: markdown)
                toastController.show(
                    message: "Copied for AI",
                    systemImage: "checkmark.circle.fill",
                    detail: recognizedText?.isEmpty == false ? "Image and text on the clipboard" : nil,
                    on: screen
                )
            } catch {
                presentError(error)
            }
        }
    }

    private func captureSelectedWindow(_ window: SCWindow, on screen: NSScreen) {
        Task {
            do {
                let image = try await ScreenCaptureManager.captureWindow(
                    window,
                    scale: screen.backingScaleFactor,
                    showsCursor: AppSettings.showsCursorInCaptures
                )
                let style = AppSettings.windowBackgroundStyle
                let paddingPixels = AppSettings.windowBackgroundPadding * screen.backingScaleFactor
                let backgroundColor = AppSettings.windowBackgroundColor
                let wallpaperURL = style == .wallpaper ? NSWorkspace.shared.desktopImageURL(for: screen) : nil
                // Off-main: the wallpaper file read can be TCC-gated (a
                // consent prompt blocks inside it) and compositing is CPU work.
                let styled = await Task.detached(priority: .userInitiated) {
                    WindowBackgroundRenderer.render(
                        window: image,
                        style: style,
                        paddingPixels: paddingPixels,
                        backgroundColor: backgroundColor,
                        wallpaper: WindowBackgroundRenderer.wallpaper(at: wallpaperURL)
                    )
                }.value
                await finish(
                    with: styled,
                    screen: screen,
                    context: Self.filenameContext(
                        for: styled,
                        appName: window.owningApplication?.applicationName,
                        windowTitle: window.title
                    ),
                    // The window's own frame, not the styled image's — the
                    // background padding grows the capture symmetrically, so
                    // the center the preview homes to is the same either way.
                    anchor: Self.screenFrame(forQuartzRect: window.frame)
                )
            } catch {
                presentError(error)
            }
        }
    }

    /// Names a capture: the window's own app/title when we have them,
    /// otherwise whatever app was frontmost. The overlay panels are
    /// non-activating, so the user's app is still frontmost during a
    /// session and `{app}` resolves to what they were actually looking at.
    private static func filenameContext(
        for image: CGImage,
        appName: String? = nil,
        windowTitle: String? = nil
    ) -> FilenameContext {
        FilenameContext(
            date: Date(),
            appName: appName ?? NSWorkspace.shared.frontmostApplication?.localizedName,
            windowTitle: windowTitle,
            pixelWidth: image.width,
            pixelHeight: image.height
        )
    }

    /// Converts a rect from a selection overlay's flipped, screen-local
    /// space (top-left origin, points — see `SelectionOverlayView.isFlipped`)
    /// to AppKit's global screen coordinates.
    private static func screenFrame(forOverlayRect rect: CGRect, on screen: NSScreen) -> CGRect {
        CGRect(
            x: screen.frame.minX + rect.minX,
            y: screen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// Converts a global Quartz rect (top-left origin, y growing downward —
    /// `SCWindow.frame`'s space) to AppKit's global screen coordinates.
    /// Both spaces share an origin display; they differ only in y direction,
    /// so the flip is about that display's height. `NSScreen.screens.first`
    /// is that display: the one AppKit places at (0, 0).
    private static func screenFrame(forQuartzRect rect: CGRect) -> CGRect {
        guard let originScreen = NSScreen.screens.first else { return rect }
        return CGRect(
            x: rect.minX,
            y: originScreen.frame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// `anchor` is the region the capture covered, in AppKit global screen
    /// coordinates — nil for a full-screen capture, whose region is the
    /// whole screen and so isn't worth pointing the preview at. Only
    /// `NotificationPosition.dynamic` uses it.
    private func finish(
        with image: CGImage,
        screen: NSScreen,
        context: FilenameContext,
        anchor: CGRect? = nil
    ) async {
        do {
            // Detached so a TCC consent prompt (first write to ~/Documents)
            // blocks a background thread, never the main thread.
            let url = AppSettings.savesAfterCapture
                ? try await Task.detached(priority: .userInitiated) {
                    try ScreenshotSaver.save(image, context: context)
                }.value
                : nil
            if AppSettings.copiesAfterCapture {
                ScreenshotSaver.copyToClipboard(image)
            }
            if AppSettings.uploadsAfterCapture {
                uploadCoordinator.upload(image, on: screen)
            }
            if AppSettings.showsPreviewAfterCapture {
                // The panel offers Upload only when Immich is configured and
                // the button is switched on — and not when the capture was
                // already uploaded automatically, which would just duplicate it.
                let offersUpload = uploadCoordinator.isConfigured
                    && AppSettings.uploadShowsPreviewButton
                    && !AppSettings.uploadsAfterCapture
                previewController.show(
                    image: image,
                    fileURL: url,
                    on: screen,
                    scale: screen.backingScaleFactor,
                    anchor: anchor,
                    onUpload: offersUpload
                        ? { [weak self] image in self?.uploadCoordinator.upload(image, on: screen) }
                        : nil,
                    onEdit: { [weak self] image, fileURL in
                        self?.annotationCoordinator.openAnnotationWindow(image: image, fileURL: fileURL)
                    }
                )
            }
        } catch {
            presentError(error)
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "QuickSnap Couldn't Capture the Screenshot"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

extension CaptureCoordinator: SelectionOverlayViewDelegate {
    func selectionOverlayView(_ view: SelectionOverlayView, didSelectAreaRect rect: CGRect) {
        guard let screen = screen(forOverlay: view) else { endSelectionSession(); return }
        let kind = sessionKind
        endSelectionSession()

        switch kind {
        case .textRecognition:
            recognizeTextInArea(rect, on: screen)
        case .copyForAI:
            copyContextForAI(rect, on: screen)
        case .area, .window:
            captureSelectedArea(rect, on: screen)
        }
    }

    func selectionOverlayView(_ view: SelectionOverlayView, didSelectWindow window: SCWindow) {
        guard let screen = screen(forOverlay: view) else { endSelectionSession(); return }
        endSelectionSession()
        captureSelectedWindow(window, on: screen)
    }

    func selectionOverlayViewDidCancel(_ view: SelectionOverlayView) {
        endSelectionSession()
    }
}
