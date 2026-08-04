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
    var body: some View {
        // Natural height, no internal spacers: the root centres this and its
        // navigation buttons together, so anything that expanded here would
        // shove the buttons back down to the window's edge.
        VStack(spacing: 22) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)

            VStack(spacing: 8) {
                Text("Welcome to QuickSnap")
                    .font(.system(size: 26, weight: .semibold))

                Text("Screenshots of an area, a window, or the whole screen — marked up, saved, and on your clipboard without leaving what you were doing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 16)
            }

            Label {
                Text("QuickSnap lives in the menu bar — look for the camera icon up top. There's no Dock icon.")
            } icon: {
                Image(systemName: "menubar.arrow.up.rectangle")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            Text("The next few screens set up the handful of things worth deciding now. You can skip any of them and change everything later in Settings.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    OnboardingWelcomeStep()
        .frame(width: 620, height: 480)
}
