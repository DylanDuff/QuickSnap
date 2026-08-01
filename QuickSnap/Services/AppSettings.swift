//
//  AppSettings.swift
//  QuickSnap
//

import AppKit

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

/// Which screen edge the transient panels (screenshot preview thumbnail,
/// toast) appear from. Horizontal placement is each panel's own affair
/// (preview: trailing corner, toast: centered); this only flips the edge
/// and the slide direction.
nonisolated enum NotificationPosition: String, CaseIterable {
    case bottom
    case top

    var displayName: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
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
        static let showPreviewAfterCapture = "showPreviewAfterCapture"
        static let copyAfterCapture = "copyAfterCapture"
        static let saveAfterCapture = "saveAfterCapture"
        static let notificationPosition = "notificationPosition"
        static let previewAutoDismissSeconds = "previewAutoDismissSeconds"
        static let toastAutoDismissSeconds = "toastAutoDismissSeconds"
        static let showTextPreviewInToast = "showTextPreviewInToast"
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
        // Uploading — provider-neutral settings…
        static let uploadingEnabled = "uploadingEnabled"
        static let uploadProvider = "uploadProvider"
        static let uploadAfterCapture = "uploadAfterCapture"
        static let uploadCopiesLink = "uploadCopiesLink"
        static let uploadShowsPreviewButton = "uploadShowsPreviewButton"
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
        static let showPreviewAfterCapture = true
        static let copyAfterCapture = true
        static let saveAfterCapture = true
        static let notificationPosition = NotificationPosition.bottom
        static let previewAutoDismissSeconds = 4.5
        static let toastAutoDismissSeconds = 2.2
        static let showTextPreviewInToast = true
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
        static let uploadingEnabled = false
        static let uploadProvider = UploadProvider.immich
        static let uploadAfterCapture = false
        /// Off by default: for Immich this mints a *public* shared link, and
        /// for S3 it assumes the bucket is world-readable — neither should
        /// happen without the user asking.
        static let uploadCopiesLink = false
        static let uploadShowsPreviewButton = true
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

    static var showsPreviewAfterCapture: Bool {
        bool(forKey: Keys.showPreviewAfterCapture, default: Defaults.showPreviewAfterCapture)
    }

    static var copiesAfterCapture: Bool {
        bool(forKey: Keys.copyAfterCapture, default: Defaults.copyAfterCapture)
    }

    static var savesAfterCapture: Bool {
        bool(forKey: Keys.saveAfterCapture, default: Defaults.saveAfterCapture)
    }

    static var notificationPosition: NotificationPosition {
        let raw = UserDefaults.standard.string(forKey: Keys.notificationPosition) ?? ""
        return NotificationPosition(rawValue: raw) ?? Defaults.notificationPosition
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
