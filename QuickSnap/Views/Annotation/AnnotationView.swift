//
//  AnnotationView.swift
//  QuickSnap
//

import SwiftUI

/// The annotation window's content: the PaperKit markup canvas (screenshot
/// as its background) on a small material mat, with the custom markup
/// toolbar pill below. Title bar, close button, and resize are all native
/// window chrome; the window is aspect-locked to the canvas so the mat
/// always frames the image tightly — zoom/pan happens inside the canvas
/// viewport and never changes the window's shape.
///
/// Output actions hand the flattened image outward via closures — what
/// "Copy" and "Save As…" actually do is decided by `AnnotationCoordinator`.
struct AnnotationView: View {
    /// Fixed chrome around the canvas. `AnnotationCoordinator` uses
    /// `chromeSize` to lock window resizing to the image's aspect ratio
    /// (content size = canvas size + chrome), so these must stay in sync
    /// with the modifiers in `body`.
    enum Layout {
        static let matTopPadding: CGFloat = 30
        static let matSidePadding: CGFloat = 6
        static let matBottomPadding: CGFloat = 6
        static let toolbarSpacing: CGFloat = 16

        /// Total non-canvas size within the window's content area.
        static var chromeSize: CGSize {
            CGSize(
                width: matSidePadding * 2,
                height: matTopPadding + matBottomPadding + toolbarSpacing + MarkupToolbar.height
            )
        }
    }

    @StateObject private var canvas: MarkupCanvasController
    private let onCopy: (CGImage) -> Void
    private let onSaveAs: (CGImage) -> Void
    /// Fired when a crop changes the canvas's aspect ratio (width / height)
    /// — `AnnotationCoordinator` re-locks and resizes the window to match.
    private let onCanvasAspectChanged: (CGFloat) -> Void

    init(
        image: CGImage,
        onCopy: @escaping (CGImage) -> Void,
        onSaveAs: @escaping (CGImage) -> Void,
        onCanvasAspectChanged: @escaping (CGFloat) -> Void
    ) {
        _canvas = StateObject(wrappedValue: MarkupCanvasController(image: image))
        self.onCopy = onCopy
        self.onSaveAs = onSaveAs
        self.onCanvasAspectChanged = onCanvasAspectChanged
    }

    var body: some View {
        VStack(spacing: Layout.toolbarSpacing) {
            MarkupCanvasView(controller: canvas)
                .aspectRatio(canvas.canvasBounds.width / canvas.canvasBounds.height, contentMode: .fit)
                // Only mounted while an insertion or crop is armed: any
                // layer above the remote PaperKit canvas kills its mouse
                // input, which is wanted during those interactions and
                // harmful otherwise.
                .overlay {
                    if canvas.pendingInsertion != nil {
                        ShapeInsertionOverlay(controller: canvas)
                    } else if canvas.isCropActive {
                        CropOverlay(controller: canvas)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                // The hairline border must NOT be an .overlay: the PaperKit
                // canvas is an ExtensionKit remote view, and any SwiftUI
                // layer above it — even .allowsHitTesting(false) — kills
                // its mouse input at the window-server level. Draw the
                // border behind, slightly outset, instead.
                .background(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                        .padding(-1)
                )
                .padding(.top, Layout.matTopPadding)
                .padding(.horizontal, Layout.matSidePadding)
                .padding(.bottom, Layout.matBottomPadding)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.regularMaterial)
                )

            MarkupToolbar(
                controller: canvas,
                onCopy: { exportFlattened(then: onCopy) },
                onSaveAs: { exportFlattened(then: onSaveAs) }
            )
        }
        .padding(0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: canvas.canvasBounds) { _, bounds in
            guard bounds.height > 0 else { return }
            onCanvasAspectChanged(bounds.width / bounds.height)
        }
    }

    private func exportFlattened(then handle: @escaping (CGImage) -> Void) {
        Task {
            if let flattened = await canvas.exportFlattened() {
                handle(flattened)
            }
        }
    }
}
