//
//  MarkupCanvasView.swift
//  QuickSnap
//

import AppKit
import PaperKit
import PencilKit
import SwiftUI

/// Hosts PaperKit's `PaperMarkupViewController` (the PencilKit-backed markup
/// canvas) in SwiftUI. The screenshot is the canvas's `contentView`
/// background.
///
/// Zoom is independent of the window: the canvas opens at actual size and
/// stays there, and `zoomRange` spans `MarkupCanvasController.minZoom`…
/// `maxZoom` about actual size — so you can zoom out well past fit and the
/// image floats in empty canvas. Resizing the window reveals more or less of
/// that canvas instead of rescaling its contents. Pinch/scroll zoom and pan
/// are handled natively by the remote PaperKit process; the toolbar's zoom
/// controls go through `MarkupCanvasController.setZoom`.
///
/// `PaperMarkupViewController` is `public` but not `open`, so this can't be
/// done by overriding `viewDidLayout()` in a subclass — the coordinator
/// listens for the view's frame-change notifications instead.
struct MarkupCanvasView: NSViewControllerRepresentable {
    @ObservedObject var controller: MarkupCanvasController

    func makeNSViewController(context: Context) -> PaperMarkupViewController {
        let markup = PaperMarkup(bounds: controller.canvasBounds)
        let viewController = PaperMarkupViewController(markup: markup, supportedFeatureSet: .latest)

        let imageView = HitTestTransparentImageView(frame: controller.canvasBounds)
        imageView.image = NSImage(
            cgImage: controller.baseImage,
            size: controller.canvasBounds.size
        )
        imageView.imageScaling = .scaleAxesIndependently
        viewController.contentView = imageView
        viewController.isEditable = true
        viewController.delegate = controller

        controller.viewController = viewController

        context.coordinator.imageView = imageView
        context.coordinator.appliedImage = controller.baseImage

        viewController.view.postsFrameChangedNotifications = true
        context.coordinator.observeViewportEvents(of: viewController, controller: controller)

        return viewController
    }

    func updateNSViewController(_ viewController: PaperMarkupViewController, context: Context) {
        context.coordinator.applyBaseImage(controller.baseImage, controller: controller, to: viewController)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        private var observations: [any NSObjectProtocol] = []
        /// The viewport is only positioned once, when the view first gets a
        /// real size: from then on zoom belongs to the user (and to the
        /// remote canvas, which holds scale across a resize by itself).
        /// Set when the user grabs a window edge: from that moment the
        /// window's size is theirs and the viewport is left alone.
        private var userIsResizingWindow = false {
            didSet { if userIsResizingWindow { initialPlacementTask?.cancel() } }
        }
        /// Drives the opening viewport until the remote confirms it — see
        /// `placeInitialViewport`.
        private var initialPlacementTask: Task<Void, Never>?
        weak var imageView: NSImageView?
        var appliedImage: CGImage?
        /// The canvas bounds the current image was applied at — how a crop
        /// (bounds changed) is told apart from a redaction (same bounds).
        private var appliedBounds: CGRect?

        func observeViewportEvents(of viewController: PaperMarkupViewController, controller: MarkupCanvasController) {
            // Reads canvasBounds from the controller at notification time
            // (not captured) — a crop changes it after this observer is set up.
            observations.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: viewController.view,
                queue: .main
            ) { [weak self, weak viewController, weak controller] _ in
                MainActor.assumeIsolated {
                    guard let self, let viewController, let controller else { return }
                    self.viewDidResize(viewController, controller: controller)
                }
            })
            // The window doesn't exist yet at setup time, so this registers
            // unfiltered and matches the window at fire time.
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willStartLiveResizeNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak viewController] notification in
                MainActor.assumeIsolated {
                    guard let self, let viewController,
                        let window = viewController.view.window,
                        (notification.object as? NSWindow) === window else { return }
                    self.userIsResizingWindow = true
                }
            })
        }

        /// The canvas view got a new size — a step of the window's initial
        /// layout, or a resize.
        ///
        /// Once the window belongs to the user, deliberately almost nothing
        /// happens here: holding absolute scale across a viewport resize is
        /// the remote canvas's *own* default behaviour, and the
        /// verify-and-retry enforcement this replaced existed solely to
        /// fight that default back into fit-tracking. Everything that made
        /// that fragile (the remote dropping host sets mid-drag, resuming at
        /// an unknowable moment, reports indistinguishable from gestures)
        /// only mattered because the host had an opinion about zoom.
        ///
        /// Before then it re-places the viewport at actual size on **every**
        /// layout step, rather than once at first layout. A one-shot placed
        /// it at whatever transient size the hosting view happened to have
        /// mid-layout, and because the remote then holds that scale as the
        /// window settles, windows opened at 200 % (measured — the size at
        /// first notification is not the size the window ends up).
        private func viewDidResize(_ viewController: PaperMarkupViewController, controller: MarkupCanvasController) {
            guard viewController.view.bounds.width > 1, controller.canvasBounds.width > 0 else { return }
            viewController.zoomRange = controller.canvasScaleRange
            guard !userIsResizingWindow, !controller.hasUserAdjustedZoom else { return }
            placeInitialViewport(of: viewController, controller: controller)
        }

        /// Drives the opening viewport to actual size, re-sending until the
        /// remote *reports* it landed.
        ///
        /// A one-shot set is not enough, in two different ways, both
        /// measured: sent during the window's first layout it lands at a
        /// transient view size the window then grows out of, and sent before
        /// the remote canvas is ready it is silently dropped altogether,
        /// leaving the canvas at the remote's own default scale (1 point per
        /// image pixel — 200 % on a retina capture). Verification is against
        /// `lastRemoteReport`, never `visibleCanvasFrame`, whose initial
        /// value is a local assumption that would "converge" instantly.
        ///
        /// This is the one survivor of the enforcement machinery the free
        /// zoom design deleted, and it's bounded: it stops on its own once
        /// the viewport is confirmed, and the moment the user grabs an edge
        /// or touches a zoom control it is cancelled and never runs again.
        private func placeInitialViewport(of viewController: PaperMarkupViewController, controller: MarkupCanvasController) {
            initialPlacementTask?.cancel()
            initialPlacementTask = Task { [weak viewController, weak controller] in
                let deadline = Date(timeIntervalSinceNow: 4)
                while !Task.isCancelled, Date() < deadline {
                    guard let viewController, let controller,
                        !controller.hasUserAdjustedZoom, !self.userIsResizingWindow
                    else { return }
                    let target = controller.visibleFrame(forZoom: MarkupCanvasController.defaultZoom)
                    if let observed = controller.lastRemoteReport, observed.isApproximately(target) {
                        ProbeCanvas.log("initial viewport: landed at \(observed.integral)")
                        return
                    }
                    viewController.zoomRange = controller.canvasScaleRange
                    controller.setZoom(MarkupCanvasController.defaultZoom, animated: false, userInitiated: false)
                    ProbeCanvas.log("initial viewport: sent \(target.integral), observed \(controller.lastRemoteReport?.integral.debugDescription ?? "none")")
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }

        /// Swaps the canvas's background to a new (cropped or redacted) base
        /// image. The viewport is left where the user had it either way: a
        /// crop no longer re-fits, because fit is no longer where the canvas
        /// lives, and re-fitting after a redaction would yank them out of
        /// whatever they had zoomed in to read.
        func applyBaseImage(_ image: CGImage, controller: MarkupCanvasController, to viewController: PaperMarkupViewController) {
            guard image !== appliedImage else { return }
            let bounds = controller.canvasBounds
            appliedImage = image
            appliedBounds = bounds
            imageView?.image = NSImage(cgImage: image, size: bounds.size)
            imageView?.frame = bounds
        }

        deinit {
            initialPlacementTask?.cancel()
            for observation in observations {
                NotificationCenter.default.removeObserver(observation)
            }
        }
    }
}

/// `NSImageView` is hit-testable by default — unlike `UIImageView` on iOS
/// (`isUserInteractionEnabled = false`), which is what PaperKit's
/// contentView-as-background pattern was designed around. Left as a plain
/// `NSImageView`, the background image swallows every mouse event before
/// the canvas's input surface sees it, silently killing drawing and
/// selection while programmatic markup (insertion, export) keeps working.
private final class HitTestTransparentImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
