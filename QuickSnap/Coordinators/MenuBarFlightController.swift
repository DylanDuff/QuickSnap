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

    /// Where the flown icon comes to rest: the drawn image's own size,
    /// centred in the item's slot.
    ///
    /// Not the slot itself — that's the status item's *window*, measured
    /// 34 × 33 pt around a much smaller glyph, and landing on it dropped an
    /// oversized icon on the menu bar. Taking the size from the same image
    /// the item draws means there's no scale factor to keep in step, and the
    /// rect is rounded to whole pixels so the two can't land half a point
    /// apart.
    private static func landingRect(in slot: NSRect) -> NSRect {
        let size = MenuBarPresence.iconImage().size
        return NSRect(
            x: slot.midX - size.width / 2,
            y: slot.midY - size.height / 2,
            width: size.width,
            height: size.height
        ).integral
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
