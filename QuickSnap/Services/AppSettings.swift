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
    }

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
