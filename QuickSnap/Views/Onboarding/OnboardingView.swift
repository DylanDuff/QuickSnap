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
    /// Which step to open on. Only ever non-default from the render probe,
    /// which needs to photograph the later steps in situ.
    var initialStep: Step = .welcome

    @State private var step: Step

    init(onFinish: @escaping () -> Void, initialStep: Step = .welcome) {
        self.onFinish = onFinish
        self.initialStep = initialStep
        _step = State(initialValue: initialStep)
    }
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
            // The step and its navigation are one block: the buttons belong
            // to the page they act on and sit just under its content, rather
            // than pinned to the window's bottom edge where they read as
            // window chrome and leave a long empty gap on the shorter steps.
            VStack(spacing: 26) {
                content
                navigationButtons
            }
            .padding(.horizontal, 36)
            // Enough top padding to keep the tallest step clear of the
            // traffic lights and the Skip button in the title-bar strip;
            // since the block is centred, it reads as a slight downward
            // nudge rather than as a margin.
            .padding(.top, step == .welcome ? 0 : 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            progressDots
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The underglow lives at the root, not behind the welcome step: a
        // step is drawn *inside* the horizontal padding above, so a
        // background there stopped 36 pt short of each edge and cut off at
        // the footer, which read as the glow being clipped. Here it's
        // full-bleed and runs all the way down: there is no footer bar over
        // it any more, only the dots.
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
        // In the title-bar strip, opposite the traffic lights. The
        // window is `.fullSizeContentView`, so this region is ours to
        // draw in and a control here still takes its clicks ahead of the
        // title bar's drag.
        .overlay(alignment: .topTrailing) { skipButton }
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

    /// Back and Continue, centred under the step's content. Skip isn't here
    /// — it's a way *out* of the flow rather than a way through it, so it
    /// sits in the top corner where it can't be mistaken for the next step.
    private var navigationButtons: some View {
        HStack(spacing: 12) {
            if step != .welcome {
                Button("Back", action: goBack)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Button(step.isLast ? "Done" : "Continue", action: goForward)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity)
    }

    /// Every step is skippable, including the permission one — the app
    /// explains itself again at the point a capture actually fails, and
    /// refusing to let someone in is worse than letting them hit that.
    @ViewBuilder
    private var skipButton: some View {
        if !step.isLast {
            Button("Skip", action: onFinish)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.top, 14)
                .padding(.trailing, 18)
        }
    }

    private var progressDots: some View {
        HStack(spacing: 7) {
            ForEach(Step.allCases, id: \.self) { dot in
                Circle()
                    .fill(dot == step ? Color.white : Color.white.opacity(0.28))
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
///
/// Arriving on a step draws its symbol on, then fades the text and controls
/// up beneath it in order. Each step view is rebuilt when the step changes,
/// so the `@State` resets and the sequence replays on every page.
struct OnboardingStepLayout<Content: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var content: Content

    @State private var isRevealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                icon
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .onboardingReveal(0, isRevealed: isRevealed, reduceMotion: reduceMotion)

                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onboardingReveal(1, isRevealed: isRevealed, reduceMotion: reduceMotion)
            }

            content
                .onboardingReveal(2, isRevealed: isRevealed, reduceMotion: reduceMotion)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await OnboardingReveal.begin { isRevealed = true } }
    }

    /// `.drawOn` is a *transition*, so the symbol has to be inserted for it
    /// to draw — `symbolEffect(.drawOn, isActive:)` compiles (the effect also
    /// conforms to `IndefiniteSymbolEffect`) but gives a repeating animation
    /// instead of the one-shot draw. The clear rectangle underneath reserves
    /// the space so nothing below shifts as it appears.
    private var icon: some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(height: 34)
            // The two transitions can't share a ternary: `.symbolEffect` is a
            // `SymbolEffectTransition`, and putting it opposite `.opacity`
            // erases both to `AnyTransition`, which has no such member.
            if reduceMotion {
                iconImage.transition(.opacity)
            } else if isRevealed {
                iconImage.transition(.symbolEffect(.drawOn))
            }
        }
    }

    private var iconImage: some View {
        Image(systemName: systemImage)
            .font(.system(size: 30, weight: .light))
            .foregroundStyle(Color.accentColor)
    }
}

/// The staggered entrance shared by the step layout and the welcome screen.
@MainActor
enum OnboardingReveal {
    /// Deferred by a beat, and animated: flipping the flag inside the same
    /// update that first shows the view gives SwiftUI no "before" state to
    /// animate from, so the symbol would simply appear instead of drawing.
    static func begin(_ reveal: @escaping () -> Void) async {
        try? await Task.sleep(for: .milliseconds(60))
        withAnimation(.smooth(duration: 0.5)) { reveal() }
    }

    static let stagger: TimeInterval = 0.09
    static let leadIn: TimeInterval = 0.16
}

extension View {
    /// Fades a piece of a step in, `index` places later than the one before
    /// it. Reduce Motion keeps the fade but drops the rise and the stagger —
    /// content still arrives, it just doesn't travel.
    func onboardingReveal(_ index: Int, isRevealed: Bool, reduceMotion: Bool) -> some View {
        opacity(isRevealed ? 1 : 0)
            .offset(y: isRevealed || reduceMotion ? 0 : 8)
            .animation(
                reduceMotion
                    ? .easeOut(duration: 0.18)
                    : .smooth(duration: 0.42)
                        .delay(OnboardingReveal.leadIn + Double(index) * OnboardingReveal.stagger),
                value: isRevealed
            )
    }
}

#Preview {
    OnboardingView(onFinish: {})
        .frame(width: 620, height: 560)
}
