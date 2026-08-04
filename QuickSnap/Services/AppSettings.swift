//
//  AppSettings.swift
//  QuickSnap
//

import AppKit
import Security

/// How a Window-mode capture is presented. Everything except `trimShadow`
/// pads the window out and draws a soft shadow behind it; `trimShadow` is
/// the bare edge-to-edge window.
enum WindowBackgroundStyle: String, CaseIterable {
    case wallpaper
    case transparent
    case solidColor
    case trimShadow

    var displayName: String {
        switch self {
        case .wallpaper: return "Wallpaper"
        case .transparent: return "Transparent"
        case .solidColor: return "Solid Color"
        case .trimShadow: return "Trim Shadow"
        }
    }
}

/// Where a transient panel (screenshot preview thumbnail, toast) appears.
/// The two edge cases only flip the edge and the slide direction —
/// horizontal placement is each panel's own affair (preview: trailing
/// corner, toast: centered).
///
/// Two cases belong to one panel each, and each picker offers only its own
/// subset (`previewCases` / `toastCases`) — but a value stored before the
/// split, or migrated from the old shared key, can still be the other one, so
/// both `AppSettings` accessors map a foreign case back to `.bottom` and
/// nothing downstream has to handle it:
///
/// - `.dynamic` is preview-only: the thumbnail is centered on whatever the
///   capture covered (the selected area, the captured window) instead of homing
///   to a corner, falling back to `.bottom` when there's no such region — a
///   full-screen capture.
/// - `.notificationCenter` is toast-only, and isn't a position at all: it hands
///   confirmations to the system instead of drawing a pill (see
///   `SystemNotifier`). It rides in this enum because it's the third choice in
///   the same one-of-three picker; `edgeCases` stays the "is a real screen
///   edge" subset that the placement maths needs.
nonisolated enum NotificationPosition: String, CaseIterable {
    case bottom
    case top
    case dynamic
    case notificationCenter

    /// The subset that means "a screen edge" — everything a panel with no
    /// capture region of its own can offer.
    static let edgeCases: [NotificationPosition] = [.bottom, .top]

    /// What each picker offers.
    static let previewCases: [NotificationPosition] = edgeCases + [.dynamic]
    static let toastCases: [NotificationPosition] = edgeCases + [.notificationCenter]

    var displayName: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        case .dynamic: return "Dynamic"
        case .notificationCenter: return "Notification"
        }
    }
}

/// UserDefaults-backed app settings. The `Keys` and `Defaults` constants are
/// the single source of truth shared by the typed accessors here (used by
/// Coordinators/Services) and the `@AppStorage` properties in the settings
/// UI — keep both reading the same key with the same default.
/// `nonisolated` (UserDefaults is thread-safe) so Services running off the
/// main thread can read it.
nonisolated enum AppSettings {
    enum Keys {
        static let saveFolderPath = "saveFolderPath"
        static let filenameTemplate = "filenameTemplate"
        static let filenameCounter = "filenameCounter"
        static let imageFormat = "imageFormat"
        static let imageQuality = "imageQuality"
        static let showsCursorInCaptures = "showsCursorInCaptures"
        static let retentionDays = "retentionDays"
        static let uploadTimeoutSeconds = "uploadTimeoutSeconds"
        static let uploadRetryCount = "uploadRetryCount"
        static let showPreviewAfterCapture = "showPreviewAfterCapture"
        static let copyAfterCapture = "copyAfterCapture"
        static let saveAfterCapture = "saveAfterCapture"
        static let previewPosition = "previewPosition"
        static let toastPosition = "toastPosition"
        /// Superseded by the two keys above; read once by
        /// `migrateLegacySettings()` and then removed.
        static let legacyNotificationPosition = "notificationPosition"
        static let previewAutoDismissSeconds = "previewAutoDismissSeconds"
        static let toastAutoDismissSeconds = "toastAutoDismissSeconds"
        static let showTextPreviewInToast = "showTextPreviewInToast"
        static let copyForAIIncludesText = "copyForAIIncludesText"
        static let aiEnabled = "aiEnabled"
        static let captureIndexingEnabled = "captureIndexingEnabled"
        static let mcpEnabled = "mcpEnabled"
        static let mcpPort = "mcpPort"
        static let windowBackgroundStyle = "windowBackgroundStyle"
        static let windowBackgroundPadding = "windowBackgroundPadding"
        static let windowBackgroundColor = "windowBackgroundColor"
        static let markupDefaultColor = "markupDefaultColor"
        static let markupDefaultStrokeStep = "markupDefaultStrokeStep"
        static let markupShowsCopyButton = "markupShowsCopyButton"
        static let markupShowsSaveButton = "markupShowsSaveButton"
        static let markupShowsSaveAsButton = "markupShowsSaveAsButton"
        static let markupShowsDragButton = "markupShowsDragButton"
        static let markupShowsUploadButton = "markupShowsUploadButton"
        static let markupShowsRedactionButton = "markupShowsRedactionButton"
        static let markupToolbarLayout = "markupToolbarLayout"
        static let markupClosesAfterSave = "markupClosesAfterSave"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let previewDoubleClickOpensMarkup = "previewDoubleClickOpensMarkup"
        // Uploading — provider-neutral settings…
        static let uploadingEnabled = "uploadingEnabled"
        static let uploadProvider = "uploadProvider"
        static let uploadAfterCapture = "uploadAfterCapture"
        static let uploadCopiesLink = "uploadCopiesLink"
        static let uploadShowsPreviewButton = "uploadShowsPreviewButton"
        static let checkUploadsForSensitiveContent = "checkUploadsForSensitiveContent"
        // …and each provider's own configuration, kept prefixed.
        static let immichServerURL = "immichServerURL"
        static let immichAlbumID = "immichAlbumID"
        static let immichAlbumName = "immichAlbumName"
        static let s3Endpoint = "s3Endpoint"
        static let s3Region = "s3Region"
        static let s3Bucket = "s3Bucket"
        static let s3AccessKeyID = "s3AccessKeyID"
        static let s3KeyPrefix = "s3KeyPrefix"
        static let s3PublicBaseURL = "s3PublicBaseURL"
        static let s3UsesPathStyle = "s3UsesPathStyle"
        static let s3PublicRead = "s3PublicRead"

        static func hotkey(for action: HotkeyAction) -> String {
            "hotkey.\(action.rawValue)"
        }
    }

    enum Defaults {
        /// Reproduces the original hardcoded naming exactly, so the
        /// out-of-box behaviour is unchanged.
        static let filenameTemplate = FilenameTemplate.defaultTemplate
        static let imageFormat = ImageFormat.png
        /// Only applies to lossy formats. 0.9 is visually indistinguishable
        /// from lossless for UI screenshots at a fraction of the size.
        static let imageQuality = 0.9
        static let showsCursorInCaptures = false
        /// 0 = retention off. Deliberately the default: this deletes files.
        static let retentionDays = 0
        static let uploadTimeoutSeconds = 30.0
        static let uploadRetryCount = 2
        static let showPreviewAfterCapture = true
        static let copyAfterCapture = true
        static let saveAfterCapture = true
        static let previewPosition = NotificationPosition.bottom
        static let toastPosition = NotificationPosition.bottom
        static let previewAutoDismissSeconds = 4.5
        static let toastAutoDismissSeconds = 2.2
        static let showTextPreviewInToast = true
        /// The transcript is most of the point of Copy for AI — an image
        /// alone is what the ordinary copy action already gives you.
        static let copyForAIIncludesText = true
        /// Off until the user asks for it. Nothing runs a model behind their
        /// back, even an on-device one.
        static let aiEnabled = false
        /// On, unlike the AI toggle above. Indexing is local OCR over a file
        /// QuickSnap just wrote, kept in a local database — nothing leaves
        /// the machine and nothing is deleted, and a save folder you can't
        /// search is the problem this exists to fix.
        static let captureIndexingEnabled = true
        /// Off by default: it opens a socket that can screenshot the user's
        /// display, which nobody should get without asking for it.
        static let mcpEnabled = false
        /// Unassigned by IANA and not in common use, so it rarely collides.
        static let mcpPort = 8787
        static let windowBackgroundStyle = WindowBackgroundStyle.transparent
        /// Points; multiplied by the screen's backing scale at render time.
        static let windowBackgroundPadding = 40.0
        static let windowBackgroundColor = "#F2F2F7"
        /// System red — matches the pre-setting hardcoded markup color.
        static let markupDefaultColor = "#FF3B30"
        /// Middle step of the five per-image stroke presets.
        static let markupDefaultStrokeStep = 2
        static let markupShowsCopyButton = true
        static let markupShowsSaveButton = true
        static let markupShowsSaveAsButton = false
        static let markupShowsDragButton = false
        static let markupShowsUploadButton = false
        static let markupShowsRedactionButton = true
        /// On: saving is the end of the edit, and the toast already confirms
        /// it, so leaving the window up makes the user close it by hand every
        /// time. Save As… counts too — same finishing move, different file.
        static let markupClosesAfterSave = true
        /// False until the flow has been through to the end (or skipped),
        /// which is what makes it a *first-run* flow rather than something
        /// that reappears.
        static let hasCompletedOnboarding = false
        /// On: the preview is a picture of the capture, and double-clicking a
        /// picture to open it is what every other app on the machine does.
        static let previewDoubleClickOpensMarkup = true
        static let uploadingEnabled = false
        static let uploadProvider = UploadProvider.immich
        static let uploadAfterCapture = false
        /// Off by default: for Immich this mints a *public* shared link, and
        /// for S3 it assumes the bucket is world-readable — neither should
        /// happen without the user asking.
        static let uploadCopiesLink = false
        static let uploadShowsPreviewButton = true
        /// On by default, unlike most things that run analysis: this is
        /// local OCR plus regexes, and the failure it prevents — a
        /// credential in a public URL — has no undo. Auto-upload is the
        /// feature people don't switch on because of exactly this risk.
        static let checkUploadsForSensitiveContent = true
        static let immichServerURL = ""
        /// Empty = upload to the library without filing it into an album.
        static let immichAlbumID = ""
        static let immichAlbumName = ""
        static let s3Endpoint = ""
        /// R2 and most MinIO deployments ignore the region but require a
        /// syntactically valid one; `us-east-1` is the safe universal value.
        static let s3Region = "us-east-1"
        static let s3Bucket = ""
        static let s3AccessKeyID = ""
        static let s3KeyPrefix = "screenshots/"
        static let s3PublicBaseURL = ""
        /// Path-style (`endpoint/bucket/key`) is what self-hosted MinIO
        /// needs and what R2/B2 accept; AWS proper prefers virtual-hosted.
        static let s3UsesPathStyle = true
        static let s3PublicRead = false
    }

    /// Number of steps on the markup stroke ladder — settings stores a step
    /// index (0…count-1) because absolute widths are per-image (they scale
    /// with the capture; see `MarkupCanvasController.strokeWidthPresets`).
    static let markupStrokeStepCount = 5

    static var defaultSaveFolder: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("QuickSnap", isDirectory: true)
    }

    /// The folder screenshots are saved to: the user-chosen folder if one is
    /// set (and still exists), otherwise `defaultSaveFolder`.
    static var saveFolder: URL {
        guard let path = UserDefaults.standard.string(forKey: Keys.saveFolderPath), !path.isEmpty else {
            return defaultSaveFolder
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return defaultSaveFolder
        }
        return url
    }

    // MARK: - Files and capture

    static var filenameTemplate: String {
        string(forKey: Keys.filenameTemplate) ?? Defaults.filenameTemplate
    }

    /// Returns the current counter and advances it. Stored rather than
    /// derived so `{counter}` keeps climbing across launches.
    static func nextFilenameCounter() -> Int {
        let next = UserDefaults.standard.integer(forKey: Keys.filenameCounter) + 1
        UserDefaults.standard.set(next, forKey: Keys.filenameCounter)
        return next
    }

    static var imageFormat: ImageFormat {
        let raw = UserDefaults.standard.string(forKey: Keys.imageFormat) ?? ""
        return ImageFormat(rawValue: raw) ?? Defaults.imageFormat
    }

    /// 0…1, only meaningful for lossy formats.
    static var imageQuality: Double {
        let value = double(forKey: Keys.imageQuality, default: Defaults.imageQuality)
        return min(max(value, 0.1), 1)
    }

    static var showsCursorInCaptures: Bool {
        bool(forKey: Keys.showsCursorInCaptures, default: Defaults.showsCursorInCaptures)
    }

    /// Days before a saved capture is cleaned up; 0 = keep forever. Only
    /// ever applies to files QuickSnap tagged — see `SaveFolderCleaner`.
    static var retentionDays: Int {
        let stored = UserDefaults.standard.object(forKey: Keys.retentionDays) as? Int
        return max(stored ?? Defaults.retentionDays, 0)
    }

    static var showsPreviewAfterCapture: Bool {
        bool(forKey: Keys.showPreviewAfterCapture, default: Defaults.showPreviewAfterCapture)
    }

    static var copiesAfterCapture: Bool {
        bool(forKey: Keys.copyAfterCapture, default: Defaults.copyAfterCapture)
    }

    static var savesAfterCapture: Bool {
        bool(forKey: Keys.saveAfterCapture, default: Defaults.saveAfterCapture)
    }

    /// The preview is always a panel of ours, so the toast-only
    /// `.notificationCenter` resolves to the bottom edge.
    static var previewPosition: NotificationPosition {
        let stored = position(forKey: Keys.previewPosition, default: Defaults.previewPosition)
        return stored == .notificationCenter ? .bottom : stored
    }

    /// The toast has no capture region to center on, so `.dynamic` — which
    /// its picker doesn't offer, but a migrated legacy value could carry —
    /// resolves to the bottom edge.
    static var toastPosition: NotificationPosition {
        let stored = position(forKey: Keys.toastPosition, default: Defaults.toastPosition)
        return stored == .dynamic ? .bottom : stored
    }

    private static func position(forKey key: String, default fallback: NotificationPosition) -> NotificationPosition {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return NotificationPosition(rawValue: raw) ?? fallback
    }

    /// Carries settings forward across key renames, so an existing choice
    /// isn't silently reset. Called once at launch, before anything reads
    /// the new keys. A migration can be dropped once no install can still
    /// be carrying the old key.
    ///
    /// - `notificationPosition` → `previewPosition` + `toastPosition`
    ///   (2026-08, when the preview gained `.dynamic` and the two panels
    ///   stopped sharing one setting).
    /// - the five `markupShows*Button` flags → `markupToolbarLayout`
    ///   (2026-08, when the toolbar became reorderable).
    static func migrateLegacySettings() {
        migrateNotificationPosition()
        migrateMarkupToolbarLayout()
    }

    private static func migrateNotificationPosition() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.string(forKey: Keys.legacyNotificationPosition) else { return }
        for key in [Keys.previewPosition, Keys.toastPosition] where defaults.string(forKey: key) == nil {
            defaults.set(legacy, forKey: key)
        }
        defaults.removeObject(forKey: Keys.legacyNotificationPosition)
    }

    /// Only runs for someone who actually changed a button's visibility —
    /// an untouched install has nothing to carry forward and should follow
    /// the default layout, including any items added to it later.
    private static func migrateMarkupToolbarLayout() {
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: Keys.markupToolbarLayout) == nil else { return }

        let legacyKeys = [
            Keys.markupShowsCopyButton, Keys.markupShowsSaveButton,
            Keys.markupShowsSaveAsButton, Keys.markupShowsDragButton,
            Keys.markupShowsUploadButton, Keys.markupShowsRedactionButton,
            Keys.markupToolbarLayout,
        ]
        guard legacyKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }

        let layout = MarkupToolbarLayout.migrating(
            showsCopy: bool(forKey: Keys.markupShowsCopyButton, default: Defaults.markupShowsCopyButton),
            showsSave: bool(forKey: Keys.markupShowsSaveButton, default: Defaults.markupShowsSaveButton),
            showsSaveAs: bool(forKey: Keys.markupShowsSaveAsButton, default: Defaults.markupShowsSaveAsButton),
            showsDragOut: bool(forKey: Keys.markupShowsDragButton, default: Defaults.markupShowsDragButton),
            showsUpload: bool(forKey: Keys.markupShowsUploadButton, default: Defaults.markupShowsUploadButton),
            showsRedact: bool(forKey: Keys.markupShowsRedactionButton, default: Defaults.markupShowsRedactionButton)
        )
        defaults.set(layout.encoded(), forKey: Keys.markupToolbarLayout)
        for key in legacyKeys {
            defaults.removeObject(forKey: key)
        }
    }

    /// Slider maximum for the preview duration; at this value the preview
    /// never auto-dismisses (`previewAutoDismissSeconds` returns nil).
    static let previewAutoDismissNeverThreshold = 15.0

    /// Nil means never auto-dismiss.
    static var previewAutoDismissSeconds: TimeInterval? {
        let value = double(forKey: Keys.previewAutoDismissSeconds, default: Defaults.previewAutoDismissSeconds)
        return value >= previewAutoDismissNeverThreshold ? nil : value
    }

    static var toastAutoDismissSeconds: TimeInterval {
        double(forKey: Keys.toastAutoDismissSeconds, default: Defaults.toastAutoDismissSeconds)
    }

    static var showsTextPreviewInToast: Bool {
        bool(forKey: Keys.showTextPreviewInToast, default: Defaults.showTextPreviewInToast)
    }

    /// Whether Copy for AI includes the capture's recognized text alongside
    /// the image and its source app.
    static var copyForAIIncludesText: Bool {
        bool(forKey: Keys.copyForAIIncludesText, default: Defaults.copyForAIIncludesText)
    }

    static var windowBackgroundStyle: WindowBackgroundStyle {
        let raw = UserDefaults.standard.string(forKey: Keys.windowBackgroundStyle) ?? ""
        return WindowBackgroundStyle(rawValue: raw) ?? Defaults.windowBackgroundStyle
    }

    /// Padding around a styled window capture, in points.
    static var windowBackgroundPadding: CGFloat {
        let stored = UserDefaults.standard.object(forKey: Keys.windowBackgroundPadding) as? Double
        return CGFloat(stored ?? Defaults.windowBackgroundPadding)
    }

    static var windowBackgroundColor: NSColor {
        let hex = UserDefaults.standard.string(forKey: Keys.windowBackgroundColor) ?? ""
        return NSColor(hexString: hex) ?? NSColor(hexString: Defaults.windowBackgroundColor)!
    }

    /// What the markup toolbar contains, in order. Absent means never
    /// customised, which is the default arrangement — not an empty toolbar,
    /// which is a legitimate (if odd) choice someone can make.
    static var markupToolbarLayout: MarkupToolbarLayout {
        guard let data = UserDefaults.standard.data(forKey: Keys.markupToolbarLayout) else {
            return .default
        }
        return MarkupToolbarLayout.decode(data) ?? .default
    }

    /// Initial markup color for new annotation windows.
    static var markupDefaultColor: NSColor {
        let hex = UserDefaults.standard.string(forKey: Keys.markupDefaultColor) ?? ""
        return NSColor(hexString: hex) ?? NSColor(hexString: Defaults.markupDefaultColor)!
    }

    /// Initial stroke step (0…`markupStrokeStepCount`-1) for new annotation
    /// windows, clamped in case a stale value is stored.
    static var markupDefaultStrokeStep: Int {
        let stored = UserDefaults.standard.object(forKey: Keys.markupDefaultStrokeStep) as? Int
        return min(max(stored ?? Defaults.markupDefaultStrokeStep, 0), markupStrokeStepCount - 1)
    }

    /// Whether the first-run flow has been completed or skipped. Cleared by
    /// `resetAll`, so "Reset All Settings" genuinely returns the app to how it
    /// arrived — including the setup it walked you through.
    static var hasCompletedOnboarding: Bool {
        get { bool(forKey: Keys.hasCompletedOnboarding, default: Defaults.hasCompletedOnboarding) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.hasCompletedOnboarding) }
    }

    /// Whether double-clicking the post-capture preview opens it for markup.
    /// Read at the moment of the click, so a change applies to a panel that's
    /// already on screen.
    static var previewDoubleClickOpensMarkup: Bool {
        bool(forKey: Keys.previewDoubleClickOpensMarkup, default: Defaults.previewDoubleClickOpensMarkup)
    }

    /// Whether an annotation window closes itself once a save has actually
    /// landed on disk. Read at save time, so a change applies to windows that
    /// are already open.
    static var markupClosesAfterSave: Bool {
        bool(forKey: Keys.markupClosesAfterSave, default: Defaults.markupClosesAfterSave)
    }

    // MARK: - Uploading

    static var uploadProvider: UploadProvider {
        let raw = UserDefaults.standard.string(forKey: Keys.uploadProvider) ?? ""
        return UploadProvider(rawValue: raw) ?? Defaults.uploadProvider
    }

    /// The configured upload target, or nil when uploading is switched off
    /// or the selected provider is missing something it needs. This is the
    /// single place providers are constructed from settings — everything
    /// else works through the `UploadDestination` protocol.
    static var uploadDestination: (any UploadDestination)? {
        guard bool(forKey: Keys.uploadingEnabled, default: Defaults.uploadingEnabled) else { return nil }

        switch uploadProvider {
        case .immich:
            guard let credentials = immichCredentials else { return nil }
            return ImmichDestination(
                credentials: credentials,
                albumID: string(forKey: Keys.immichAlbumID),
                albumName: string(forKey: Keys.immichAlbumName),
                createsSharedLink: uploadCopiesLink
            )

        case .s3:
            guard let configuration = s3Configuration else { return nil }
            return S3Destination(configuration: configuration, copiesLink: uploadCopiesLink)
        }
    }

    /// Credentials for the configured Immich instance. The API key lives in
    /// the Keychain (`KeychainStore`), not UserDefaults — only the server
    /// address is a plain default.
    static var immichCredentials: ImmichCredentials? {
        guard let serverURL = ImmichClient.normalizedServerURL(
                  from: UserDefaults.standard.string(forKey: Keys.immichServerURL) ?? ""
              ),
              let apiKey = KeychainStore.string(for: KeychainStore.Account.immichAPIKey)
        else {
            return nil
        }
        return ImmichCredentials(serverURL: serverURL, apiKey: apiKey)
    }

    /// Everything the S3 destination needs; nil when a required field is
    /// blank or the endpoint isn't a usable URL.
    static var s3Configuration: S3Configuration? {
        guard let endpoint = S3Destination.normalizedEndpoint(
                  from: UserDefaults.standard.string(forKey: Keys.s3Endpoint) ?? ""
              ),
              let bucket = string(forKey: Keys.s3Bucket),
              let accessKeyID = string(forKey: Keys.s3AccessKeyID),
              let secretAccessKey = KeychainStore.string(for: KeychainStore.Account.s3SecretKey)
        else {
            return nil
        }
        return S3Configuration(
            endpoint: endpoint,
            region: string(forKey: Keys.s3Region) ?? Defaults.s3Region,
            bucket: bucket,
            accessKeyID: accessKeyID,
            secretAccessKey: secretAccessKey,
            keyPrefix: string(forKey: Keys.s3KeyPrefix) ?? "",
            publicBaseURL: string(forKey: Keys.s3PublicBaseURL),
            usesPathStyle: bool(forKey: Keys.s3UsesPathStyle, default: Defaults.s3UsesPathStyle),
            isPublicRead: bool(forKey: Keys.s3PublicRead, default: Defaults.s3PublicRead)
        )
    }

    static var uploadsAfterCapture: Bool {
        bool(forKey: Keys.uploadAfterCapture, default: Defaults.uploadAfterCapture)
    }

    /// Whether a successful upload should put a link on the clipboard —
    /// which for Immich means minting a public shared link, and for S3
    /// means the object URL.
    static var uploadCopiesLink: Bool {
        bool(forKey: Keys.uploadCopiesLink, default: Defaults.uploadCopiesLink)
    }

    /// Whether the post-capture preview panel offers an upload button. Only
    /// consulted when `uploadDestination` is non-nil.
    static var uploadShowsPreviewButton: Bool {
        bool(forKey: Keys.uploadShowsPreviewButton, default: Defaults.uploadShowsPreviewButton)
    }

    /// Whether captures are scanned for credentials before they're
    /// uploaded, holding the upload when something turns up. See
    /// `SensitiveContentDetector`.
    static var checksUploadsForSensitiveContent: Bool {
        bool(forKey: Keys.checkUploadsForSensitiveContent, default: Defaults.checkUploadsForSensitiveContent)
    }

    /// Per-request timeout for upload providers, in seconds.
    static var uploadTimeoutSeconds: TimeInterval {
        let value = double(forKey: Keys.uploadTimeoutSeconds, default: Defaults.uploadTimeoutSeconds)
        return min(max(value, 5), 300)
    }

    /// Extra attempts after a failure (0 = try once, don't retry). Only
    /// transient failures are retried — see `UploadCoordinator`.
    static var uploadRetryCount: Int {
        let stored = UserDefaults.standard.object(forKey: Keys.uploadRetryCount) as? Int
        return min(max(stored ?? Defaults.uploadRetryCount, 0), 5)
    }

    // MARK: - Intelligence

    /// The configured AI provider, or nil when the user hasn't switched
    /// intelligence features on. Availability is *not* checked here — a
    /// provider whose model is unavailable still answers `availability`, and
    /// callers need that distinction to explain themselves.
    ///
    /// The single place providers are constructed from settings, same as
    /// `uploadDestination`. There's one conformer today, so there's no
    /// provider picker; a second one adds a `Keys.aiProvider` enum and a
    /// branch here, and nothing upstream changes.
    static var aiProvider: (any AIProvider)? {
        guard isAIEnabled else { return nil }
        return FoundationModelsProvider()
    }

    static var isAIEnabled: Bool {
        bool(forKey: Keys.aiEnabled, default: Defaults.aiEnabled)
    }

    /// Whether saved captures are indexed for search (`CaptureIndex`).
    static var isCaptureIndexingEnabled: Bool {
        bool(forKey: Keys.captureIndexingEnabled, default: Defaults.captureIndexingEnabled)
    }

    // MARK: - MCP server

    static var isMCPServerEnabled: Bool {
        bool(forKey: Keys.mcpEnabled, default: Defaults.mcpEnabled)
    }

    /// Loopback port for the MCP endpoint. Clamped above the privileged range
    /// so a stored nonsense value can't make the listener fail silently.
    static var mcpServerPort: UInt16 {
        let stored = UserDefaults.standard.object(forKey: Keys.mcpPort) as? Int
        return UInt16(min(max(stored ?? Defaults.mcpPort, 1024), 65_535))
    }

    /// The bearer token MCP clients must present, generated on first use and
    /// kept in the Keychain — never in UserDefaults, since anything running
    /// as the user can read a defaults plist, and this token authorises
    /// screenshots.
    ///
    /// Returns nil only if the Keychain write fails, which leaves the server
    /// rejecting every request rather than accepting unauthenticated ones.
    @discardableResult
    static func mcpAuthToken() -> String? {
        if let existing = KeychainStore.string(for: KeychainStore.Account.mcpAuthToken) {
            return existing
        }
        return regenerateMCPAuthToken()
    }

    @discardableResult
    static func regenerateMCPAuthToken() -> String? {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let token = Data(bytes).base64EncodedString()
        do {
            try KeychainStore.setString(token, for: KeychainStore.Account.mcpAuthToken)
            return token
        } catch {
            return nil
        }
    }

    // MARK: - Reset

    /// Clears every stored setting and both Keychain secrets — the Advanced
    /// page's "Reset All Settings". Enumerated explicitly rather than wiping
    /// the whole domain so nothing outside our own keys is touched.
    static func resetAll() {
        let keys = [
            Keys.saveFolderPath, Keys.filenameTemplate, Keys.filenameCounter,
            Keys.imageFormat, Keys.imageQuality, Keys.showsCursorInCaptures,
            Keys.retentionDays, Keys.uploadTimeoutSeconds, Keys.uploadRetryCount,
            Keys.showPreviewAfterCapture, Keys.copyAfterCapture, Keys.saveAfterCapture,
            Keys.previewPosition, Keys.toastPosition, Keys.previewAutoDismissSeconds,
            Keys.toastAutoDismissSeconds, Keys.showTextPreviewInToast,
            Keys.copyForAIIncludesText, Keys.aiEnabled,
            Keys.captureIndexingEnabled,
            Keys.mcpEnabled, Keys.mcpPort,
            Keys.windowBackgroundStyle, Keys.windowBackgroundPadding, Keys.windowBackgroundColor,
            Keys.markupDefaultColor, Keys.markupDefaultStrokeStep,
            Keys.markupShowsCopyButton, Keys.markupShowsSaveButton,
            Keys.markupShowsSaveAsButton, Keys.markupShowsDragButton,
            Keys.markupShowsUploadButton, Keys.markupShowsRedactionButton,
            Keys.markupToolbarLayout, Keys.markupClosesAfterSave,
            Keys.hasCompletedOnboarding, Keys.previewDoubleClickOpensMarkup,
            Keys.uploadingEnabled, Keys.uploadProvider, Keys.uploadAfterCapture,
            Keys.uploadCopiesLink, Keys.uploadShowsPreviewButton,
            Keys.checkUploadsForSensitiveContent,
            Keys.immichServerURL, Keys.immichAlbumID, Keys.immichAlbumName,
            Keys.s3Endpoint, Keys.s3Region, Keys.s3Bucket, Keys.s3AccessKeyID,
            Keys.s3KeyPrefix, Keys.s3PublicBaseURL, Keys.s3UsesPathStyle, Keys.s3PublicRead,
        ] + HotkeyAction.allCases.map(Keys.hotkey(for:))

        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try? KeychainStore.remove(KeychainStore.Account.immichAPIKey)
        try? KeychainStore.remove(KeychainStore.Account.s3SecretKey)
        try? KeychainStore.remove(KeychainStore.Account.mcpAuthToken)
    }

    /// Current shortcut for `action`, nil when explicitly cleared. The
    /// defaults come through `registerDefaultHotkeys`, so an absent key
    /// resolves to the action's default automatically.
    static func hotkey(for action: HotkeyAction) -> HotkeyShortcut? {
        guard let data = UserDefaults.standard.data(forKey: Keys.hotkey(for: action)) else {
            return action.defaultShortcut
        }
        return HotkeyShortcut.decode(data)
    }

    /// Registers each action's default shortcut with UserDefaults — call
    /// once at launch. Registered (not written) so "never touched" follows
    /// the default, while an explicit clear stores empty Data and stays
    /// cleared. `@AppStorage` also resolves through registered defaults, so
    /// the settings UI sees the same values.
    static func registerDefaultHotkeys() {
        var defaults: [String: Any] = [:]
        for action in HotkeyAction.allCases {
            defaults[Keys.hotkey(for: action)] = action.defaultShortcut.encoded
        }
        UserDefaults.standard.register(defaults: defaults)
    }

    private static func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? defaultValue
    }

    /// A stored string, treating empty as absent — which is how every
    /// optional text setting here reads ("no album", "no CDN domain").
    private static func string(forKey key: String) -> String? {
        let value = UserDefaults.standard.string(forKey: key) ?? ""
        return value.isEmpty ? nil : value
    }

    private static func double(forKey key: String, default defaultValue: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? defaultValue
    }
}


// MARK: - Hex color storage

/// `#RRGGBB` round-tripping for storing the solid background color in
/// UserDefaults — shared by `AppSettings` and the settings UI's ColorPicker
/// binding. `nonisolated` so the nonisolated `AppSettings` accessor can use
/// it (NSColor itself is immutable and thread-safe).
nonisolated extension NSColor {
    convenience init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    var hexString: String {
        let srgb = usingColorSpace(.sRGB) ?? self
        let red = Int(round(srgb.redComponent * 255))
        let green = Int(round(srgb.greenComponent * 255))
        let blue = Int(round(srgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
