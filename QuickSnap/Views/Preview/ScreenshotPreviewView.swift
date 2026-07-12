//
//  ScreenshotPreviewView.swift
//  QuickSnap
//

import AppKit
import SwiftUI

struct ScreenshotPreviewView: View {
    let image: NSImage
    /// False when the capture was never saved to disk — there's no file to
    /// reveal, so the Finder button is hidden.
    let showsRevealInFinder: Bool
    /// The file backing drag-out: the saved screenshot, or a temporary PNG
    /// when the capture was never saved to disk. Nil only if that temporary
    /// write failed, which hides the drag handle.
    let dragFileURL: URL?
    let onOpenInFinder: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void
    @ObservedObject var dragState: PreviewDragState

    @State private var isHovering = false
    @State private var isActionBarVisible = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )

            if isActionBarVisible {
                actionBar
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottom)))
            }
        }
        .overlay(alignment: .topTrailing) {
            if isActionBarVisible {
                PreviewActionButton(systemImage: "xmark", action: onClose)
                    .padding(6)
                    .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topTrailing)))
            }
        }
        .background(
            HoverTrackingArea(cursor: .openHand) { hovering in
                isHovering = hovering
                onHoverChanged(hovering)
            }
        )
        .onChange(of: isHovering) { updateActionBarVisibility() }
        .onChange(of: dragState.isDragging) { updateActionBarVisibility() }
        .onAppear { updateActionBarVisibility() }
    }

    /// Animates explicitly rather than via an `.animation(value:)` modifier —
    /// `isHovering` is driven from an AppKit callback and `dragState` from a
    /// separate object, and the implicit modifier didn't reliably pick up
    /// changes from both sources, especially the hide-on-drag path.
    private func updateActionBarVisibility() {
        withAnimation(.easeOut(duration: 0.15)) {
            isActionBarVisible = isHovering && !dragState.isDragging
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let dragFileURL {
                PreviewFileDragHandle(fileURL: dragFileURL)
            }
            PreviewActionButton(systemImage: "doc.on.doc.fill", action: onCopy)
            PreviewActionButton(systemImage: "pencil.tip.crop.circle.fill", action: onEdit)
            if showsRevealInFinder {
                PreviewActionButton(systemImage: "folder.fill", action: onOpenInFinder)
            }
        }
    }
}

/// Small circular hover control shared by the preview panel's action bar.
private struct PreviewActionButton: View {
    let systemImage: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .previewActionIconStyle()
        }
        .buttonStyle(.plain)
        .previewIconHoverEffect(isHovering: $isHovering)
    }
}
