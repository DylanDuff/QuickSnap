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

    /// What an overlay session produced, for the callers that want the
    /// selection itself rather than the default follow-on behaviour.
    enum SelectionResult {
        case area(CGRect, NSScreen)
        case window(SCWindow, NSScreen)
    }

    private var overlayWindows: [SelectionOverlayWindow] = []
    private var isSessionActive = false
    private var sessionKind: SelectionSessionKind = .area
    /// Set only while a caller is awaiting a selection (currently just the
    /// MCP server). When it's set the delegate hands the result straight
    /// back instead of running the normal capture flow.
    private var sessionContinuation: CheckedContinuation<SelectionResult?, Never>?
    private var sessionTimeout: Task<Void, Never>?
    private let previewController = ScreenshotPreviewController()
    private let annotationCoordinator = AnnotationCoordinator()
    private let hotkeyCoordinator = HotkeyCoordinator()
    private let toastController = ToastController()
    private let uploadCoordinator = UploadCoordinator()
    private let mcpCoordinator = MCPCoordinator()
    private let captureIndexer = CaptureIndexer.shared
    private lazy var searchController = CaptureSearchController(
        onEdit: { [weak self] image, file in
            self?.annotationCoordinator.openAnnotationWindow(image: image, file: file)
        }
    )

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
            case .searchCaptures: self?.showCaptureSearch()
            }
        }
        hotkeyCoordinator.start()
        mcpCoordinator.host = self
        mcpCoordinator.startIfEnabled()
        // Before anything else user-facing: on a first run this is the
        // app's whole first impression, and it's where the Screen
        // Recording prompt and the save folder's TCC prompt are meant to
        // be answered — not mid-capture, under a full-screen overlay.
        OnboardingRenderProbe.runIfEnabled()
        OnboardingRenderProbe.inspectWindowIfEnabled()
        OnboardingCoordinator.shared.showIfFirstRun()
        UndoProbe.startIfEnabled(annotationCoordinator: annotationCoordinator)
        FreeZoomProbe.startIfEnabled(annotationCoordinator: annotationCoordinator)
        Task {
            await runRetentionCleanup()
            // After retention, so the index's launch reconcile doesn't walk
            // a folder that's about to lose files.
            captureIndexer.startIfNeeded()
        }
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
    private func runRetentionCleanup() async {
        let days = AppSettings.retentionDays
        guard days > 0 else { return }
        let removed = await Task.detached(priority: .background) {
            SaveFolderCleaner.clean(olderThan: days)
        }.value
        // A search hit that opens nothing is worse than no hit.
        captureIndexer.captureFilesRemoved(removed)
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

    // MARK: - Awaited selection

    /// Runs a selection session and returns what the user picked, or nil if
    /// they cancelled or ran out of time. Used by the MCP server, which
    /// needs the selection as a value rather than as a side effect.
    private func awaitSelection(kind: SelectionSessionKind, timeout: TimeInterval) async throws -> SelectionResult? {
        guard !isSessionActive else { throw MCPToolError.captureSessionBusy }
        let content = try await ScreenCaptureManager.shareableContent()

        return await withCheckedContinuation { continuation in
            sessionContinuation = continuation
            startOverlaySession(kind: kind, content: content)
            sessionTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.endSelectionSession()
                self?.completeSession(nil)
            }
        }
    }

    /// Hands `result` to whoever is awaiting the session, and reports whether
    /// anyone was — a false return means the delegate should carry on with
    /// the normal capture flow.
    @discardableResult
    private func completeSession(_ result: SelectionResult?) -> Bool {
        guard let continuation = sessionContinuation else { return false }
        sessionContinuation = nil
        sessionTimeout?.cancel()
        sessionTimeout = nil
        continuation.resume(returning: result)
        return true
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

    /// Captures `rect` (in the overlay's flipped, screen-local point space)
    /// from `screen`. The one path from a selected rectangle to pixels —
    /// shared by the area capture, OCR, Copy for AI and MCP flows.
    private func captureArea(
        _ rect: CGRect,
        on screen: NSScreen,
        showsCursor: Bool = AppSettings.showsCursorInCaptures
    ) async throws -> CGImage {
        let content = try await ScreenCaptureManager.shareableContent()
        guard let display = ScreenCaptureManager.display(for: screen, in: content) else {
            throw ScreenCaptureManagerError.displayNotFound
        }
        return try await ScreenCaptureManager.captureArea(
            rect: rect,
            display: display,
            scale: screen.backingScaleFactor,
            showsCursor: showsCursor
        )
    }

    private func captureSelectedArea(_ rect: CGRect, on screen: NSScreen) {
        Task {
            do {
                let image = try await captureArea(rect, on: screen)
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
                let image = try await captureArea(rect, on: screen, showsCursor: false)
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
                let image = try await captureArea(rect, on: screen)
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
            // Resolved before the write so the same template — same counter,
            // same timestamp — can be re-rendered if a description arrives
            // for `{describe}` later.
            let name = ScreenshotSaver.resolvedName(for: context)
            // Detached so a TCC consent prompt (first write to ~/Documents)
            // blocks a background thread, never the main thread.
            let url = AppSettings.savesAfterCapture
                ? try await Task.detached(priority: .userInitiated) {
                    try ScreenshotSaver.save(image, name: name)
                }.value
                : nil
            let file = CaptureFile(url: url)
            if url != nil {
                enrichSavedCapture(image, file: file, name: name)
            }
            if AppSettings.copiesAfterCapture {
                ScreenshotSaver.copyToClipboard(image)
            }
            if AppSettings.uploadsAfterCapture {
                upload(image, file: file, on: screen)
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
                    file: file,
                    on: screen,
                    scale: screen.backingScaleFactor,
                    anchor: anchor,
                    onUpload: offersUpload
                        ? { [weak self] image in self?.upload(image, file: file, on: screen) }
                        : nil,
                    onEdit: { [weak self] image, file in
                        self?.annotationCoordinator.openAnnotationWindow(image: image, file: file)
                    }
                )
            }
        } catch {
            presentError(error)
        }
    }

    /// Everything that happens to a saved capture *after* it's on disk: the
    /// `{describe}` rename, and the search index.
    ///
    /// One method because both want the same expensive thing — Vision's OCR,
    /// plus the model's description of it — and running `CaptureAnalyzer`
    /// once per consumer would double the cost of every capture for an
    /// answer we already have.
    ///
    /// Deliberately not part of the save: a model round trip takes seconds,
    /// and a capture that isn't saved until it finishes is a capture that
    /// can be lost. So the file lands immediately under a name with the
    /// `{describe}` token empty, and moves once — or not at all, if
    /// intelligence is off, the provider is unavailable, the model returns
    /// nothing, or the slug sanitizes away to nothing. Every one of those
    /// falls back to the name the file already has, which is a complete
    /// name in its own right.
    ///
    /// The rename is a move within the folder, so the `FileTag` xattr rides
    /// along and retention still recognises the file. `file` is the box the
    /// preview panel and any annotation window are holding, so updating it
    /// is what keeps their Reveal in Finder and drag-out pointing at the
    /// file that now exists.
    private func enrichSavedCapture(_ image: CGImage, file: CaptureFile, name: ResolvedFilename) {
        let describes = name.awaitsDescription && AppSettings.isAIEnabled
        let indexes = AppSettings.isCaptureIndexingEnabled
        guard describes || indexes else { return }

        Task {
            // The index wants a caption too when intelligence is on, even if
            // the filename template never asked for one.
            let analysis = await CaptureAnalyzer.analyze(
                image,
                appName: name.context.appName,
                windowTitle: name.context.windowTitle,
                describes: describes || (indexes && AppSettings.isAIEnabled)
            )

            if describes, let description = analysis.description {
                await rename(file, to: name.describing(description), from: name)
            }

            // Indexed last, so the row carries the name the file ended up
            // with rather than one it held for two seconds.
            if indexes, let url = file.url {
                captureIndexer.index(url, analysis: analysis, context: name.context)
            }
        }
    }

    private func rename(_ file: CaptureFile, to described: ResolvedFilename, from name: ResolvedFilename) async {
        guard described.value != name.value, let currentURL = file.url else { return }

        // Detached for the same reason the save is: the save folder can be
        // TCC-protected, and a move inside it blocks in the syscall.
        let renamed = await Task.detached(priority: .utility) {
            try? ScreenshotSaver.rename(currentURL, toBaseName: described.value)
        }.value
        guard let renamed else { return }
        file.moved(to: renamed)
        captureIndexer.captureMoved(from: currentURL, to: renamed)
    }

    /// Uploads a capture, with the redaction gate wired to the annotation
    /// window: if the capture turns out to hold credentials, nothing is sent
    /// — the window opens with the findings under review instead, and the
    /// upload only continues from there, carrying whatever the user left
    /// behind (see `docs/redaction.md`).
    private func upload(_ image: CGImage, file: CaptureFile, on screen: NSScreen?) {
        uploadCoordinator.upload(image, on: screen) { [weak self] flagged, matches, proceed in
            self?.annotationCoordinator.openAnnotationWindow(
                image: flagged,
                file: file,
                heldUpload: AnnotationCoordinator.HeldUpload(matches: matches, proceed: proceed)
            )
        }
    }

    // MARK: - Search

    func showCaptureSearch() {
        searchController.toggle()
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
        guard let screen = screen(forOverlay: view) else { endSelectionSession(); completeSession(nil); return }
        let kind = sessionKind
        endSelectionSession()

        guard !completeSession(.area(rect, screen)) else { return }

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
        guard let screen = screen(forOverlay: view) else { endSelectionSession(); completeSession(nil); return }
        endSelectionSession()
        guard !completeSession(.window(window, screen)) else { return }
        captureSelectedWindow(window, on: screen)
    }

    func selectionOverlayViewDidCancel(_ view: SelectionOverlayView) {
        endSelectionSession()
        completeSession(nil)
    }
}


// MARK: - MCP

/// The capture surface the MCP server drives.
///
/// Agent-initiated captures deliberately **do not** run the after-capture
/// actions. An agent asked for the pixels; saving a file, overwriting the
/// user's clipboard and popping a preview panel on every tool call would be
/// noise the user never asked for — and the tool result already hands back a
/// path. Window captures skip `WindowBackgroundRenderer` for the same
/// reason: a wallpaper-padded presentation shot is worse input than the bare
/// window.
extension CaptureCoordinator: MCPCaptureHost {
    func captureInteractiveArea(timeout: TimeInterval) async throws -> CGImage? {
        try requireScreenRecordingPermission()
        guard case .area(let rect, let screen)? = try await awaitSelection(kind: .area, timeout: timeout) else {
            return nil
        }
        return try await captureArea(rect, on: screen)
    }

    func captureWindow(matchingApp app: String, title: String?) async throws -> (image: CGImage, description: String) {
        try requireScreenRecordingPermission()
        let window = try await matchingWindow(app: app, title: title)
        let screen = screen(containing: window)
        let image = try await ScreenCaptureManager.captureWindow(
            window,
            scale: screen?.backingScaleFactor ?? 2,
            showsCursor: false
        )
        announceAgentCapture(on: screen)
        return (image, Self.describe(window))
    }

    func captureDisplay(index: Int?) async throws -> CGImage {
        try requireScreenRecordingPermission()
        let screens = NSScreen.screens
        let screen: NSScreen?
        if let index {
            guard screens.indices.contains(index) else {
                throw MCPToolError.displayNotFound(available: screens.count)
            }
            screen = screens[index]
        } else {
            screen = screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        }
        guard let screen else { throw MCPToolError.displayNotFound(available: screens.count) }

        let content = try await ScreenCaptureManager.shareableContent()
        guard let display = ScreenCaptureManager.display(for: screen, in: content) else {
            throw ScreenCaptureManagerError.displayNotFound
        }
        let image = try await ScreenCaptureManager.captureFullScreen(
            display: display,
            scale: screen.backingScaleFactor,
            showsCursor: false
        )
        announceAgentCapture(on: screen)
        return image
    }

    func recognizeText(matchingApp app: String?, title: String?) async throws -> String {
        try requireScreenRecordingPermission()
        let image: CGImage
        if let app {
            let window = try await matchingWindow(app: app, title: title)
            image = try await ScreenCaptureManager.captureWindow(
                window,
                scale: screen(containing: window)?.backingScaleFactor ?? 2
            )
            announceAgentCapture(on: screen(containing: window))
        } else {
            image = try await captureDisplay(index: nil)
        }
        return try await TextRecognizer.recognizeText(in: image)
    }

    func capturableWindows() async throws -> [String] {
        try requireScreenRecordingPermission()
        let content = try await ScreenCaptureManager.shareableContent()
        return ScreenCaptureManager.capturableWindows(in: content).map(Self.describe)
    }

    // MARK: Support

    private func requireScreenRecordingPermission() throws {
        // Deliberately doesn't call `ensurePermission()`: that runs a modal
        // NSAlert, which would block the server's response until the user
        // happened to notice and dismiss it.
        guard ScreenRecordingPermission.isGranted else {
            throw MCPToolError.screenRecordingDenied
        }
    }

    /// The frontmost capturable window whose app (and optionally title)
    /// matches. `SCShareableContent` is ordered front to back, so first match
    /// is the one the user is most likely to mean.
    private func matchingWindow(app: String, title: String?) async throws -> SCWindow {
        let content = try await ScreenCaptureManager.shareableContent()
        let candidates = ScreenCaptureManager.capturableWindows(in: content)
        let match = candidates.first { window in
            guard let appName = window.owningApplication?.applicationName,
                  appName.localizedCaseInsensitiveContains(app)
            else {
                return false
            }
            guard let title else { return true }
            return window.title?.localizedCaseInsensitiveContains(title) == true
        }
        guard let match else {
            throw MCPToolError.windowNotFound(app: app, available: candidates.map(Self.describe))
        }
        return match
    }

    private func screen(containing window: SCWindow) -> NSScreen? {
        let frame = Self.screenFrame(forQuartzRect: window.frame)
        return NSScreen.screens.max { first, second in
            first.frame.intersection(frame).area < second.frame.intersection(frame).area
        }
    }

    /// A capture an agent asked for happens with no other visible sign, so
    /// the toast is the user's only indication that something read their
    /// screen. Interactive selection doesn't need it — the overlay was the
    /// notice.
    private func announceAgentCapture(on screen: NSScreen?) {
        guard let screen = screen ?? NSScreen.main else { return }
        toastController.show(
            message: "Screenshot shared with \(MCPProtocol.serverName)",
            systemImage: "sparkles",
            on: screen
        )
    }

    private static func describe(_ window: SCWindow) -> String {
        let appName = window.owningApplication?.applicationName ?? "Unknown"
        guard let title = window.title, !title.isEmpty, title != appName else { return appName }
        return "\(appName) — \(title)"
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
