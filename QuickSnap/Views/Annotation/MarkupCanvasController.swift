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
    /// — a sub-rect of `canvasBounds` when zoomed in, and *larger* than it
    /// (with a negative origin) when zoomed out past fit, which is now
    /// allowed. Updated from the PaperKit delegate; overlays use it to map
    /// view points to canvas pixels regardless of zoom/pan, and that
    /// mapping — origin offset plus uniform scale — holds either way.
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
        didSet {
            applyTool()
            currentSnapshot = snapshot()
        }
    }

    // MARK: - Undo history

    /// One point in the edit history. Everything a step can change is in
    /// here, so restoring is a single assignment of all three — in
    /// particular a crop, which moves the markup *and* replaces the image,
    /// and would otherwise leave restored annotations in the wrong
    /// coordinate space.
    ///
    /// `PaperMarkup` is a value type, so a snapshot is just the value; the
    /// image is a reference, but `CGImage` is immutable and crops/redactions
    /// always produce a new one, so holding it is enough.
    private struct CanvasSnapshot {
        let markup: PaperMarkup?
        let baseImage: CGImage
        let canvasBounds: CGRect
    }

    /// Steps behind and ahead of where the canvas is now.
    private var undoStack: [CanvasSnapshot] = []
    private var redoStack: [CanvasSnapshot] = []
    /// Where the canvas is now — pushed onto one stack when the other is
    /// popped, and the thing every recorded step is measured against.
    private var currentSnapshot: CanvasSnapshot?

    /// True while *we* are assigning markup, so the change report that comes
    /// back from that assignment isn't recorded as a new user edit (verified
    /// with the probe: a host assignment re-enters the delegate exactly
    /// once). Cleared on the next main-queue turn rather than straight after
    /// the assignment, because the report can arrive either way round.
    private var isApplyingSnapshot = false

    /// A screenshot markup session is short and the snapshots are small
    /// (a serialized stroke is on the order of a kilobyte), but the base
    /// image isn't — cap the history so a long crop-heavy session can't
    /// accumulate an unbounded number of full-size images.
    private static let undoHistoryLimit = 50

    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private func snapshot() -> CanvasSnapshot {
        CanvasSnapshot(
            markup: viewController?.markup,
            baseImage: baseImage,
            canvasBounds: canvasBounds
        )
    }

    /// A change the *user* made on the canvas (a stroke, a move, a delete)
    /// has just been reported: the state before it is what an undo goes back
    /// to. Doing something new drops the redo branch, as everywhere else.
    ///
    /// The canvas reports exactly one change per stroke (verified with the
    /// probe), so this needs no coalescing — one report is one undo step.
    private func recordUserEdit() {
        guard let previous = currentSnapshot else {
            currentSnapshot = snapshot()
            return
        }
        let current = snapshot()
        currentSnapshot = current
        // The canvas reports a change once when it first attaches, which
        // isn't an edit and would leave a new window offering to undo
        // nothing (measured — it arrived before the first stroke and left
        // Undo enabled on an untouched capture). A report that has no drawn
        // content on either side of it can't be a user edit worth keeping:
        // erasing the last markup still has content in `previous`, so it
        // records normally.
        guard hasDrawnContent(previous.markup) || hasDrawnContent(current.markup) else { return }
        push(previous)
    }

    private func hasDrawnContent(_ markup: PaperMarkup?) -> Bool {
        guard let frame = markup?.contentsRenderFrame else { return false }
        return !frame.isNull && !frame.isEmpty
    }

    /// Runs a host-side edit (an insertion, a crop) as one undo step.
    ///
    /// These assign `markup` themselves, which re-enters the change delegate
    /// — hence the suppression: without it the same edit would be recorded
    /// twice, once here and once from its own echo.
    private func recordingUndoStep(_ mutate: () -> Void) {
        let previous = currentSnapshot ?? snapshot()
        isApplyingSnapshot = true
        mutate()
        push(previous)
        currentSnapshot = snapshot()
        clearSnapshotSuppression()
    }

    private func push(_ snapshot: CanvasSnapshot) {
        undoStack.append(snapshot)
        if undoStack.count > Self.undoHistoryLimit {
            undoStack.removeFirst(undoStack.count - Self.undoHistoryLimit)
        }
        redoStack.removeAll()
        updateUndoAvailability()
    }

    /// The change report from our own assignment can arrive during the call
    /// or on the next main-queue turn, so the flag has to outlive the
    /// statement that set it.
    private func clearSnapshotSuppression() {
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingSnapshot = false
        }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot ?? snapshot())
        apply(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot ?? snapshot())
        apply(next)
    }

    /// Puts a snapshot back. Assigning `markup` is what restores annotations
    /// (verified with the probe: the canvas takes the old value and stays
    /// editable); the image and bounds are published, so a crop being undone
    /// flows out to the canvas view and the window's aspect lock the same
    /// way applying the crop did.
    private func apply(_ snapshot: CanvasSnapshot) {
        pendingInsertion = nil
        isCropActive = false

        isApplyingSnapshot = true
        if snapshot.baseImage !== baseImage {
            baseImage = snapshot.baseImage
        }
        if snapshot.canvasBounds != canvasBounds {
            canvasBounds = snapshot.canvasBounds
            visibleCanvasFrame = snapshot.canvasBounds
        }
        viewController?.markup = snapshot.markup
        currentSnapshot = snapshot
        clearSnapshotSuppression()
        updateUndoAvailability()
    }

    /// Drops the history outright. Used by redaction: the snapshots behind
    /// it hold the *unredacted* image, so an undo would put the credential
    /// back on screen — see `redact`.
    private func clearUndoHistory() {
        undoStack.removeAll()
        redoStack.removeAll()
        currentSnapshot = snapshot()
        updateUndoAvailability()
    }

    private func updateUndoAvailability() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
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

        if ProbeCanvas.isAnyProbeEnabled {
            ProbeCanvas.current = self
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
    ///
    /// Recorded as one undo step — insertions used to be the exception that
    /// couldn't be taken back, which stopped being acceptable once there was
    /// an undo to take them back with.
    private func mutateMarkup(_ mutate: (inout PaperMarkup, PaperMarkupViewController) -> Void) {
        guard let viewController, var markup = viewController.markup else { return }
        recordingUndoStep {
            mutate(&markup, viewController)
            viewController.markup = markup
        }
        tool = .select
    }

    // MARK: - Zoom

    /// Zoom is a fraction of the capture's **actual size**: 1 means one
    /// image pixel per device pixel — how big the thing was on screen when
    /// it was captured. Windows open there and stay there; resizing the
    /// window reveals more or less of the canvas rather than rescaling it,
    /// like a Figma canvas and unlike the fit-to-frame preview this
    /// replaced.
    static let minZoom: CGFloat = 0.1
    static let maxZoom: CGFloat = 8
    static let defaultZoom: CGFloat = 1
    /// One press of zoom in / zoom out. Multiplicative, because zoom is
    /// perceived in ratios.
    static let zoomStep: CGFloat = 1.5

    /// Image pixels per point. A retina capture carries two pixels per
    /// point, so showing it at actual size means half a point per pixel —
    /// without this a 2× capture would open twice as large as the thing it
    /// is a picture of.
    var backingScale: CGFloat {
        viewController?.view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    /// What the canvas's `zoomRange` should be, in PaperKit's units (points
    /// per image pixel) rather than ours.
    var canvasScaleRange: ClosedRange<CGFloat> {
        (Self.minZoom / backingScale)...(Self.maxZoom / backingScale)
    }

    /// Current zoom as a fraction of actual size. Derived from the published
    /// viewport, so views tracking it update on every pinch and scroll.
    var zoom: CGFloat {
        guard let view = viewController?.view, visibleCanvasFrame.width > 0 else { return Self.defaultZoom }
        return view.bounds.width / visibleCanvasFrame.width * backingScale
    }

    /// The zoom at which the whole capture is visible. Not a floor any more
    /// — just where the "Fit" control goes.
    var fitZoom: CGFloat {
        guard
            let view = viewController?.view,
            canvasBounds.width > 0, canvasBounds.height > 0,
            view.bounds.width > 1, view.bounds.height > 1
        else { return Self.defaultZoom }
        return min(
            view.bounds.width / canvasBounds.width,
            view.bounds.height / canvasBounds.height
        ) * backingScale
    }

    var canZoomIn: Bool { zoom < Self.maxZoom - 0.001 }
    var canZoomOut: Bool { zoom > Self.minZoom + 0.001 }

    func zoomIn() { setZoom(zoom * Self.zoomStep) }
    func zoomOut() { setZoom(zoom / Self.zoomStep) }
    func zoomToActualSize() { setZoom(Self.defaultZoom) }
    func zoomToFit() { setZoom(fitZoom) }

    /// Zooms about the middle of what's on screen, which is what every
    /// keyboard/button zoom in every editor does — pinch zoom is the
    /// remote's own business and anchors on the gesture instead.
    ///
    /// Note the canvas will not honour a *pan* while zoomed out past fit:
    /// with the image smaller than the viewport the remote re-centres it and
    /// drops the offset (measured, `Probe/FreeZoomProbe.swift`). Zoomed in,
    /// panning works normally.
    /// Set once the user has expressed an opinion about zoom, which is what
    /// stops `MarkupCanvasView` re-placing the viewport at actual size while
    /// the window is still laying itself out.
    private(set) var hasUserAdjustedZoom = false

    func setZoom(_ zoom: CGFloat, animated: Bool = true, userInitiated: Bool = true) {
        guard let viewController, viewController.view.bounds.width > 1 else { return }
        if userInitiated { hasUserAdjustedZoom = true }
        viewController.zoomRange = canvasScaleRange
        viewController.setContentVisibleFrame(visibleFrame(forZoom: zoom), animated: animated)
    }

    /// The canvas region a given zoom puts in the viewport, centred on
    /// what's on screen now. Separate from `setZoom` so the opening
    /// placement can *verify* against the same rect it asked for.
    func visibleFrame(forZoom zoom: CGFloat) -> CGRect {
        guard let viewController, viewController.view.bounds.width > 1 else { return visibleCanvasFrame }
        let clamped = min(max(zoom, Self.minZoom), Self.maxZoom)
        let scale = clamped / backingScale
        let size = CGSize(
            width: viewController.view.bounds.width / scale,
            height: viewController.view.bounds.height / scale
        )
        // Opening centres on the capture; later zooms centre on whatever the
        // user is looking at.
        let center = hasUserAdjustedZoom
            ? CGPoint(x: visibleCanvasFrame.midX, y: visibleCanvasFrame.midY)
            : CGPoint(x: canvasBounds.midX, y: canvasBounds.midY)
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

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

        // One step: the image, the bounds and the shifted markup go back
        // together or not at all — restoring markup laid out for the cropped
        // image over the uncropped one would put every annotation in the
        // wrong place.
        recordingUndoStep {
            baseImage = croppedImage
            canvasBounds = CGRect(origin: .zero, size: clamped.size)
            // MarkupCanvasView re-fits the viewport to the new bounds.
            visibleCanvasFrame = canvasBounds

            guard let viewController, var markup = viewController.markup else { return }
            markup.transformContent(CGAffineTransform(translationX: -clamped.minX, y: -clamped.minY))
            markup.bounds = canvasBounds
            viewController.markup = markup
        }
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
    /// Deliberately **not** undoable, and it takes the history with it: every
    /// snapshot behind this point holds the pre-redaction image, so a later
    /// undo would put the credential back on screen — and then into whatever
    /// the user exports next. An undo that can un-redact is the wrong
    /// feature; losing the earlier steps is the price, and redaction is
    /// normally the last thing done before sending the capture out anyway.
    func redact(_ matches: [SensitiveMatch]) {
        guard !matches.isEmpty else { return }
        baseImage = Redactor.redacting(baseImage, rects: matches.map(\.rect))

        let redacted = Set(matches.map(\.id))
        pendingRedactions.removeAll { redacted.contains($0.id) }
        clearUndoHistory()
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
        ProbeCanvas.log("delegate: observed \(visibleCanvasFrame.integral)")
    }

    /// The only signal a user canvas edit (stroke, move, delete) ever gives
    /// the host — PaperKit exposes no undo of its own, so this is what the
    /// history is built from. Our own assignments echo back through here
    /// too, which `isApplyingSnapshot` filters out.
    func paperMarkupViewControllerDidChangeMarkup(_ paperMarkupViewController: PaperMarkupViewController) {
        UndoProbe.noteMarkupChanged()
        guard !isApplyingSnapshot else { return }
        recordUserEdit()
    }
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
