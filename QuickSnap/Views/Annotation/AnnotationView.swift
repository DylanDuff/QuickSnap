//
//  AnnotationView.swift
//  QuickSnap
//

import SwiftUI

/// The annotation window's content: nothing but the PaperKit markup canvas
/// (screenshot as its background) on a small material mat. Title bar, close
/// button, and resize are all native window chrome; the window resizes
/// freely, and the canvas inside it is a viewport onto the capture rather
/// than a frame around it — resizing shows more or less of the canvas and
/// never rescales what's on it.
///
/// The tools pill is deliberately **not** part of this view: it lives in its
/// own child panel (`MarkupToolbarPanel`) pinned below the window, so the
/// window's frame — and therefore its native resize handles — hugs the
/// image instead of wrapping around a mostly-empty toolbar row.
struct AnnotationView: View {
    /// Fixed chrome around the canvas. `AnnotationCoordinator` uses
    /// `chromeSize` to size a new window (capture at actual size + chrome),
    /// so these must stay in sync with the modifiers in `body`. It is no
    /// longer a resize constraint — the window is free.
    enum Layout {
        static let matTopPadding: CGFloat = 30
        static let matSidePadding: CGFloat = 6
        static let matBottomPadding: CGFloat = 6
        /// Gap between the window's bottom edge and the toolbar pill. The
        /// pill is a separate window, so this is *not* part of `chromeSize`
        /// — `MarkupToolbarPanel.reposition()` is what consumes it.
        static let toolbarGap: CGFloat = 16

        /// Total non-canvas size within the window's content area.
        static var chromeSize: CGSize {
            CGSize(
                width: matSidePadding * 2,
                height: matTopPadding + matBottomPadding
            )
        }
    }

    @ObservedObject var canvas: MarkupCanvasController
    /// Save and Save As, wired to the same coordinator actions the toolbar
    /// buttons use — see `keyboardShortcuts`.
    let onSave: (CGImage) -> Void
    let onSaveAs: (CGImage) -> Void

    /// ⌘S / ⌘⇧S and ⌘Z / ⌘⇧Z, always available regardless of what the
    /// toolbar contains.
    ///
    /// This is what makes a freely customisable toolbar safe: the layout
    /// editor lets every export button be removed, and without a shortcut
    /// that would strand an annotated screenshot in a window it can't leave.
    /// Undo and redo lean on the same arrangement from the other side —
    /// they're left *out* of the default toolbar, because the keys are how
    /// most people will reach them.
    ///
    /// Taking ⌘Z from the canvas costs nothing: the remote PaperKit view
    /// implements no undo of its own (measured — a synthesized ⌘Z over a
    /// freshly drawn stroke changed nothing at all, `Probe/UndoProbe.swift`),
    /// so there is no built-in behaviour here to shadow.
    ///
    /// Deliberately **no ⌘C**, though. Copy would be the obvious extra, but
    /// ⌘C means "copy the selection" while a text box is being edited — and
    /// a SwiftUI `keyboardShortcut` resolves through `performKeyEquivalent`,
    /// *before* the remote view ever sees the key. Taking ⌘C would quietly
    /// break text editing to guard against a case ⌘S already covers.
    ///
    /// They live here, in the window's own content, rather than in the
    /// toolbar pill: that panel is `canBecomeKey == false`, so it never
    /// receives key events at all.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { export(then: onSave) }
                .keyboardShortcut("s", modifiers: .command)
            Button("") { export(then: onSaveAs) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            // Disabled when there's nothing to go back to, so an empty
            // history doesn't swallow the key with a no-op.
            Button("") { canvas.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!canvas.canUndo)
            Button("") { canvas.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!canvas.canRedo)
            // The standard macOS zoom set. ⌘0 is "fit the whole thing in
            // the window", ⌘1 is actual size — the same pair Preview and
            // most editors use.
            Button("") { canvas.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!canvas.canZoomIn)
            Button("") { canvas.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!canvas.canZoomOut)
            Button("") { canvas.zoomToFit() }
                .keyboardShortcut("0", modifiers: .command)
            Button("") { canvas.zoomToActualSize() }
                .keyboardShortcut("1", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    /// Flattens before handing over, so a shortcut produces exactly what the
    /// equivalent toolbar button would.
    private func export(then handle: @escaping (CGImage) -> Void) {
        Task {
            handle(await canvas.exportFlattened() ?? canvas.baseImage)
        }
    }

    var body: some View {
        // No `.aspectRatio` any more: the canvas fills the mat whatever
        // shape the window is, and the capture floats inside it at whatever
        // zoom the user left it at.
        MarkupCanvasView(controller: canvas)
            // Only mounted while an insertion or crop is armed: any
            // layer above the remote PaperKit canvas kills its mouse
            // input, which is wanted during those interactions and
            // harmful otherwise.
            .overlay {
                if !canvas.pendingRedactions.isEmpty {
                    // First: a held upload is waiting on this, and it's the
                    // only overlay the user didn't ask for by picking a tool.
                    RedactionOverlay(controller: canvas)
                } else if canvas.pendingInsertion != nil {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
            )
            .background(keyboardShortcuts)
            .ignoresSafeArea(.container, edges: .top)
    }
}
