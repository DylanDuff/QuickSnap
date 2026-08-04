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

    static func runIfEnabled() {
        guard let directory = outputDirectory else { return }
        Task {
            render(OnboardingView(onFinish: {}), named: "0-flow", to: directory)
            render(padded(OnboardingWelcomeStep()), named: "1-welcome", to: directory)
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
