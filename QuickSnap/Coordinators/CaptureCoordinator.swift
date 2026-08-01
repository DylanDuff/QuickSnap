//
//  CaptureCoordinator.swift
//  QuickSnap
//

import AppKit
import Combine
import ScreenCaptureKit

@MainActor
final class CaptureCoordinator: ObservableObject {
    /// What the current overlay session is for. `.area` and
    /// `.textRecognition` share the drag-to-select overlay; they diverge in
    /// what happens with the selected rect.
    private enum SelectionSessionKind {
        case area
        case window
        case textRecognition
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
        AppSettings.registerDefaultHotkeys()
        hotkeyCoordinator.onAction = { [weak self] action in
            switch action {
            case .captureArea: self?.startAreaCapture()
            case .captureWindow: self?.startWindowCapture()
            case .captureFullScreen: self?.captureFullScreen()
            case .captureText: self?.startTextCapture()
            }
        }
        hotkeyCoordinator.start()
        ZoomResizeProbe.startIfEnabled(annotationCoordinator: annotationCoordinator)
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
            // Text recognition never writes a file — no folder access needed.
            if kind != .textRecognition, AppSettings.savesAfterCapture {
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
            let image = try await ScreenCaptureManager.captureFullScreen(display: display, scale: screen.backingScaleFactor)
            await finish(with: image, screen: screen)
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
                let image = try await ScreenCaptureManager.captureArea(rect: rect, display: display, scale: screen.backingScaleFactor)
                await finish(with: image, screen: screen)
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

    private func captureSelectedWindow(_ window: SCWindow, on screen: NSScreen) {
        Task {
            do {
                let image = try await ScreenCaptureManager.captureWindow(window, scale: screen.backingScaleFactor)
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
                await finish(with: styled, screen: screen)
            } catch {
                presentError(error)
            }
        }
    }

    private func finish(with image: CGImage, screen: NSScreen) async {
        do {
            // Detached so a TCC consent prompt (first write to ~/Documents)
            // blocks a background thread, never the main thread.
            let url = AppSettings.savesAfterCapture
                ? try await Task.detached(priority: .userInitiated) { try ScreenshotSaver.save(image) }.value
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

        if kind == .textRecognition {
            recognizeTextInArea(rect, on: screen)
        } else {
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
