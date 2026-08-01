//
//  ZoomResizeProbe.swift
//  QuickSnap
//
//  TEMPORARY diagnostic harness — inert unless launched with
//  QUICKSNAP_ZOOM_PROBE=1. Opens an annotation window with a synthetic
//  image, performs real live-resize drags via CGEvents (posting requires
//  Accessibility permission for QuickSnap; the probe checks and prompts),
//  and logs every zoom decision with timestamps so the remote canvas's
//  event ordering can be observed instead of guessed. Prints a PASS/FAIL
//  summary per scenario, then terminates the app.
//

import AppKit
import ApplicationServices
import CoreGraphics
import PaperKit

@MainActor
enum ZoomResizeProbe {
    static let isEnabled = ProcessInfo.processInfo.environment["QUICKSNAP_ZOOM_PROBE"] == "1"

    /// Set by `MarkupCanvasController.init` while the probe is enabled, so
    /// the probe can reach the canvas without threading access through the
    /// view layers.
    static weak var currentCanvas: MarkupCanvasController?

    private static let startTime = Date()
    private static var failures = 0

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let elapsed = String(format: "%8.3f", Date().timeIntervalSince(startTime))
        print("[probe \(elapsed)] \(message())")
        fflush(stdout)
    }

    static func startIfEnabled(annotationCoordinator: AnnotationCoordinator) {
        guard isEnabled else { return }
        Task { await run(annotationCoordinator: annotationCoordinator) }
    }

    // MARK: - Scenario script

    private static func run(annotationCoordinator: AnnotationCoordinator) async {
        log("starting — checking Accessibility")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        log("accessibility trusted: \(trusted)")

        annotationCoordinator.openAnnotationWindow(
            image: makeSyntheticImage(width: 1600, height: 1000),
            file: CaptureFile()
        )
        try? await Task.sleep(for: .seconds(2))

        guard let canvas = currentCanvas,
            let window = NSApp.windows.first(where: { $0.delegate === annotationCoordinator })
        else {
            log("ABORT: annotation window or canvas controller not found")
            return terminate()
        }
        logState("initial", canvas, window)

        guard trusted else {
            log("ABORT: grant Accessibility to QuickSnap (System Settings → Privacy & Security → Accessibility), then re-run")
            return terminate()
        }

        // Control test: CGEvent delivery. Drag the title bar; if the window
        // didn't move, events are silently not being delivered.
        let originBefore = window.frame.origin.x
        await postDrag(
            fromCocoa: CGPoint(x: window.frame.midX, y: window.frame.maxY - 10),
            byX: 80, steps: 8, stepDelayMs: 16
        )
        try? await Task.sleep(for: .seconds(0.6))
        guard abs(window.frame.origin.x - originBefore) > 40 else {
            log("ABORT: control drag did not move the window — CGEvents not delivered")
            return terminate()
        }
        log("control drag OK (window moved)")

        // Post-drag waits are generous: the remote resumes accepting host
        // sets ~0.4 s after growing drags but ~1.3 s+ after shrinking ones,
        // and enforcement retries until it lands — the checks measure the
        // settled state, not the transient.

        // Test 1: live shrink at fit → relative zoom must stay 1 (fit).
        var expected = relativeZoom(canvas)
        await dragRightEdge(of: window, byX: -400, steps: 10, stepDelayMs: 16)
        try? await Task.sleep(for: .seconds(3))
        check("1: shrink at fit", canvas, window, expected: expected)

        // Test 2: zoom to 2× (programmatic stand-in for a pinch), grow.
        zoomTo(canvas, relative: 2)
        try? await Task.sleep(for: .seconds(0.8))
        logState("after zoomTo(2)", canvas, window)
        expected = relativeZoom(canvas)
        await dragRightEdge(of: window, byX: 350, steps: 10, stepDelayMs: 16)
        try? await Task.sleep(for: .seconds(3))
        check("2: grow while zoomed", canvas, window, expected: expected)

        // Test 3: fast, large shrink while zoomed — the reported failure.
        expected = relativeZoom(canvas)
        await dragRightEdge(of: window, byX: -600, steps: 5, stepDelayMs: 8)
        try? await Task.sleep(for: .seconds(3))
        check("3: fast large shrink while zoomed", canvas, window, expected: expected)

        log(failures == 0 ? "SUMMARY: ALL PASS" : "SUMMARY: \(failures) FAILURE(S)")
        terminate()
    }

    // MARK: - Canvas helpers

    private static func relativeZoom(_ canvas: MarkupCanvasController) -> CGFloat {
        let visible = canvas.visibleCanvasFrame
        guard visible.width > 0 else { return .nan }
        return canvas.canvasBounds.width / visible.width
    }

    /// Programmatic stand-in for a user pinch: centers a region sized for
    /// the given relative zoom. Outside a resize the delegate accepts the
    /// resulting report as a genuine gesture, matching real pinch state.
    private static func zoomTo(_ canvas: MarkupCanvasController, relative: CGFloat) {
        guard let viewController = canvas.viewController else {
            log("zoomTo: no viewController")
            return
        }
        let bounds = canvas.canvasBounds
        let size = CGSize(width: bounds.width / relative, height: bounds.height / relative)
        viewController.setContentVisibleFrame(
            CGRect(
                x: bounds.midX - size.width / 2,
                y: bounds.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            animated: false
        )
    }

    private static func check(_ name: String, _ canvas: MarkupCanvasController, _ window: NSWindow, expected: CGFloat) {
        let actual = relativeZoom(canvas)
        let pass = expected > 0 && abs(actual - expected) / expected < 0.05
        if !pass { failures += 1 }
        log("\(pass ? "PASS" : "FAIL") test \(name): relativeZoom expected \(format(expected)) actual \(format(actual))")
        logState("after test \(name)", canvas, window)
    }

    private static func logState(_ label: String, _ canvas: MarkupCanvasController, _ window: NSWindow) {
        log("state[\(label)]: window=\(window.frame.size) canvas=\(canvas.canvasBounds.size) visible=\(canvas.visibleCanvasFrame.integral) relZoom=\(format(relativeZoom(canvas)))")
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    // MARK: - CGEvent drags

    /// Right edge, vertical middle — over the opaque mat, safely inside the
    /// resize band, and width-driven so the aspect lock follows in height.
    private static func dragRightEdge(of window: NSWindow, byX deltaX: CGFloat, steps: Int, stepDelayMs: Int) async {
        let start = CGPoint(x: window.frame.maxX - 2, y: window.frame.midY)
        log("drag right edge byX=\(deltaX) steps=\(steps) delay=\(stepDelayMs)ms")
        await postDrag(fromCocoa: start, byX: deltaX, steps: steps, stepDelayMs: stepDelayMs)
    }

    private static func postDrag(fromCocoa start: CGPoint, byX deltaX: CGFloat, steps: Int, stepDelayMs: Int) async {
        let cgStart = cgPoint(fromCocoa: start)
        post(.leftMouseDown, at: cgStart)
        for step in 1...steps {
            let progress = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, at: CGPoint(x: cgStart.x + deltaX * progress, y: cgStart.y))
            try? await Task.sleep(for: .milliseconds(stepDelayMs))
        }
        post(.leftMouseUp, at: CGPoint(x: cgStart.x + deltaX, y: cgStart.y))
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Cocoa global coords (bottom-left origin, y up) → CG event coords
    /// (top-left origin of the primary display, y down).
    private static func cgPoint(fromCocoa point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    // MARK: - Fixture

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
