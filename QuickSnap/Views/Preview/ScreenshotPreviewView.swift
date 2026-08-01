//
//  ScreenshotPreviewView.swift
//  QuickSnap
//

import AppKit
import SwiftUI

struct ScreenshotPreviewView: View {
    /// Hover action bar metrics, exposed so `ScreenshotPreviewController`
    /// can size the panel large enough for the actions to fit with
    /// breathing room instead of pressing the preview's bounds.
    enum ActionBarMetrics {
        /// Matches `PreviewActionIconStyle`'s frame.
        static let buttonDiameter: CGFloat = 34
        static let spacing: CGFloat = 10
        /// Minimum gap between the bar's outermost buttons and the panel edge.
        static let breathingRoom: CGFloat = 14

        static func minimumPanelWidth(buttonCount: Int) -> CGFloat {
            CGFloat(buttonCount) * buttonDiameter
                + CGFloat(buttonCount - 1) * spacing
                + breathingRoom * 2
        }
    }

    let image: NSImage
    /// Where the saved capture currently is — observed rather than copied,
    /// so a `{describe}` rename landing while the panel is up moves the
    /// Finder button and the drag payload with it. Nil url = the capture was
    /// never saved to disk, which hides the Finder button.
    @ObservedObject var file: CaptureFile
    /// Drag-out fallback for a capture with no file of its own: a temporary
    /// PNG written at show time. Nil only if that write failed, which hides
    /// the drag handle.
    let temporaryDragFileURL: URL?
    let onOpenInFinder: () -> Void
    let onCopy: () -> Void
    let onEdit: () -> Void
    /// Nil hides the Immich upload button — see `ScreenshotPreviewController.show`.
    let onUpload: (() -> Void)?
    let onClose: () -> Void
    let onHoverChanged: (Bool) -> Void
    @ObservedObject var dragState: PreviewDragState

    @State private var isHovering = false
    @State private var isActionBarVisible = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    .transition(revealTransition(anchor: .bottom))
            }
        }
        .overlay(alignment: .topTrailing) {
            if isActionBarVisible {
                PreviewActionButton(systemImage: "xmark", action: onClose)
                    .padding(6)
                    .transition(revealTransition(anchor: .topTrailing))
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
        withAnimation(reduceMotion ? .easeOut(duration: 0.15) : Motion.revealSpring) {
            isActionBarVisible = isHovering && !dragState.isDragging
        }
    }

    /// Scale-from-anchor reveal so the bar grows out of the edge it lives
    /// on; a plain fade under reduced motion.
    private func revealTransition(anchor: UnitPoint) -> AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .scale(scale: 0.9, anchor: anchor))
    }

    /// The saved capture if there is one, else the temporary PNG.
    private var dragFileURL: URL? {
        file.url ?? temporaryDragFileURL
    }

    private var actionBar: some View {
        HStack(spacing: ActionBarMetrics.spacing) {
            if let dragFileURL {
                PreviewFileDragHandle(fileURL: dragFileURL)
            }
            PreviewActionButton(systemImage: "doc.on.doc.fill", action: onCopy)
            PreviewActionButton(systemImage: "pencil.tip.crop.circle.fill", action: onEdit)
            if let onUpload {
                PreviewActionButton(systemImage: "arrow.up.circle.fill", action: onUpload)
            }
            if file.url != nil {
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
        .buttonStyle(PressScaleButtonStyle())
        .previewIconHoverEffect(isHovering: $isHovering)
    }
}
