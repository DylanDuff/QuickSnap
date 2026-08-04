//
//  OnboardingRenderProbe.swift
//  QuickSnap
//
//  TEMPORARY diagnostic harness — inert unless launched with
//  QUICKSNAP_ONBOARDING_RENDER=<directory>. Renders each onboarding step to a
//  PNG at the real window content size and writes it out, so the layout can be
//  *looked at* without a screen recording grant (a terminal-launched process
//  has none — TCC attributes it to the terminal, so `screencapture` fails).
//
//  `ImageRenderer` draws the view hierarchy directly, which is enough to catch
//  the things that actually go wrong here: content taller than the window,
//  clipped controls, a squeezed toolbar editor. Materials and vibrancy render
//  flat, so this says nothing about how it *looks* — only how it lays out.
//

import AppKit
import SwiftUI

@MainActor
enum OnboardingRenderProbe {
    static var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["QUICKSNAP_ONBOARDING_RENDER"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    static var isEnabled: Bool { outputDirectory != nil }

    /// Window content size, minus the footer the steps don't draw.
    private static let stepSize = CGSize(width: 620, height: 560)

    /// Opens the flow and leaves it open, for working on it: no first-run
    /// flag to clear, no clicking through Settings after every build.
    /// Closing the window doesn't quit — QuickSnap carries on in the menu
    /// bar, and Settings → General → Setup reopens it.
    static func openAndStayIfEnabled() {
        guard ProcessInfo.processInfo.environment["QUICKSNAP_ONBOARDING_OPEN"] == "1" else { return }
        OnboardingCoordinator.shared.show()
    }

    /// Opens the real window and reports what actually decided its size —
    /// the window's own frame, the constraints an `NSHostingView` may have
    /// pushed onto it, and what SwiftUI thinks the content wants.
    static func inspectWindowIfEnabled() {
        guard ProcessInfo.processInfo.environment["QUICKSNAP_ONBOARDING_WINDOW"] == "1" else { return }
        Task {
            OnboardingCoordinator.shared.show()
            try? await Task.sleep(for: .seconds(1.5))
            guard let window = NSApp.windows.first(where: { $0.title == "Welcome to QuickSnap" }) else {
                print("[onboarding-window] no window found")
                return NSApp.terminate(nil)
            }
            // Option 2's whole premise: can the status item's window be
            // found, and does its frame look like the menu bar?
            print("[onboarding-window] menu bar icon frame: \(MenuBarPresence.shared.iconFrame?.debugDescription ?? "NOT FOUND")")
            for candidate in NSApp.windows {
                print("[onboarding-window]   window: \(type(of: candidate)) frame=\(candidate.frame)")
            }

            let screen = window.screen ?? NSScreen.main
            print("[onboarding-window] frame=\(window.frame)")
            print("[onboarding-window] contentRect=\(window.contentRect(forFrameRect: window.frame))")
            print("[onboarding-window] contentMinSize=\(window.contentMinSize) contentMaxSize=\(window.contentMaxSize)")
            print("[onboarding-window] screen visibleFrame=\(screen?.visibleFrame ?? .zero)")
            if let hosting = window.contentView as? NSView {
                print("[onboarding-window] contentView=\(type(of: hosting)) bounds=\(hosting.bounds)")
                print("[onboarding-window] fittingSize=\(hosting.fittingSize) intrinsic=\(hosting.intrinsicContentSize)")
            }

            // Dragging the content must NOT move the window: it would eat
            // the drag-to-reorder on the toolbar step. The title strip must
            // still move it, or the window can't be repositioned at all.
            let beforeContentDrag = window.frame.origin
            await drag(fromCocoa: CGPoint(x: window.frame.midX, y: window.frame.midY - 40), byX: 90)
            try? await Task.sleep(for: .seconds(0.5))
            let movedByContent = hypot(
                window.frame.origin.x - beforeContentDrag.x,
                window.frame.origin.y - beforeContentDrag.y
            )
            print("[onboarding-window] \(movedByContent < 5 ? "PASS" : "FAIL") content drag left the window put (moved \(Int(movedByContent))pt)")

            let beforeTitleDrag = window.frame.origin
            await drag(fromCocoa: CGPoint(x: window.frame.midX, y: window.frame.maxY - 10), byX: 60)
            try? await Task.sleep(for: .seconds(0.5))
            let movedByTitle = window.frame.origin.x - beforeTitleDrag.x
            print("[onboarding-window] \(movedByTitle > 30 ? "PASS" : "FAIL") title strip still drags the window (moved \(Int(movedByTitle))pt)")

            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    private static func drag(fromCocoa start: CGPoint, byX deltaX: CGFloat) async {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let origin = CGPoint(x: start.x, y: primaryHeight - start.y)
        post(.leftMouseDown, at: origin)
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            post(.leftMouseDragged, at: CGPoint(x: origin.x + deltaX * progress, y: origin.y))
            try? await Task.sleep(for: .milliseconds(16))
        }
        post(.leftMouseUp, at: CGPoint(x: origin.x + deltaX, y: origin.y))
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func runIfEnabled() {
        guard let directory = outputDirectory else { return }
        // A render captures one frame, synchronously, before any `.task` has
        // fired — so without this every step photographs mid-reveal at
        // opacity 0, an empty page that reads as a layout bug.
        // `accessibilityReduceMotion` can't be forced instead: it's a
        // read-only environment value.
        OnboardingReveal.startsRevealed = true
        Task {
            render(OnboardingView(onFinish: {}), named: "0-flow", to: directory)
            // The later steps in situ: standalone renders don't exercise the
            // root's vertical centring or the title-bar clearance.
            render(OnboardingView(onFinish: {}, initialStep: .hotkeys), named: "0-flow-hotkeys", to: directory)
            render(OnboardingView(onFinish: {}, initialStep: .toolbar), named: "0-flow-toolbar", to: directory)
            render(padded(OnboardingWelcomeStep(menuBarIconFrame: .constant(.zero), isIconInFlight: false)), named: "1-welcome", to: directory)
            render(padded(OnboardingPermissionStep()), named: "2-permission", to: directory)
            render(padded(OnboardingSavingStep()), named: "3-saving", to: directory)
            render(padded(OnboardingHotkeysStep()), named: "4-hotkeys", to: directory)
            render(padded(OnboardingToolbarStep()), named: "5-toolbar", to: directory)
            render(padded(OnboardingFinishStep()), named: "6-finish", to: directory)
            print("[onboarding-render] wrote PNGs to \(directory.path)")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }

    /// Steps are drawn by the root view with padding and on an opaque
    /// backing; reproduce both so a standalone render matches what the window
    /// shows.
    private static func padded(_ step: some View) -> some View {
        step
            .padding(.horizontal, 36)
            .padding(.top, 36)
            .frame(width: stepSize.width, height: stepSize.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor))
    }

    private static func render(_ view: some View, named name: String, to directory: URL) {
        let renderer = ImageRenderer(
            content: view.frame(width: stepSize.width, height: stepSize.height)
        )
        renderer.scale = 2
        guard
            let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("[onboarding-render] FAILED to render \(name)")
            return
        }
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
