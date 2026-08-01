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
/// background. Fit is the zoom floor (`zoomRange` = fit…fit × headroom), so
/// you can never zoom out past the whole image; pinch/scroll zoom and pan
/// are handled natively by the remote PaperKit process (gesture-only, no
/// toolbar zoom UI). The Coordinator preserves the relative zoom across
/// window resizes via verify-and-retry enforcement — see `enforceViewport`.
///
/// `PaperMarkupViewController` is `public` but not `open`, so fit-tracking
/// can't be done by overriding `viewDidLayout()` in a subclass — the
/// coordinator listens for the view's frame-change notifications instead.
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
        private var appliedFitZoom: CGFloat = 0
        /// Non-nil while a live window resize is in progress: the visible
        /// canvas region captured when the resize started (before any size
        /// change), restored by enforcement when the resize ends.
        private var liveResizeTarget: CGRect?
        /// The verify-and-retry loop driving the viewport to a target
        /// region — see `enforceViewport`.
        private var enforcementTask: Task<Void, Never>?
        private var enforcementTarget: CGRect?
        weak var imageView: NSImageView?
        var appliedImage: CGImage?
        /// The canvas bounds the current image was applied at — how a crop
        /// (bounds changed, re-fit) is told apart from a redaction (same
        /// bounds, leave the viewport alone).
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
                    self.updateZoomBounds(of: viewController, controller: controller)
                }
            })
            // The window doesn't exist yet at setup time, so both live-resize
            // observers register unfiltered and match the window at fire time.
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willStartLiveResizeNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak viewController, weak controller] notification in
                MainActor.assumeIsolated {
                    guard let self, let viewController, let controller,
                        let window = viewController.view.window,
                        (notification.object as? NSWindow) === window else { return }
                    self.beginLiveResize(controller: controller)
                }
            })
            observations.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: nil,
                queue: .main
            ) { [weak self, weak viewController, weak controller] notification in
                MainActor.assumeIsolated {
                    guard let self, let viewController, let controller,
                        let window = viewController.view.window,
                        (notification.object as? NSWindow) === window else { return }
                    self.endLiveResize(of: viewController, controller: controller)
                }
            })
        }

        /// The user grabbed a window edge (sent *before* any size change,
        /// so the observed region is still trustworthy): capture the region
        /// to restore. During the drag the remote canvas freezes its zoom
        /// and drops every host→remote set (verified empirically with the
        /// probe, 2026-07 — pinned zoom ranges and one-shot frame sets were
        /// both silently ignored), so nothing useful can be done until the
        /// drag ends; `endLiveResize` then enforces the captured region.
        private func beginLiveResize(controller: MarkupCanvasController) {
            // If an enforcement is mid-flight (e.g. post-crop), its target
            // is the intent — the observed region may still be drifted.
            liveResizeTarget = enforcementTarget ?? controller.visibleCanvasFrame
            cancelEnforcement()
            ZoomResizeProbe.log("liveResize BEGIN: captured target=\(liveResizeTarget!.integral)")
        }

        private func endLiveResize(of viewController: PaperMarkupViewController, controller: MarkupCanvasController) {
            guard let target = liveResizeTarget else { return }
            liveResizeTarget = nil
            ZoomResizeProbe.log("liveResize END: enforcing target=\(target.integral)")
            enforceViewport(target, of: viewController, controller: controller)
        }

        /// Drives the remote canvas to show `target`, verifying and
        /// retrying: sets are re-sent (zoom range first — a stale range
        /// silently clamps frame sets into no-ops) until the *observed*
        /// `visibleCanvasFrame` matches. One-shot sets are not reliable:
        /// the remote drops host→remote sync during live resizes and
        /// resumes at an unknowable moment, so the only dependable pattern
        /// is retry-until-verified. Bounded by a deadline in case the
        /// target is genuinely unsatisfiable; cancelled by a new
        /// enforcement or an incoming live resize.
        private func enforceViewport(_ target: CGRect, of viewController: PaperMarkupViewController, controller: MarkupCanvasController) {
            cancelEnforcement()
            let canvas = controller.canvasBounds
            guard canvas.width > 0, canvas.height > 0 else { return }
            let size = CGSize(width: min(target.width, canvas.width), height: min(target.height, canvas.height))
            let clamped = CGRect(
                x: min(max(target.minX, 0), canvas.width - size.width),
                y: min(max(target.minY, 0), canvas.height - size.height),
                width: size.width,
                height: size.height
            )
            enforcementTarget = clamped
            enforcementTask = Task { [weak self, weak viewController, weak controller] in
                // The remote resumes accepting host sets at an unknowable
                // moment — measured ~0.4 s after growing drags but ~1.3 s+
                // after shrinking ones (probe, 2026-07) — so the deadline
                // must comfortably outlast the slow case.
                let deadline = Date(timeIntervalSinceNow: 4)
                while !Task.isCancelled, Date() < deadline {
                    guard let viewController, let controller else { return }
                    // Verify against what the remote actually reported —
                    // never `visibleCanvasFrame`, whose initial value is a
                    // local assumption (see `lastRemoteReport`).
                    if let observed = controller.lastRemoteReport, observed.isApproximately(clamped) {
                        ZoomResizeProbe.log("enforce: converged at \(observed.integral)")
                        self?.enforcementTarget = nil
                        return
                    }
                    let viewWidth = viewController.view.bounds.width
                    if viewWidth > 1 {
                        let fitZoom = viewWidth / controller.canvasBounds.width
                        viewController.zoomRange = fitZoom...(fitZoom * MarkupCanvasController.maxZoomOverFit)
                    }
                    viewController.setContentVisibleFrame(clamped, animated: false)
                    ZoomResizeProbe.log("enforce: sent target=\(clamped.integral) observed=\(controller.lastRemoteReport?.integral.debugDescription ?? "none")")
                    try? await Task.sleep(for: .milliseconds(80))
                }
                ZoomResizeProbe.log("enforce: ended without convergence (cancelled=\(Task.isCancelled))")
                self?.enforcementTarget = nil
            }
        }

        private func cancelEnforcement() {
            enforcementTask?.cancel()
            enforcementTask = nil
            enforcementTarget = nil
        }

        /// Swaps the canvas's background to a new (cropped) base image: the
        /// image view gets the new image and frame, and an enforcement
        /// drives the viewport to fit the new canvas bounds — it keeps
        /// running through the window's animated resize to the new aspect
        /// ratio (those frame-change steps see it active and stand back).
        func applyBaseImage(_ image: CGImage, controller: MarkupCanvasController, to viewController: PaperMarkupViewController) {
            guard image !== appliedImage else { return }
            let bounds = controller.canvasBounds
            let boundsChanged = appliedBounds != bounds
            appliedImage = image
            appliedBounds = bounds
            imageView?.image = NSImage(cgImage: image, size: bounds.size)
            imageView?.frame = bounds

            // A crop changes the canvas, so the viewport has to be re-fitted.
            // A redaction replaces the same-sized pixels, and re-fitting
            // there would yank the user out of wherever they had zoomed to
            // in order to read what they were redacting.
            guard boundsChanged else { return }
            appliedFitZoom = 0
            ZoomResizeProbe.log("applyBaseImage: enforcing fit of new canvas \(bounds.size)")
            enforceViewport(bounds, of: viewController, controller: controller)
        }

        /// Viewport frame changed, preserving the *relative* zoom (the
        /// remote's own behavior keeps absolute scale, which silently
        /// changes the effective zoom as the window shrinks).
        ///
        /// During a live resize nothing is sent — the remote drops all
        /// host→remote sets until the drag ends (`endLiveResize` restores
        /// the captured region then). Programmatic resizes (initial
        /// layout, post-crop window animation, title-bar zoom button)
        /// start an enforcement toward the pre-change region; steps of an
        /// ongoing animation don't restart it (the first step's target is
        /// the intent — later observed regions may already be drifted).
        private func updateZoomBounds(of viewController: PaperMarkupViewController, controller: MarkupCanvasController) {
            let canvasBounds = controller.canvasBounds
            let viewWidth = viewController.view.bounds.width
            guard viewWidth > 1, canvasBounds.width > 0 else { return }
            let fitZoom = viewWidth / canvasBounds.width
            guard abs(fitZoom - appliedFitZoom) > 0.001 else { return }
            let isFirstLayout = appliedFitZoom == 0
            appliedFitZoom = fitZoom

            if liveResizeTarget != nil {
                ZoomResizeProbe.log("frameChange (live resize): viewWidth=\(viewWidth) fit=\(fitZoom) — deferred to endLiveResize")
                return
            }
            if enforcementTarget != nil {
                ZoomResizeProbe.log("frameChange (enforcing): viewWidth=\(viewWidth) fit=\(fitZoom) — enforcement continues")
                return
            }
            let target = isFirstLayout ? canvasBounds : controller.visibleCanvasFrame
            ZoomResizeProbe.log("frameChange: viewWidth=\(viewWidth) fit=\(fitZoom) firstLayout=\(isFirstLayout) enforcing=\(target.integral)")
            enforceViewport(target, of: viewController, controller: controller)
        }

        deinit {
            enforcementTask?.cancel()
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
