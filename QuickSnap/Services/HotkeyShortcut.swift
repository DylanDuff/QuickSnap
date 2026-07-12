//
//  HotkeyShortcut.swift
//  QuickSnap
//

import AppKit
import Carbon.HIToolbox

/// The app actions a global hotkey can trigger.
nonisolated enum HotkeyAction: String, CaseIterable {
    case captureArea
    case captureWindow
    case captureFullScreen
    case captureText

    var displayName: String {
        switch self {
        case .captureArea: return "Capture Area"
        case .captureWindow: return "Capture Window"
        case .captureFullScreen: return "Capture Full Screen"
        case .captureText: return "Capture Text (OCR)"
        }
    }

    var defaultShortcut: HotkeyShortcut {
        switch self {
        case .captureArea:
            return HotkeyShortcut(keyCode: UInt32(kVK_ANSI_7), modifiers: [.command, .shift], keyLabel: "7")
        case .captureWindow:
            return HotkeyShortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: [.command, .shift], keyLabel: "8")
        case .captureFullScreen:
            return HotkeyShortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: [.command, .shift], keyLabel: "9")
        case .captureText:
            return HotkeyShortcut(keyCode: UInt32(kVK_ANSI_0), modifiers: [.command, .shift], keyLabel: "0")
        }
    }
}

/// A recorded global keyboard shortcut. `keyCode` + modifiers drive the
/// Carbon registration; `keyLabel` is the human-readable key captured at
/// record time (deriving it from a key code needs the live keyboard layout,
/// so it's stored instead).
nonisolated struct HotkeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags.rawValue`, already masked to ⌘⇧⌥⌃.
    var modifiersRaw: UInt
    var keyLabel: String

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiersRaw = modifiers.intersection(Self.allowedModifiers).rawValue
        self.keyLabel = keyLabel
    }

    /// Builds a shortcut from a keyDown event, or nil if the combination
    /// isn't usable as a global hotkey: it must be a function-row/navigation
    /// key, or a printable key combined with at least one of ⌘⌥⌃ (shift
    /// alone would swallow ordinary typing).
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(Self.allowedModifiers)
        let keyCode = UInt32(event.keyCode)

        let label: String
        if let special = Self.specialKeyLabels[keyCode] {
            label = special
        } else if let characters = event.characters(byApplyingModifiers: []), !characters.isEmpty,
                  let scalar = characters.unicodeScalars.first, !CharacterSet.controlCharacters.contains(scalar) {
            label = characters.uppercased()
        } else {
            return nil
        }

        let standsAlone = Self.standaloneKeyCodes.contains(keyCode)
        guard standsAlone || !modifiers.intersection([.command, .option, .control]).isEmpty else {
            return nil
        }

        self.init(keyCode: keyCode, modifiers: modifiers, keyLabel: label)
    }

    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifiersRaw)
    }

    /// E.g. "⌃⌥⇧⌘7" — standard macOS modifier ordering.
    var displayString: String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols + keyLabel
    }

    var carbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }

    // MARK: - Persistence

    var encoded: Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Empty data decodes to nil — that's the stored representation of
    /// "explicitly cleared", distinct from an absent key (which falls back
    /// to the registered default).
    static func decode(_ data: Data) -> HotkeyShortcut? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(HotkeyShortcut.self, from: data)
    }

    // MARK: - Key metadata

    private static let allowedModifiers: NSEvent.ModifierFlags = [.command, .shift, .option, .control]

    /// Keys allowed as a hotkey without ⌘⌥⌃ (they don't collide with typing).
    private static let standaloneKeyCodes: Set<UInt32> = {
        var codes = Set(functionKeyLabels.keys)
        codes.formUnion([UInt32(kVK_Home), UInt32(kVK_End), UInt32(kVK_PageUp), UInt32(kVK_PageDown)])
        return codes
    }()

    private static let functionKeyLabels: [UInt32: String] = [
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    private static let specialKeyLabels: [UInt32: String] = {
        var labels = functionKeyLabels
        labels[UInt32(kVK_Space)] = "Space"
        labels[UInt32(kVK_Return)] = "↩"
        labels[UInt32(kVK_Tab)] = "⇥"
        labels[UInt32(kVK_LeftArrow)] = "←"
        labels[UInt32(kVK_RightArrow)] = "→"
        labels[UInt32(kVK_UpArrow)] = "↑"
        labels[UInt32(kVK_DownArrow)] = "↓"
        labels[UInt32(kVK_Home)] = "↖"
        labels[UInt32(kVK_End)] = "↘"
        labels[UInt32(kVK_PageUp)] = "⇞"
        labels[UInt32(kVK_PageDown)] = "⇟"
        labels[UInt32(kVK_ForwardDelete)] = "⌦"
        return labels
    }()
}
