//
//  MenuBarFlightController.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Flies the menu bar icon out of the onboarding window and up into the menu
/// bar, then hands over to the real item.
///
/// The icon has to travel outside the window it starts in, so it can't be
/// drawn by that window's content: this is a borderless, non-activating,
/// click-through panel — the same pattern as the toast and preview panels —
/// carrying a single image from one screen rectangle to another.
///
/// The illusion only works if the real item is hidden until the flight lands
/// (`MenuBarPresence`), so `completion` is what reveals it and **must** run
/// on every path out of here, including the ones that give up early.
@MainActor
final class MenuBarFlightController {
    static let shared = MenuBarFlightController()

    private var panel: NSPanel?

    private init() {}

    /// `source` is in screen coordinates. `completion` reveals the real item.
    func fly(from source: NSRect, completion: @escaping () -> Void) {
        // Reduce Motion: no flight at all, the item simply appears. Flying an
        // icon across the screen is the one thing this feature *is*, so
        // there's no reduced version of it worth showing.
        guard !Motion.reduceMotion else { return completion() }

        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(source) }) ?? NSScreen.main else {
            return completion()
        }
        let slot = MenuBarPresence.shared.iconFrame ?? Self.fallbackTarget(on: screen)
        let target = Self.landingRect(in: slot)

        let panel = NSPanel(
            contentRect: source,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // Above the onboarding window and everything else on the way up,
        // so the icon passes over rather than behind.
        panel.level = .statusBar
        panel.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]

        let icon = NSImageView()
        icon.image = MenuBarPresence.iconImage()
        icon.contentTintColor = .labelColor
        // Proportional, never `.scaleAxesIndependently`: the image isn't the
        // same aspect as the rect it lands in, so filling it stretches the
        // glyph for the whole flight. Fitting matches what the menu bar does
        // with the same image anyway — SwiftUI fits it into an 18 × 18
        // rendering, so fitting into the same rect lands on the same pixels.
        icon.imageScaling = .scaleProportionallyUpOrDown
        panel.contentView = icon
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        // Fade in where the label's icon was, so it reads as that icon
        // lifting off rather than a new one appearing.
        NSAnimationContext.animate(.easeOut(duration: 0.12)) {
            panel.animator().alphaValue = 1
        } completion: { [weak self] in
            self?.travel(panel, to: target, completion: completion)
        }
    }

    private func travel(_ panel: NSPanel, to target: NSRect, completion: @escaping () -> Void) {
        NSAnimationContext.animate(Motion.panelSpring) {
            panel.animator().setFrame(target, display: true)
        } completion: { [weak self] in
            // The real item appears in the same turn the flown icon goes, so
            // there's never two of them or none of them.
            completion()
            panel.orderOut(nil)
            panel.close()
            self?.panel = nil
        }
    }

    /// Where the flown icon comes to rest: exactly the rect the menu bar
    /// draws its icon in, which `MenuBarPresence.iconFrame` measures rather
    /// than derives. Earlier versions centred a guessed size in the item's
    /// window and then in its button, and both left the icon a point or two
    /// off — enough to see it jump as the real one took over.
    ///
    /// Deliberately **not** `.integral`: that returns the smallest integral
    /// rect *containing* the original, so it grows the frame by up to a point
    /// and drags the origin down and left with it — which is precisely the
    /// slight shift you could see as the flown icon handed over. Rounding to
    /// half points lands on whole pixels on a Retina display without
    /// changing the size.
    private static func landingRect(in slot: NSRect) -> NSRect {
        NSRect(
            x: roundedToHalf(slot.minX),
            y: roundedToHalf(slot.minY),
            width: slot.width,
            height: slot.height
        )
    }

    private static func roundedToHalf(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    /// Used when the status item's window can't be found: the trailing end of
    /// the menu bar, which is where it sits on an uncluttered Mac.
    private static func fallbackTarget(on screen: NSScreen) -> NSRect {
        let thickness = NSStatusBar.system.thickness
        return NSRect(
            x: screen.frame.maxX - 140,
            y: screen.frame.maxY - thickness,
            width: thickness,
            height: thickness
        )
    }
}
