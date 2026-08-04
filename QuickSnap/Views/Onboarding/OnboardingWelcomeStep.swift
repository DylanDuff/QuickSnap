//
//  OnboardingWelcomeStep.swift
//  QuickSnap
//

import SwiftUI

/// Opening screen: what the app is, and where to find it. The second half
/// matters more than it looks — QuickSnap has no Dock icon (`LSUIElement`),
/// so someone who closes this window and doesn't know to look in the menu
/// bar has effectively lost the app.
struct OnboardingWelcomeStep: View {
    /// Where the menu bar icon is, in window coordinates, so the flow can
    /// launch the flight from exactly where the user was looking.
    @Binding var menuBarIconFrame: CGRect
    /// Set while the icon is in flight: the row it came from fades out so
    /// the icon reads as having left it.
    var isIconInFlight: Bool

    @State private var isRevealed = OnboardingReveal.startsRevealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Natural height, no internal spacers: the root centres this and its
        // navigation buttons together, so anything that expanded here would
        // shove the buttons back down to the window's edge.
        VStack(spacing: 22) {
            // The app icon is an image, not a symbol, so there's nothing to
            // draw on: it settles in from slightly small instead, then the
            // words follow it in order.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .scaleEffect(isRevealed || reduceMotion ? 1 : 0.86)
                .opacity(isRevealed || reduceMotion ? 1 : 0)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.18) : .smooth(duration: 0.5),
                    value: isRevealed
                )

            VStack(spacing: 8) {
                Text("Welcome to QuickSnap")
                    .font(.system(size: 26, weight: .semibold))
                    .onboardingReveal(0, isRevealed: isRevealed, reduceMotion: reduceMotion)

                Text("The next few screens set up the handful of things worth deciding now. You can skip any of them and change everything later in Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
                    .onboardingReveal(1, isRevealed: isRevealed, reduceMotion: reduceMotion)
            }

            Label {
                Text("QuickSnap lives in the menu bar.")
                    .font(.callout.weight(.medium))
            } icon: {
                // The menu bar item's own symbol (`QuickSnapApp`'s
                // `MenuBarExtra`), so the thing to look for up there is the
                // thing shown here.
                Image(systemName: "camera.viewfinder")
                    // Close to the size it ends up at in the menu bar, so the
                    // flight is a journey rather than a resize.
                    .font(.system(size: MenuBarPresence.iconPointSize))
                    // Reported in window coordinates; the coordinator turns
                    // it into screen coordinates, since only it has the
                    // window.
                    .onGeometryChange(for: CGRect.self) { proxy in
                        proxy.frame(in: .global)
                    } action: { frame in
                        menuBarIconFrame = frame
                    }
                    // Hidden, not removed, the moment the flight starts: the
                    // flown copy takes over from here, and removing it would
                    // collapse the row around the gap.
                    .opacity(isIconInFlight ? 0 : 1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.quickSnapViolet.opacity(0.16))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.quickSnapViolet.opacity(0.35), lineWidth: 1)
            )
            .opacity(isIconInFlight ? 0 : 1)
            .animation(.easeOut(duration: 0.2), value: isIconInFlight)
            .onboardingReveal(2, isRevealed: isRevealed, reduceMotion: reduceMotion)

        }
        .frame(maxWidth: .infinity)
        .task { await OnboardingReveal.begin { isRevealed = true } }
    }
}

#Preview {
    OnboardingWelcomeStep(menuBarIconFrame: .constant(.zero), isIconInFlight: false)
        .frame(width: 620, height: 480)
}
