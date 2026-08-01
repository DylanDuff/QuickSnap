//
//  MarkupToolbarPanel.swift
//  QuickSnap
//

import AppKit
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Drag-out payload for the annotation toolbar. Unlike the preview panel's
/// drag (which has a file on disk already), the annotated file doesn't
/// exist until it's needed — `makeFile` flattens the canvas and writes a
/// temporary PNG only when a drop destination actually requests the file.
nonisolated struct AnnotatedFileDrag: Transferable {
    let makeFile: @Sendable () async throws -> URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .png) { drag in
            SentTransferredFile(try await drag.makeFile())
        }
    }
}

nonisolated enum AnnotatedFileDragError: Error {
    case exportFailed
}

/// Borderless child panel holding the markup tools pill, pinned below its
/// annotation window.
///
/// The pill used to be a row inside the window's own content, which put the
/// window's bottom edge — and therefore its native resize handles — a
/// toolbar's height below the image, with the bottom corners landing in
/// empty space either side of the pill. Hosting it in its own window lets
/// the annotation window's frame hug the mat exactly.
///
/// The panel is deliberately **as wide as the window it hangs off**, with
/// the pill centered in it, rather than sized to the pill. The pill's width
/// animates on every preset-row swap, and a window cannot resize in lockstep
/// with the SwiftUI content inside it: `onGeometryChange` reports a size
/// SwiftUI has *already* laid out and drawn at, so a panel tracking the pill
/// is always a beat behind. That showed up two ways — the capsule's ends
/// clipped square while it grew (it read as the toolbar losing its corner
/// radius), and the pill sliding sideways as the panel's edges moved under
/// already-drawn content. Both are gone if the window simply doesn't change
/// during a transition, which is what a fixed width buys: the width morph
/// then animates entirely inside SwiftUI, exactly as it did when the pill
/// was a row in the annotation window's own content.
///
/// The cost is transparent panel either side of the pill. That's the same
/// footprint the annotation window itself used to occupy there, so it costs
/// nothing that wasn't already being paid.
///
/// Placement is the panel's own job (`reposition()`), since a pill size
/// change reaches the panel first; `AnnotationCoordinator` calls the same
/// method when the window resizes.
final class MarkupToolbarPanel: NSPanel {
    /// Clearance kept either side of the pill when the window is too narrow
    /// to provide it — the pill must never be clipped by its own panel.
    private static let minimumSideMargin: CGFloat = 24

    /// The pill's own measured size, reported by SwiftUI. Only used to size
    /// the panel's height and to catch the narrow-window case; the panel's
    /// width normally comes from the parent window.
    private var pillSize: CGSize = .zero

    init(
        controller: MarkupCanvasController,
        onCopy: @escaping (CGImage) -> Void,
        onSave: @escaping (CGImage) -> Void,
        onSaveAs: @escaping (CGImage) -> Void,
        onUpload: @escaping (CGImage) -> Void,
        onExportDragFile: @escaping @Sendable (CGImage) throws -> URL
    ) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: MarkupToolbar.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        // The annotation window is non-opaque too, so macOS already derives
        // its shadow from the content's alpha — the pill cast one there.
        // Keep that now that it's a window of its own.
        hasShadow = true
        isReleasedWhenClosed = false
        // NSPanel defaults this to true, which would hide the pill while
        // leaving its window on screen whenever the app deactivates.
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]

        let hosting = NSHostingView(rootView: MarkupToolbarContainer(
            controller: controller,
            onCopy: onCopy,
            onSave: onSave,
            onSaveAs: onSaveAs,
            onUpload: onUpload,
            onExportDragFile: onExportDragFile,
            onSizeChange: { [weak self] size in self?.pillSizeChanged(size) }
        ))
        contentView = hosting
        pillSizeChanged(hosting.fittingSize)
    }

    /// Never key: clicking a tool must not pull key status off the
    /// annotation window it belongs to. Buttons still receive their mouse
    /// events — same pattern as `ScreenshotPreviewPanel`.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The pill's height is fixed and its width only matters here in the
    /// narrow-window case, so in normal use this changes the panel's frame
    /// exactly never — which is the entire point.
    private func pillSizeChanged(_ size: CGSize) {
        let measured = CGSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard measured.width > 0, measured.height > 0, measured != pillSize else { return }
        pillSize = measured
        reposition()
    }

    /// Spans the parent window's width, centered on it, `toolbarGap` below
    /// its bottom edge (which, for a titled window, is the bottom of its
    /// content area). Widens past the window only if the pill wouldn't
    /// otherwise fit.
    func reposition() {
        guard let parent, pillSize.height > 0 else { return }
        let width = max(parent.frame.width, pillSize.width + Self.minimumSideMargin * 2)
        let target = NSRect(
            x: (parent.frame.midX - width / 2).rounded(),
            y: (parent.frame.minY - AnnotationView.Layout.toolbarGap - pillSize.height).rounded(),
            width: width,
            height: pillSize.height
        )
        guard target != frame else { return }
        setFrame(target, display: true)
    }
}

/// Wraps `MarkupToolbar` with the export plumbing its output buttons need,
/// and reports the pill's laid-out size back to the panel. `.fixedSize()`
/// keeps the pill at its ideal size no matter what frame the panel happens
/// to have — the panel follows the pill, not the other way round.
private struct MarkupToolbarContainer: View {
    @ObservedObject var controller: MarkupCanvasController
    let onCopy: (CGImage) -> Void
    let onSave: (CGImage) -> Void
    let onSaveAs: (CGImage) -> Void
    let onUpload: (CGImage) -> Void
    /// Writes a flattened export to a drag-suitable temporary file —
    /// provided by `AnnotationCoordinator` (it owns naming and file I/O).
    let onExportDragFile: @Sendable (CGImage) throws -> URL
    let onSizeChange: (CGSize) -> Void

    var body: some View {
        MarkupToolbar(
            controller: controller,
            onCopy: { exportFlattened(then: onCopy) },
            onSave: { exportFlattened(then: onSave) },
            onSaveAs: { exportFlattened(then: onSaveAs) },
            onUpload: { exportFlattened(then: onUpload) },
            dragFile: dragFile
        )
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: { $0.size }, action: onSizeChange)
        // Measure the pill, then center it in the panel — which spans the
        // window, so this is what keeps the pill centered under the window
        // without the panel itself having to move as the pill's width
        // animates.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func exportFlattened(then handle: @escaping (CGImage) -> Void) {
        Task {
            if let flattened = await controller.exportFlattened() {
                handle(flattened)
            }
        }
    }

    /// The toolbar's drag-out payload: flatten at drop time, then hand the
    /// image to the coordinator's temp-file writer.
    private var dragFile: AnnotatedFileDrag {
        AnnotatedFileDrag { [controller, onExportDragFile] in
            guard let flattened = await controller.exportFlattened() else {
                throw AnnotatedFileDragError.exportFailed
            }
            return try onExportDragFile(flattened)
        }
    }
}
