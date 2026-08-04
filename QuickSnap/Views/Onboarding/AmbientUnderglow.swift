//
//  AmbientUnderglow.swift
//  QuickSnap
//

import SwiftUI

/// The animated underlight behind the onboarding welcome screen
/// (`BottomAmbientShader.metal`).
///
/// The shader *replaces* whatever layer it's applied to, keeping only that
/// layer's alpha as a mask — so this is a plain opaque rectangle with the
/// effect on it, sitting behind the content, rather than an effect on the
/// content itself. Put it in a `.background`, never an `.overlay`.
///
/// Under Reduce Motion it doesn't animate at all: the timeline is paused and
/// the shader is evaluated at one fixed, fully-revealed moment, so the screen
/// keeps its depth without anything moving. That's the house rule — degrade
/// to a still, not to nothing.
struct AmbientUnderglow: View {
    /// Fixed rather than the system accent — see `Color.quickSnapViolet`.
    var tint: Color = .quickSnapViolet

    /// How long the glow takes to grow up from the bottom edge on first
    /// appearance.
    private static let revealDuration: TimeInterval = 2.2
    /// The moment the still frame is sampled from when motion is off — far
    /// enough in that the pockets and motes have spread out.
    private static let stillMoment: TimeInterval = 6

    @State private var start = Date.now
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(paused: reduceMotion)) { context in
                let elapsed = reduceMotion
                    ? Self.stillMoment
                    : context.date.timeIntervalSince(start)
                Rectangle()
                    .fill(.white)
                    .layerEffect(
                        ShaderLibrary.default.bottomAmbientLighting(
                            .float2(geometry.size),
                            .float(elapsed),
                            .float(reduceMotion ? 1 : min(elapsed / Self.revealDuration, 1)),
                            .color(tint)
                        ),
                        // The shader only ever samples the pixel it's
                        // shading, so it needs no reach beyond it.
                        maxSampleOffset: .zero
                    )
            }
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

#Preview {
    AmbientUnderglow()
        .frame(width: 620, height: 400)
        .background(Color.black)
}
