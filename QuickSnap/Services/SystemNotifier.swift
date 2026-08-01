//
//  SystemNotifier.swift
//  QuickSnap
//

import AppKit
import UserNotifications

/// Posts QuickSnap's confirmations to Notification Center, the alternative to
/// the in-app toast pill selected by `NotificationPosition.notificationCenter`.
/// `ToastController` is the only caller — it routes to here or to its own panel
/// so the rest of the app keeps calling one API.
///
/// Not a bare `enum` like the neighbouring Services because two things have to
/// live somewhere: `UNUserNotificationCenter` holds its delegate weakly (and
/// without a delegate macOS suppresses the banner whenever QuickSnap is
/// frontmost — which it is while an annotation window is open, so Save
/// confirmations would silently vanish), and the authorization answer is cached
/// so callers can decide without waiting on an async round trip.
@MainActor
final class SystemNotifier: NSObject {
    static let shared = SystemNotifier()

    /// Last known answer from `UNUserNotificationCenter`, refreshed by
    /// `refreshAuthorization()`. Starts pessimistic: a false negative just
    /// means one confirmation shows as a pill, while a false positive would
    /// drop it entirely.
    private(set) var isAuthorized = false

    private var hasRequestedAuthorization = false

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        refreshAuthorization()
    }

    /// Asks for permission the first time, and re-reads the status on every
    /// call after that (the user can change their mind in System Settings).
    /// Called when Notification Center is selected in Settings, so the system
    /// prompt appears next to the switch that caused it rather than mid-capture.
    func requestAuthorizationIfNeeded(completion: (@MainActor (Bool) -> Void)? = nil) {
        guard !hasRequestedAuthorization else {
            refreshAuthorization(completion: completion)
            return
        }
        hasRequestedAuthorization = true

        // Alerts only — QuickSnap has no capture sound, and a confirmation
        // that outlives the thing it confirms doesn't want a badge either.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in
                self.isAuthorized = granted
                completion?(granted)
            }
        }
    }

    func refreshAuthorization(completion: (@MainActor (Bool) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            // Read the status inside the callback rather than hopping with the
            // settings object, which isn't `Sendable`.
            let status = settings.authorizationStatus
            Task { @MainActor in
                self.isAuthorized = status == .authorized || status == .provisional
                completion?(self.isAuthorized)
            }
        }
    }

    /// Posts a confirmation. `delivered` is false when the notification didn't
    /// make it — most often because authorization was never granted — which is
    /// the caller's cue to fall back to the toast pill so the feedback isn't
    /// lost. Delivery is asynchronous, so the fallback lands a beat late; that
    /// only happens on a path the user has already opted out of.
    func post(title: String, body: String?, delivered: @escaping @MainActor (Bool) -> Void) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let body {
            content.body = body
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately.
        )

        UNUserNotificationCenter.current().add(request) { error in
            let succeeded = error == nil
            Task { @MainActor in
                if !succeeded {
                    self.isAuthorized = false
                }
                delivered(succeeded)
            }
        }
    }

    /// Opens the Notifications pane, for the Settings hint shown when
    /// permission is missing.
    static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension SystemNotifier: UNUserNotificationCenterDelegate {
    /// Without this, macOS hides the banner when QuickSnap itself is
    /// frontmost — which is exactly the case for a Save confirmation from an
    /// annotation window. Declared `nonisolated` because the delegate protocol
    /// carries no isolation of its own; it touches no state.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }
}
