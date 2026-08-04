//
//  FreeZoomProbe.swift
//  QuickSnap
//
//  TEMPORARY diagnostic harness — inert unless launched with
//  QUICKSNAP_FREEZOOM_PROBE=1. The annotation window's whole viewport design
//  assumes fit is the zoom floor (`zoomRange` starts at fit, the window is
//  aspect-locked to the image). Decoupling zoom from window size needs the
//  opposite, so this measures whether the remote canvas will actually do it:
//
//    1. Does `zoomRange` accept a lower bound below fit?
//    2. Does `setContentVisibleFrame` accept a region *larger* than the
//       canvas bounds — i.e. the image smaller than the viewport — or does
//       the remote clamp it back to the content?
//    3. Can the visible region be panned while zoomed out past fit (origin
//       outside the canvas bounds)?
//    4. Does the remote hold absolute scale across a window resize on its
//       own, with no host enforcement? (That is exactly the behaviour the
//       new design wants, and the behaviour the current one fights.)
//
//  Prints PASS/FAIL per question, then terminates.
//

import AppKit
import ApplicationServices
import CoreGraphics
import PaperKit

@MainActor
enum FreeZoomProbe {
    static let isEnabled = ProcessInfo.processInfo.environment["QUICKSNAP_FREEZOOM_PROBE"] == "1"

    private static let startTime = Date()
    private static var failures = 0

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let elapsed = String(format: "%8.3f", Date().timeIntervalSince(startTime))
        print("[freezoom \(elapsed)] \(message())")
        fflush(stdout)
    }

    private static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        log("\(passed ? "PASS" : "FAIL") \(name)")
    }

    static func startIfEnabled(annotationCoordinator: AnnotationCoordinator) {
        guard isEnabled else { return }
        Task { await run(annotationCoordinator: annotationCoordinator) }
    }

    private static func run(annotationCoordinator: AnnotationCoordinator) async {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("accessibility trusted: \(trusted)")

        annotationCoordinator.openAnnotationWindow(
            image: makeSyntheticImage(width: 1600, height: 1000),
            file: CaptureFile()
        )
        // Long settle: the existing viewport enforcement runs on first
        // layout and must be finished before anything here is measured,
        // or it will fight every set below.
        try? await Task.sleep(for: .seconds(3))

        guard let canvas = ProbeCanvas.current,
            let window = NSApp.windows.first(where: { $0.delegate === annotationCoordinator }),
            let viewController = canvas.viewController
        else {
            log("ABORT: annotation window or canvas controller not found")
            return terminate()
        }

        let bounds = canvas.canvasBounds
        log("canvas=\(bounds.size) view=\(viewController.view.bounds.size) backingScale=\(canvas.backingScale) zoom=\(percent(canvas.zoom))")

        // --- 1: windows open at actual size, not fit ---
        check("1: opens at 100%", abs(canvas.zoom - 1) < 0.05)

        // --- 2: window size and zoom are independent ---
        // The whole point of the change: resizing reveals more or less of
        // the canvas, it does not rescale the capture.
        guard trusted else {
            log("SKIP the rest: needs Accessibility for the resize drags")
            return finish()
        }
        let zoomBeforeShrink = canvas.zoom
        let visibleBeforeShrink = canvas.visibleCanvasFrame
        await dragRightEdge(of: window, byX: -260)
        try? await Task.sleep(for: .seconds(2.5))
        check("2: shrinking the window leaves zoom alone", abs(canvas.zoom - zoomBeforeShrink) / zoomBeforeShrink < 0.05)
        check("2b: …and reveals less of the canvas", canvas.visibleCanvasFrame.width < visibleBeforeShrink.width * 0.95)
        log("   zoom \(percent(zoomBeforeShrink)) → \(percent(canvas.zoom)), visible \(visibleBeforeShrink.integral) → \(canvas.visibleCanvasFrame.integral)")

        let zoomBeforeGrow = canvas.zoom
        await dragRightEdge(of: window, byX: 320)
        try? await Task.sleep(for: .seconds(2.5))
        check("3: growing the window leaves zoom alone", abs(canvas.zoom - zoomBeforeGrow) / zoomBeforeGrow < 0.05)
        log("   zoom \(percent(zoomBeforeGrow)) → \(percent(canvas.zoom)), visible \(canvas.visibleCanvasFrame.integral)")

        // --- 4: zoom out well past fit, so the image floats in space ---
        canvas.setZoom(MarkupCanvasController.minZoom, animated: false)
        try? await Task.sleep(for: .seconds(1.2))
        check("4: can zoom out to the floor, past fit", canvas.zoom < canvas.fitZoom * 0.9)
        check("4b: …and the viewport is then larger than the image", canvas.visibleCanvasFrame.width > bounds.width)
        log("   zoom=\(percent(canvas.zoom)) fit=\(percent(canvas.fitZoom)) visible=\(canvas.visibleCanvasFrame.integral) canvas=\(bounds.size)")

        // --- 5: the ceiling holds ---
        canvas.setZoom(MarkupCanvasController.maxZoom * 4, animated: false)
        try? await Task.sleep(for: .seconds(1.2))
        check("5: zoom is clamped at the ceiling", canvas.zoom <= MarkupCanvasController.maxZoom * 1.05)
        log("   zoom=\(percent(canvas.zoom)) (asked for \(percent(MarkupCanvasController.maxZoom * 4)))")

        // --- 6: fit and actual size land where they say ---
        canvas.zoomToFit()
        try? await Task.sleep(for: .seconds(1.2))
        check("6: zoom to fit shows the whole capture", canvas.visibleCanvasFrame.width >= bounds.width * 0.98)
        canvas.zoomToActualSize()
        try? await Task.sleep(for: .seconds(1.2))
        check("6b: actual size returns to 100%", abs(canvas.zoom - 1) < 0.05)

        // --- 7: a crop no longer moves the window ---
        let frameBeforeCrop = window.frame
        canvas.applyCrop(to: CGRect(x: 200, y: 100, width: 900, height: 800))
        try? await Task.sleep(for: .seconds(2))
        check("7: cropping doesn't resize the window", window.frame.size == frameBeforeCrop.size)
        log("   window=\(window.frame.size) canvas=\(canvas.canvasBounds.size) zoom=\(percent(canvas.zoom))")

        // --- 8: would padding the canvas out restore panning below fit? ---
        // The remote refuses to pan when the *content* is smaller than the
        // viewport. If that's genuinely about content size, giving the
        // markup bounds bigger than the image should restore panning — and
        // decide whether a Figma-style free pan is worth the coordinate-space
        // refactor it would cost.
        canvas.setZoom(0.5, animated: false)
        try? await Task.sleep(for: .seconds(1))
        let imageBounds = canvas.canvasBounds
        // Sized against the *viewport*, not the image: the centring rule is
        // about content vs viewport, so the padded canvas has to comfortably
        // exceed what's on screen for the test to mean anything.
        let viewport = canvas.visibleCanvasFrame
        let padded = CGRect(
            x: imageBounds.midX - viewport.width,
            y: imageBounds.midY - viewport.height,
            width: viewport.width * 2,
            height: viewport.height * 2
        )
        if var markup = viewController.markup {
            markup.bounds = padded
            viewController.markup = markup
        }
        try? await Task.sleep(for: .seconds(1))
        let visible = canvas.visibleCanvasFrame
        log("   padded bounds=\(padded.integral) viewport=\(visible.integral) (viewport \(visible.width < padded.width ? "fits inside" : "exceeds") the padded canvas)")

        let panTarget = visible.offsetBy(dx: 300, dy: 0)
        viewController.setContentVisibleFrame(panTarget, animated: false)
        try? await Task.sleep(for: .seconds(1))
        let afterPan = canvas.visibleCanvasFrame
        check("8: padding the canvas restores panning below fit", abs(afterPan.minX - visible.minX) > 100)
        log("   requested=\(panTarget.integral) observed=\(afterPan.integral)")

        finish()
    }

    private static func finish() {
        log(failures == 0 ? "SUMMARY: ALL PASS" : "SUMMARY: \(failures) FAILURE(S)")
        terminate()
    }

    private static func percent(_ zoom: CGFloat) -> String {
        String(format: "%.0f%%", zoom * 100)
    }

    private static func dragRightEdge(of window: NSWindow, byX deltaX: CGFloat) async {
        let start = CGPoint(x: window.frame.maxX - 2, y: window.frame.midY)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgStart = CGPoint(x: start.x, y: primaryHeight - start.y)
        post(.leftMouseDown, at: cgStart)
        for step in 1...10 {
            let progress = CGFloat(step) / 10
            post(.leftMouseDragged, at: CGPoint(x: cgStart.x + deltaX * progress, y: cgStart.y))
            try? await Task.sleep(for: .milliseconds(16))
        }
        post(.leftMouseUp, at: CGPoint(x: cgStart.x + deltaX, y: cgStart.y))
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func makeSyntheticImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let tile = 100
        for row in 0...(height / tile) {
            for column in 0...(width / tile) {
                let even = (row + column) % 2 == 0
                context.setFillColor(even ? CGColor(gray: 0.85, alpha: 1) : CGColor(srgbRed: 0.3, green: 0.5, blue: 0.8, alpha: 1))
                context.fill(CGRect(x: column * tile, y: row * tile, width: tile, height: tile))
            }
        }
        return context.makeImage()!
    }

    private static func terminate() {
        log("terminating")
        NSApp.terminate(nil)
    }
}
