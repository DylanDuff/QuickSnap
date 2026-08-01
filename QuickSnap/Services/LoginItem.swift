//
//  LoginItem.swift
//  QuickSnap
//

import ServiceManagement

/// Launch-at-login, via `SMAppService`. The modern replacement for the
/// deprecated `SMLoginItemSetEnabled` / login-item helper-app dance — the
/// app registers *itself*, no helper bundle needed.
///
/// Registration state lives with the system, not in UserDefaults: the user
/// can revoke it in System Settings → General → Login Items, and the
/// settings toggle has to reflect that rather than a stale local copy. So
/// `isEnabled` reads `SMAppService.mainApp.status` every time.
///
/// `@MainActor` unlike the other Services: it's driven straight from a
/// SwiftUI toggle and does no blocking I/O worth moving off the main thread.
@MainActor
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// The user has denied it in System Settings — the toggle should say so
    /// rather than silently failing to turn on.
    static var isDeniedBySystem: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Returns whether the change took effect. Registration can throw (a
    /// non-notarized build in some locations, or an approval requirement),
    /// and silently swallowing that would leave the toggle lying.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    static func openSystemLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
