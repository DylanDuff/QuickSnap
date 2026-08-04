//
//  OnboardingView.swift
//  QuickSnap
//

import SwiftUI

/// The first-run flow's content: a step at a time, with the navigation
/// chrome around it. `OnboardingCoordinator` owns the window.
///
/// What's here is what a first run either *breaks* on or never discovers:
/// the Screen Recording permission (without which nothing works at all),
/// the save folder (whose first write blocks on a system prompt), and the
/// shortcuts (an unknown shortcut is a dead feature). Everything else is a
/// preference someone might reasonably want set before their first capture.
/// Deliberately absent: anything destructive (retention), anything needing
/// credentials (uploading), and anything you'd only understand after using
/// the app for a while.
struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var step: Step = .welcome
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Int, CaseIterable {
        case welcome
        case permission
        case saving
        case hotkeys
        case toolbar
        case finish

        var isLast: Bool { self == .finish }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 36)
                .padding(.top, step == .welcome ? 0 : 36)

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The underglow lives at the root, not behind the welcome step: a
        // step is drawn *inside* the horizontal padding above, so a
        // background there stopped 36 pt short of each edge and cut off at
        // the footer, which read as the glow being clipped. Here it's
        // full-bleed and runs behind the footer, which is translucent so it
        // shows through.
        .background {
            ZStack {
                Rectangle().fill(.regularMaterial)
                if step == .welcome {
                    AmbientUnderglow()
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: OnboardingWelcomeStep()
        case .permission: OnboardingPermissionStep()
        case .saving: OnboardingSavingStep()
        case .hotkeys: OnboardingHotkeysStep()
        case .toolbar: OnboardingToolbarStep()
        case .finish: OnboardingFinishStep()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back", action: goBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Every step is skippable, including the permission one — the
            // app explains itself again at the point a capture actually
            // fails, and refusing to let someone in is worse than letting
            // them hit that.
            if !step.isLast {
                Button("Skip", action: onFinish)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Button(step.isLast ? "Done" : "Continue", action: goForward)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        // Centred against the footer itself, not wedged between spacers: the
        // buttons on either side have different widths (and Back disappears
        // on the first step), so a flex layout puts the dots visibly off
        // centre and shifts them as you move through the flow.
        .overlay { progressDots }
        // Thin enough to read as glass over the underglow rather than a bar
        // sitting on top of it — the glow runs the full height of the window
        // behind this.
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.self) { dot in
                Circle()
                    .fill(dot == step ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : Motion.revealSpring, value: step)
    }

    private func goForward() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onFinish()
            return
        }
        withAnimation(reduceMotion ? nil : Motion.revealSpring) { step = next }
    }

    private func goBack() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        withAnimation(reduceMotion ? nil : Motion.revealSpring) { step = previous }
    }
}

/// Shared layout for a step: an icon, a title, a line of explanation, and
/// whatever the step is actually asking for. Kept here rather than in its own
/// file — it exists only for these six screens.
struct OnboardingStepLayout<Content: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(Color.accentColor)

                Text(title)
                    .font(.system(size: 22, weight: .semibold))

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    OnboardingView(onFinish: {})
        .frame(width: 620, height: 560)
}
