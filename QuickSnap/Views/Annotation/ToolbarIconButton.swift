//
//  ToolbarIconButton.swift
//  QuickSnap
//

import CoreTransferable
import SwiftUI

/// Circular icon button shared by the markup toolbar and the crop confirm
/// bar: hover highlight, press-down scale (feedback lands on mouse-down,
/// not release), and an accent-tinted active state for toggles like the
/// crop button or the currently selected tool.
struct ToolbarIconButton: View {
    let systemImage: String
    var isActive = false
    var diameter: CGFloat = 28
    var iconSize: CGFloat = 14
    var iconWeight: Font.Weight = .medium
    /// Foreground color while not active.
    var tint: Color = .primary
    /// Dims the icon and stops the click. Custom button labels don't dim
    /// themselves under `.disabled`, so the tint is applied here too.
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: iconWeight))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(backgroundColor))
                .foregroundStyle(isActive ? Color.accentColor : tint)
                .opacity(isEnabled ? 1 : 0.35)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
        .disabled(!isEnabled)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
    }

    private var backgroundColor: Color {
        if isActive {
            Color.accentColor.opacity(0.25)
        } else if isHovering && isEnabled {
            Color.primary.opacity(0.08)
        } else {
            Color.clear
        }
    }
}

/// The non-button sibling of `ToolbarIconButton`: same circular look and
/// hover highlight, but the icon is a drag source rather than a click
/// target (the markup toolbar's drag-out-file handle).
struct ToolbarIconDragSource<Payload: Transferable>: View {
    let systemImage: String
    let payload: Payload

    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .medium))
            .frame(width: 28, height: 28)
            .background(Circle().fill(isHovering ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Circle())
            .draggable(payload)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
    }
}
