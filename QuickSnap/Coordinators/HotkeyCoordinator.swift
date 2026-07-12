//
//  HotkeyCoordinator.swift
//  QuickSnap
//

import AppKit
import Carbon.HIToolbox

/// Owns the app's global hotkey registrations. Uses Carbon's
/// `RegisterEventHotKey` — the one supported system-wide hotkey API (the
/// same one hotkey libraries wrap): it works for accessory apps, needs no
/// Accessibility/Input Monitoring permission, and consumes the event so the
/// frontmost app never sees the keystroke.
///
/// Registrations follow the shortcuts stored in `AppSettings` and are
/// re-applied automatically whenever UserDefaults changes (cheap: compares
/// against the last-applied set first). Dispatch goes through `onAction`,
/// wired by `CaptureCoordinator`.
@MainActor
final class HotkeyCoordinator {
    var onAction: ((HotkeyAction) -> Void)?

    private var registeredHotkeys: [EventHotKeyRef] = []
    private var appliedShortcuts: [HotkeyAction: HotkeyShortcut?] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var defaultsObserver: NSObjectProtocol?

    /// `EventHotKeyID.id` → action; ids are the action's index in `allCases`.
    private static let actions = HotkeyAction.allCases

    private static let signature: FourCharCode = {
        var code: FourCharCode = 0
        for scalar in "QSnp".unicodeScalars {
            code = (code << 8) + FourCharCode(scalar.value)
        }
        return code
    }()

    func start() {
        installEventHandler()
        applyRegistrations()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue; hop is safe.
            MainActor.assumeIsolated {
                self?.applyRegistrations()
            }
        }
    }

    private func installEventHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )
    }

    /// C callback: Carbon delivers hotkey events on the main event loop.
    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr, let userData else { return noErr }

        let coordinator = Unmanaged<HotkeyCoordinator>.fromOpaque(userData).takeUnretainedValue()
        MainActor.assumeIsolated {
            coordinator.handleHotkey(id: hotKeyID.id)
        }
        return noErr
    }

    private func handleHotkey(id: UInt32) {
        guard Int(id) < Self.actions.count else { return }
        onAction?(Self.actions[Int(id)])
    }

    /// Syncs Carbon registrations with the stored shortcuts. Called on
    /// every UserDefaults change, so it exits early when nothing relevant
    /// changed.
    private func applyRegistrations() {
        let current = Dictionary(uniqueKeysWithValues: Self.actions.map { ($0, AppSettings.hotkey(for: $0)) })
        guard current != appliedShortcuts else { return }
        appliedShortcuts = current

        for hotkey in registeredHotkeys {
            UnregisterEventHotKey(hotkey)
        }
        registeredHotkeys.removeAll()

        for (index, action) in Self.actions.enumerated() {
            guard let shortcut = current[action], let shortcut else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                EventHotKeyID(signature: Self.signature, id: UInt32(index)),
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registeredHotkeys.append(ref)
            }
        }
    }
}
