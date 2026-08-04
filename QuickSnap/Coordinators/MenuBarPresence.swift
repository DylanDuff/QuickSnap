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
    static let iconPointSize: CGFloat = 17.5

    /// The item's icon — and the very same image the onboarding flight
    /// carries, so the two can't drift apart in size or weight and the
    /// hand-off has nothing to give away.
    static func iconImage() -> NSImage {
        guard
            let symbol = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "QuickSnap")?
                .withSymbolConfiguration(.init(pointSize: iconPointSize, weight: .regular))
        else { return NSImage() }

        let image = trimmingTransparentSides(symbol) ?? symbol
        image.isTemplate = true
        return image
    }

    /// Crops the empty columns either side of the glyph.
    ///
    /// An SF Symbol image is laid out on the symbol's *design* width, which
    /// for this one leaves a margin of transparent pixels on each side. The
    /// menu bar item sizes itself to the image it's given, so those margins
    /// show up as the icon sitting in too much space — more of it the larger
    /// the point size. Vertical extent is left alone: that's what keeps the
    /// glyph on the menu bar's baseline.
    ///
    /// Returns nil rather than guessing if anything about the bitmap isn't
    /// what's expected; the caller falls back to the untrimmed image.
    private static func trimmingTransparentSides(_ image: NSImage) -> NSImage? {
        let size = image.size
        guard size.width > 1, size.height > 1 else { return nil }

        // Drawn into a context of our own making, so the byte layout is
        // known rather than whatever the symbol happens to arrive in.
        let width = Int(size.width.rounded(.up))
        let height = Int(size.height.rounded(.up))
        guard
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data else { return nil }
        let bytes = pixels.bindMemory(to: UInt8.self, capacity: width * height * 4)

        var firstColumn: Int?
        var lastColumn: Int?
        for x in 0..<width {
            var isEmpty = true
            for y in 0..<height where bytes[(y * width + x) * 4 + 3] > 8 {
                isEmpty = false
                break
            }
            if !isEmpty {
                firstColumn = firstColumn ?? x
                lastColumn = x
            }
        }

        guard let first = firstColumn, let last = lastColumn, last >= first else { return nil }
        let trimmedWidth = CGFloat(last - first + 1)
        guard trimmedWidth < size.width else { return nil }

        let trimmed = NSImage(size: NSSize(width: trimmedWidth, height: size.height))
        trimmed.lockFocus()
        image.draw(
            in: NSRect(x: -CGFloat(first), y: 0, width: size.width, height: size.height),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        trimmed.unlockFocus()
        return trimmed
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
