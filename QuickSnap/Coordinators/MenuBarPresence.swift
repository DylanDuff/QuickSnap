//
//  MenuBarPresence.swift
//  QuickSnap
//

import AppKit
import Combine
import SwiftUI

/// Whether the menu bar item draws its icon, and where that item is on
/// screen.
///
/// The item is **always inserted**, even while hidden. Two reasons: an
/// inserted item is what reserves its slot, so nothing shuffles sideways
/// when the icon comes back; and its window is the only way to find out
/// where it actually sits — there's no API to ask a `MenuBarExtra` for its
/// frame, and the position depends on how many other items the user has.
/// Hiding is therefore "draw a blank label", not "remove the item".
///
/// A singleton because the `App` scene and the onboarding flow both need it
/// and neither owns the other.
@MainActor
final class MenuBarPresence: nonisolated ObservableObject {
    static let shared = MenuBarPresence()

    /// False only while the onboarding flow is flying the icon up there.
    /// In-memory and defaulting to true, so a crash or a quit mid-flight
    /// can't leave someone with a menu bar app they can't see.
    @Published var showsIcon = true

    private init() {}

    /// Point size the item's symbol is drawn at. A touch larger than the
    /// system default, which rendered small enough that the icon arriving
    /// from onboarding had to shrink to meet it.
    static let iconPointSize: CGFloat = 18

    /// The item's icon — and the very same image the onboarding flight
    /// carries, so the two can't drift apart in size or weight and the
    /// hand-off has nothing to give away.
    static func iconImage() -> NSImage {
        let image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "QuickSnap")?
            .withSymbolConfiguration(.init(pointSize: iconPointSize, weight: .regular))
        image?.isTemplate = true
        return image ?? NSImage()
    }

    /// Where the item is, in screen coordinates.
    ///
    /// Found by enumerating the app's own windows for the status bar one.
    /// That's an observation rather than a contract — hence the optional,
    /// and the caller's fallback — but it uses no private API, and it's the
    /// difference between the icon landing on the real thing and landing in
    /// empty space on a busy menu bar.
    var iconFrame: NSRect? {
        NSApp.windows.first { window in
            let name = String(describing: type(of: window))
            return name.contains("StatusBar") || name.contains("MenuBarExtra")
        }?.frame
    }
}
