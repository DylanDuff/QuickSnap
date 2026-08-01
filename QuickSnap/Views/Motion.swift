//
//  Motion.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// House motion style, following Apple's fluid-interface guidance:
/// critically damped springs by default (no overshoot — bounce is reserved
/// for gestures that carry momentum, of which we currently have none), and
/// reduced motion swaps slides/scales for plain cross-fades.
enum Motion {
    /// Enter/exit spring for floating panels (preview thumbnail, toast).
    /// `.smooth` is a critically damped spring — Apple's "damping 1.0".
    static let panelSpring: Animation = .smooth(duration: 0.35)

    /// Quick spring for small in-view reveals (hover action bar).
    static let revealSpring: Animation = .smooth(duration: 0.2)

    /// Whether the user has asked for reduced motion system-wide. SwiftUI
    /// views should prefer `@Environment(\.accessibilityReduceMotion)`;
    /// this is for AppKit-side (NSWindow) animations.
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// Press-down feedback: the control shrinks the instant it's pressed
/// (response on mouse-down, not on release) and springs back on release.
struct PressScaleButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.9

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
