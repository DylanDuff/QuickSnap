//
//  PreviewActionIconStyle.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Shared look for the action bar's circular icons: sizes the icon's
/// container and gives it a frosted, blurred backing so it reads clearly
/// over any screenshot content behind it.
private struct PreviewActionIconStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(
                width: ScreenshotPreviewView.ActionBarMetrics.buttonDiameter,
                height: ScreenshotPreviewView.ActionBarMetrics.buttonDiameter
            )
            .background(.black.opacity(0.35), in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 1))
    }
}

/// Cursor-swap + subtle scale-up feedback shared by every action bar icon.
/// Animates explicitly at the mutation site rather than relying on an
/// `.animation(value:)` modifier, which is unreliable here since hover state
/// is driven from an AppKit callback rather than a SwiftUI gesture.
private struct PreviewIconHoverEffect: ViewModifier {
    @Binding var isHovering: Bool
    var blocksWindowDrag: Bool = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovering ? 1.1 : 1)
            .background(
                HoverTrackingArea(cursor: .pointingHand, onHover: { hovering in
                    withAnimation(.easeOut(duration: 0.12)) {
                        isHovering = hovering
                    }
                }, blocksWindowDrag: blocksWindowDrag)
            )
    }
}

extension View {
    func previewActionIconStyle() -> some View {
        modifier(PreviewActionIconStyle())
    }

    func previewIconHoverEffect(isHovering: Binding<Bool>, blocksWindowDrag: Bool = false) -> some View {
        modifier(PreviewIconHoverEffect(isHovering: isHovering, blocksWindowDrag: blocksWindowDrag))
    }
}
