//
//  MarkupCanvasController.swift
//  QuickSnap
//

import AppKit
import Combine
import PaperKit
import PencilKit
import SwiftUI

/// The markup tools our custom toolbar can select. Drawing tools map to
/// PencilKit `PKTool`s on the PaperKit canvas; `select` flips the canvas
/// into selection mode instead (mouse input selects/moves existing markup
/// rather than drawing).
enum MarkupTool: String, CaseIterable, Identifiable {
    case select
    case pen
    case highlighter
    case eraser

    var id: String { rawValue }
}

/// An insertion armed from the toolbar's insert menu, waiting for the user
/// to drag out its geometry on the canvas. While non-nil,
/// `ShapeInsertionOverlay` covers the canvas to capture that drag.
enum PendingInsertion: Equatable {
    case shape(ShapeConfiguration.Shape)
    case line(arrow: Bool)
}

/// Transient UI state shared between `MarkupToolbar` (tool/color/width
/// selection, insert actions) and `MarkupCanvasView` (the PaperKit canvas
/// that state is applied to). UI-layer only: it never touches Services —
/// exported images are handed outward via `AnnotationView`'s closures.
///
/// Canvas coordinates equal the screenshot's pixel coordinates (the markup
/// bounds are the image's pixel size), so stroke widths, inserted-shape
/// frames, and text sizes are all expressed in image pixels and export 1:1.
@MainActor
final class MarkupCanvasController: nonisolated ObservableObject {
    @Published var tool: MarkupTool = .pen {
        didSet {
            pendingInsertion = nil
            isCropActive = false
            applyTool()
        }
    }
    /// Non-nil while the user has picked something from the insert menu and
    /// hasn't dragged it out on the canvas yet. Picking a tool cancels it.
    @Published var pendingInsertion: PendingInsertion? {
        didSet {
            if pendingInsertion != nil { isCropActive = false }
        }
    }
    /// While true, `CropOverlay` covers the canvas: the user drags out and
    /// adjusts a crop rect, then confirms (Return / ✓) or cancels (Esc).
    /// Mutually exclusive with `pendingInsertion` and cancelled by picking
    /// any tool.
    @Published var isCropActive = false {
        didSet {
            if isCropActive { pendingInsertion = nil }
        }
    }
    /// Regions a detector flagged as sensitive, still visible in the image.
    /// Non-empty means `RedactionOverlay` is up: the user clicks a region to
    /// black it out, or takes all of them at once. Emptying this dismisses
    /// the review.
    @Published var pendingRedactions: [SensitiveMatch] = [] {
        didSet {
            if !pendingRedactions.isEmpty {
                pendingInsertion = nil
                isCropActive = false
                hasReviewedSensitiveContent = true
            }
        }
    }

    /// True while a scan is running, so the toolbar can show it working —
    /// Vision takes a second or two on a full-screen capture, and a button
    /// that appears to do nothing gets pressed again.
    @Published var isScanningForSensitiveContent = false

    /// Set once findings have been put in front of the user in this window.
    ///
    /// It's what stops the gate from looping: after the review, an upload
    /// from this window skips the check, so choosing to keep something
    /// flagged doesn't hold the very next upload for the same reason and
    /// pop a second review over the first.
    private(set) var hasReviewedSensitiveContent = false

    /// Set when the window was opened *because* an upload was held. The
    /// review bar then offers to carry that upload on, with whatever the
    /// image looks like once the user is done — otherwise there'd be no way
    /// to complete it except a toolbar button that's hidden by default.
    ///
    /// A closure the coordinator wires, like `AnnotationView`'s outputs —
    /// this class still touches no Services.
    var continueHeldUpload: ((CGImage) -> Void)?
    @Published var color: Color {
        didSet { applyTool() }
    }
    /// Stroke width in image pixels.
    @Published var strokeWidth: CGFloat {
        didSet { applyTool() }
    }

    /// The screenshot under the markup. Both change together when a crop is
    /// applied; `canvasBounds` stays origin-zero at the image's pixel size.
    @Published private(set) var baseImage: CGImage
    @Published private(set) var canvasBounds: CGRect
    /// The canvas region currently visible in the viewport, in image pixels
    /// — equals `canvasBounds` at fit zoom, a sub-rect when zoomed in.
    /// Updated from the PaperKit delegate; overlays use it to map view
    /// points to canvas pixels regardless of zoom/pan.
    @Published private(set) var visibleCanvasFrame: CGRect

    /// The last region the remote canvas actually *reported* — nil until
    /// its first delegate report. Viewport enforcement verifies against
    /// this, never against `visibleCanvasFrame`, whose initial value is a
    /// local assumption: trusting it made enforcement "converge" before
    /// the remote had even initialized (probe, 2026-07), leaving the
    /// canvas at the remote's default zoom instead of fit.
    private(set) var lastRemoteReport: CGRect?
    let strokeWidthRange: ClosedRange<CGFloat>

    /// The preset widths the toolbar offers, spanning `strokeWidthRange`
    /// geometrically (stroke perception is multiplicative — equal ratios
    /// read as equal steps). The middle preset is the image-proportional
    /// width, save for clamping at extreme image sizes. The step count is
    /// `AppSettings.markupStrokeStepCount` — the Markup settings page
    /// stores a default step index into this ladder.
    var strokeWidthPresets: [CGFloat] {
        Self.strokeWidthPresets(in: strokeWidthRange)
    }

    private static func strokeWidthPresets(in range: ClosedRange<CGFloat>) -> [CGFloat] {
        let lower = range.lowerBound
        let upper = range.upperBound
        guard upper > lower else { return [lower] }
        let steps = AppSettings.markupStrokeStepCount
        return (0..<steps).map { lower * pow(upper / lower, CGFloat($0) / CGFloat(steps - 1)) }
    }

    weak var viewController: PaperMarkupViewController? {
        didSet { applyTool() }
    }

    /// Defaults are passed in (from the Markup settings, read by
    /// `AnnotationCoordinator`) rather than read here — this class stays
    /// clear of Services. `defaultStrokeStep` indexes the preset ladder so
    /// the setting is relative ("medium"), not an absolute pixel width that
    /// would read differently across capture sizes.
    init(image: CGImage, defaultColor: Color, defaultStrokeStep: Int) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        baseImage = image
        canvasBounds = bounds
        visibleCanvasFrame = bounds
        color = defaultColor

        // Scale stroke widths with the image so annotations stay visually
        // proportional whether the capture is a small window or a full
        // Retina display. PKInkingTool widths get clamped to the ink's
        // validWidthRange internally, so cap the top end conservatively.
        let proportionalWidth = bounds.width * 0.005
        strokeWidthRange = max(2, proportionalWidth / 3)...min(60, max(12, proportionalWidth * 3))
        let presets = Self.strokeWidthPresets(in: strokeWidthRange)
        strokeWidth = presets[min(max(defaultStrokeStep, 0), presets.count - 1)]

        if ZoomResizeProbe.isEnabled {
            ZoomResizeProbe.currentCanvas = self
        }
    }

    private var nsColor: NSColor { NSColor(color) }

    func applyTool() {
        guard let viewController else { return }
        switch tool {
        case .select:
            viewController.indirectPointerTouchMode = .selection
        case .pen:
            setInkingTool(.pen, alpha: 1, widthScale: 1)
        case .highlighter:
            setInkingTool(.marker, alpha: 0.4, widthScale: 3)
        case .eraser:
            viewController.indirectPointerTouchMode = .drawing
            viewController.drawingTool = PKEraserTool(.vector)
        }
    }

    private func setInkingTool(_ ink: PKInkingTool.InkType, alpha: CGFloat, widthScale: CGFloat) {
        guard let viewController else { return }
        viewController.indirectPointerTouchMode = .drawing
        viewController.drawingTool = PKInkingTool(
            ink,
            color: nsColor.withAlphaComponent(alpha),
            width: strokeWidth * widthScale
        )
    }

    // MARK: - Insertion

    /// Inserts the armed shape/line with the geometry the user dragged out.
    /// Points are in canvas (image pixel) coordinates.
    func completePendingInsertion(from start: CGPoint, to end: CGPoint) {
        guard let pending = pendingInsertion else { return }
        pendingInsertion = nil
        switch pending {
        case .shape(let shape):
            let frame = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: max(abs(end.x - start.x), 1),
                height: max(abs(end.y - start.y), 1)
            )
            insertShape(shape, frame: frame)
        case .line(let arrow):
            insertLine(from: start, to: end, arrow: arrow)
        }
    }

    func cancelPendingInsertion() {
        pendingInsertion = nil
    }

    private func insertShape(_ shape: ShapeConfiguration.Shape, frame: CGRect) {
        mutateMarkup { markup, _ in
            let configuration = ShapeConfiguration(
                type: shape,
                fillColor: nil,
                strokeColor: nsColor.cgColor,
                lineWidth: strokeWidth
            )
            markup.insertNewShape(configuration: configuration, frame: frame, rotation: 0)
        }
    }

    private func insertLine(from start: CGPoint, to end: CGPoint, arrow: Bool) {
        mutateMarkup { markup, _ in
            let configuration = ShapeConfiguration(
                type: .line,
                fillColor: nsColor.cgColor,
                strokeColor: nsColor.cgColor,
                lineWidth: strokeWidth
            )
            markup.insertNewLine(
                configuration: configuration,
                from: start,
                to: end,
                startMarker: false,
                endMarker: arrow
            )
        }
    }

    func insertTextbox() {
        mutateMarkup { markup, viewController in
            let fontSize = max(24, canvasBounds.width / 25)
            let text = NSAttributedString(
                string: "Text",
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
                    .foregroundColor: nsColor,
                ]
            )
            let frame = viewController.suggestedFrameForInserting(
                contentInFrame: CGRect(x: 0, y: 0, width: fontSize * 6, height: fontSize * 1.6)
            )
            markup.insertNewTextbox(attributedText: text, frame: frame, rotation: 0)
        }
    }

    /// Inserted markup lands selected-adjacent workflows: switch to select
    /// mode afterwards so the user can immediately move/resize it.
    private func mutateMarkup(_ mutate: (inout PaperMarkup, PaperMarkupViewController) -> Void) {
        guard let viewController, var markup = viewController.markup else { return }
        mutate(&markup, viewController)
        viewController.markup = markup
        tool = .select
    }

    // MARK: - Zoom

    /// Zoom-in headroom over fit — the upper bound `MarkupCanvasView` gives
    /// the canvas's `zoomRange` (fit is always the lower bound, so you can
    /// never zoom out past the whole image). Zooming and panning are
    /// gesture-only: pinch/scroll handled natively by the remote canvas.
    static let maxZoomOverFit: CGFloat = 8

    // MARK: - Crop

    /// Smallest allowed crop edge, in image pixels — rejects degenerate
    /// rects from a stray drag.
    static let minimumCropEdge: CGFloat = 32

    func beginCrop() {
        isCropActive = true
    }

    func cancelCrop() {
        isCropActive = false
    }

    /// Crops the screenshot to `rect` (canvas/image pixel coordinates,
    /// top-left origin — `CGImage.cropping` uses the same space). Existing
    /// markup is translated so annotations keep their place over the image
    /// and stay individually editable; anything left outside the new bounds
    /// is clipped at export by the context's edges.
    func applyCrop(to rect: CGRect) {
        isCropActive = false
        let clamped = rect.integral.intersection(canvasBounds)
        guard
            clamped.width >= Self.minimumCropEdge,
            clamped.height >= Self.minimumCropEdge,
            clamped != canvasBounds,
            let croppedImage = baseImage.cropping(to: clamped)
        else { return }

        baseImage = croppedImage
        canvasBounds = CGRect(origin: .zero, size: clamped.size)
        // MarkupCanvasView re-fits the viewport to the new bounds.
        visibleCanvasFrame = canvasBounds

        guard let viewController, var markup = viewController.markup else { return }
        markup.transformContent(CGAffineTransform(translationX: -clamped.minX, y: -clamped.minY))
        markup.bounds = canvasBounds
        viewController.markup = markup
    }

    // MARK: - Redaction

    /// Paints out `matches` and drops them from the review.
    ///
    /// Unlike an inserted shape, this replaces the base image's pixels
    /// (`Redactor`) — the covered text is gone from the document, not
    /// covered by an object that could be moved, deleted or missed by an
    /// export path. That's the difference between a redaction and a black
    /// rectangle, and the reason this lives here rather than going through
    /// `insertNewShape`.
    ///
    /// Not undoable, like crop: PaperKit's undo stack only covers user
    /// canvas edits, and an undo that could bring a credential back would be
    /// the wrong feature anyway.
    func redact(_ matches: [SensitiveMatch]) {
        guard !matches.isEmpty else { return }
        baseImage = Redactor.redacting(baseImage, rects: matches.map(\.rect))

        let redacted = Set(matches.map(\.id))
        pendingRedactions.removeAll { redacted.contains($0.id) }
    }

    /// Blacks out everything found and, when an upload is waiting on this
    /// review, sends it on with the redacted pixels.
    func redactAllPending() {
        redact(pendingRedactions)
        finishHeldUpload()
    }

    /// Leaves the flagged regions in place — the user has looked and decided
    /// they're fine. Any held upload stays held: "keep" is a statement about
    /// the image, not permission to send it.
    func dismissRedactionReview() {
        pendingRedactions = []
        continueHeldUpload = nil
    }

    /// "Upload Anyway": send the capture as it stands.
    func uploadHeldCaptureAsIs() {
        pendingRedactions = []
        finishHeldUpload()
    }

    /// Hands the held upload the canvas as it stands — flattened, so any
    /// markup made during the review goes with it, and over the redacted
    /// base image rather than the one that was flagged.
    private func finishHeldUpload() {
        guard let continueHeldUpload else { return }
        self.continueHeldUpload = nil
        Task {
            continueHeldUpload(await exportFlattened() ?? baseImage)
        }
    }

    // MARK: - Export

    /// Flattens the markup over the original screenshot at full pixel
    /// resolution. Returns the plain screenshot if there's no markup yet.
    func exportFlattened() async -> CGImage? {
        let width = baseImage.width
        let height = baseImage.height
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }

        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(baseImage, in: frame)
        if let markup = viewController?.markup {
            // Canvas coordinates are top-left origin (PaperKit is UIKit-based)
            // but `draw(in:frame:)` renders straight into the context's own
            // bottom-left-origin space — without this flip every annotation
            // lands mirrored about the image's horizontal centerline.
            context.saveGState()
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: 1, y: -1)
            await markup.draw(in: context, frame: frame)
            context.restoreGState()
        }
        return context.makeImage()
    }
}

/// Tracks the canvas's zoom/pan (pinch and scroll happen inside the remote
/// PaperKit process — this delegate is the only way to observe them).
extension MarkupCanvasController: @MainActor PaperMarkupViewController.Delegate {
    func paperMarkupViewControllerDidChangeContentVisibleFrame(_ paperMarkupViewController: PaperMarkupViewController) {
        // Pure observation: `visibleCanvasFrame` always mirrors what the
        // remote canvas actually shows (overlays map through it, so it must
        // be truthful even mid-resize). Keeping the *desired* zoom across
        // resizes is `MarkupCanvasView.Coordinator`'s job — verified
        // empirically (probe, 2026-07) that fighting it here loses: the
        // remote drops host→remote sets during live resizes and its own
        // reports are indistinguishable from user gestures.
        lastRemoteReport = paperMarkupViewController.contentVisibleFrame
        visibleCanvasFrame = paperMarkupViewController.contentVisibleFrame
        ZoomResizeProbe.log("delegate: observed \(visibleCanvasFrame.integral)")
    }

    func paperMarkupViewControllerDidChangeMarkup(_ paperMarkupViewController: PaperMarkupViewController) {}
    func paperMarkupViewControllerDidChangeSelection(_ paperMarkupViewController: PaperMarkupViewController) {}
    func paperMarkupViewControllerDidBeginDrawing(_ paperMarkupViewController: PaperMarkupViewController) {}
}

extension CGRect {
    /// Loose comparison in image pixels — remote round-trips aren't exact.
    /// Used by the viewport enforcement in `MarkupCanvasView.Coordinator`.
    func isApproximately(_ other: CGRect) -> Bool {
        let tolerance = Swift.max(1, other.width * 0.005)
        return abs(minX - other.minX) <= tolerance
            && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance
            && abs(height - other.height) <= tolerance
    }
}
