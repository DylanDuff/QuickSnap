//
//  UndoProbe.swift
//  QuickSnap
//
//  TEMPORARY diagnostic harness — inert unless launched with
//  QUICKSNAP_UNDO_PROBE=1. Answers the two questions an undo feature on a
//  remote PaperKit canvas hinges on, empirically rather than by assumption:
//
//    1. Does `paperMarkupViewControllerDidChangeMarkup` actually fire for a
//       user-drawn stroke (the only signal a host-side undo stack could be
//       driven by), and how many times per stroke?
//    2. Does the remote canvas already implement ⌘Z itself? If it does, a
//       host-level `keyboardShortcut` would *take* working behaviour, since
//       `performKeyEquivalent` runs before the remote view sees the key.
//
//  Draws with real CGEvents (posting requires Accessibility permission for
//  QuickSnap; the probe checks and prompts), then prints a summary and
//  terminates the app.
//

import AppKit
import ApplicationServices
import CoreGraphics
import PaperKit

@MainActor
enum UndoProbe {
    static let isEnabled = ProcessInfo.processInfo.environment["QUICKSNAP_UNDO_PROBE"] == "1"

    private static let startTime = Date()

    /// Delegate fires since the last `resetChangeCount()`, so a stroke's
    /// change reports can be counted rather than guessed at.
    private(set) static var markupChangeCount = 0

    static func noteMarkupChanged() {
        guard isEnabled else { return }
        markupChangeCount += 1
        log("delegate: didChangeMarkup (#\(markupChangeCount))")
    }

    private static func resetChangeCount() {
        markupChangeCount = 0
    }

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let elapsed = String(format: "%8.3f", Date().timeIntervalSince(startTime))
        print("[undo-probe \(elapsed)] \(message())")
        fflush(stdout)
    }

    static func startIfEnabled(annotationCoordinator: AnnotationCoordinator) {
        guard isEnabled else { return }
        Task { await run(annotationCoordinator: annotationCoordinator) }
    }

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

        guard let canvas = ProbeCanvas.current,
            let window = NSApp.windows.first(where: { $0.delegate === annotationCoordinator }),
            let viewController = canvas.viewController
        else {
            log("ABORT: annotation window or canvas controller not found")
            return terminate()
        }
        log("window=\(window.frame) canvas=\(canvas.canvasBounds.size) tool=\(canvas.tool.rawValue)")

        guard trusted else {
            log("ABORT: grant Accessibility to QuickSnap (System Settings → Privacy & Security → Accessibility), then re-run")
            return terminate()
        }

        // Control test: are CGEvents reaching this process at all? Drag the
        // title bar and check the window moved.
        let originBefore = window.frame.origin.x
        await postDrag(fromCocoa: CGPoint(x: window.frame.midX, y: window.frame.maxY - 10), points: [CGPoint(x: 80, y: 0)])
        try? await Task.sleep(for: .seconds(0.6))
        guard abs(window.frame.origin.x - originBefore) > 40 else {
            log("ABORT: control drag did not move the window — CGEvents not delivered")
            return terminate()
        }
        log("control drag OK (window moved)")

        // Content bounding boxes are the measurement throughout: PaperMarkup
        // `==` does not survive a round trip through the remote canvas
        // (measured — a restored value is structurally right but unequal,
        // and its serialized size differs), so equality can't be used to
        // tell states apart.
        let emptyFrame = viewController.markup?.contentsRenderFrame ?? .null
        check("0: canvas starts with no history", !canvas.canUndo && !canvas.canRedo)

        // One stroke on the left, then one further right, so the content
        // frame tells the two states apart by width.
        resetChangeCount()
        await drawStroke(in: viewController, window: window)
        try? await Task.sleep(for: .seconds(1.2))
        let oneStrokeFrame = viewController.markup?.contentsRenderFrame ?? .null
        check("1: one stroke recorded one undo step", markupChangeCount == 1 && canvas.canUndo && !canvas.canRedo)
        log("   frames: empty=\(emptyFrame.integral) oneStroke=\(oneStrokeFrame.integral)")

        await drawStroke(in: viewController, window: window, offsetX: 140)
        try? await Task.sleep(for: .seconds(1.2))
        let twoStrokeFrame = viewController.markup?.contentsRenderFrame ?? .null
        check("2: second stroke widened the content", twoStrokeFrame.width > oneStrokeFrame.width)

        // The real user path: ⌘Z through the window's key equivalents, not
        // a direct call — that's what has to beat the remote view to the key.
        postCommandZ(shift: false)
        try? await Task.sleep(for: .seconds(1.2))
        check(
            "3: ⌘Z removed the second stroke",
            (viewController.markup?.contentsRenderFrame ?? .null).isApproximately(oneStrokeFrame) && canvas.canRedo
        )
        log("   after ⌘Z: \((viewController.markup?.contentsRenderFrame ?? .null).integral)")

        postCommandZ(shift: true)
        try? await Task.sleep(for: .seconds(1.2))
        check(
            "4: ⌘⇧Z put it back",
            (viewController.markup?.contentsRenderFrame ?? .null).isApproximately(twoStrokeFrame) && !canvas.canRedo
        )

        // Back to the start, then confirm the history bottoms out.
        canvas.undo()
        canvas.undo()
        try? await Task.sleep(for: .seconds(1))
        let backToEmpty = viewController.markup?.contentsRenderFrame ?? .null
        check(
            "5: undoing every step empties the canvas and the history",
            backToEmpty.isNull || backToEmpty.isInfinite || backToEmpty.width == 0
        )
        check("5b: nothing left to undo", !canvas.canUndo && canvas.canRedo)
        log("   after two undos: \(backToEmpty.integral) canUndo=\(canvas.canUndo) canRedo=\(canvas.canRedo)")

        // Redo forward again so there's markup to survive the crop.
        canvas.redo()
        canvas.redo()
        try? await Task.sleep(for: .seconds(1))

        // --- Crop: image, bounds and markup have to move as one step ---
        let boundsBeforeCrop = canvas.canvasBounds
        let frameBeforeCrop = viewController.markup?.contentsRenderFrame ?? .null
        canvas.applyCrop(to: CGRect(x: 200, y: 100, width: 1000, height: 700))
        try? await Task.sleep(for: .seconds(1.5))
        check("6: crop applied", canvas.canvasBounds.size == CGSize(width: 1000, height: 700))
        log("   markup after crop: \((viewController.markup?.contentsRenderFrame ?? .null).integral) (shifted by the crop origin)")

        canvas.undo()
        try? await Task.sleep(for: .seconds(1.5))
        check("7: undoing a crop restores the canvas size", canvas.canvasBounds == boundsBeforeCrop)
        check(
            "7b: …and puts the markup back where it was",
            (viewController.markup?.contentsRenderFrame ?? .null).isApproximately(frameBeforeCrop)
        )
        log("   after crop undo: bounds=\(canvas.canvasBounds.size) markup=\((viewController.markup?.contentsRenderFrame ?? .null).integral)")

        // --- Redaction must take the history with it ---
        canvas.redact([
            SensitiveMatch(kind: .apiToken, rect: CGRect(x: 40, y: 40, width: 300, height: 60), preview: "probe")
        ])
        try? await Task.sleep(for: .seconds(0.5))
        check("8: redaction cleared the undo history", !canvas.canUndo && !canvas.canRedo)

        // --- And the canvas still takes edits after all of that ---
        resetChangeCount()
        await drawStroke(in: viewController, window: window, offsetX: -40)
        try? await Task.sleep(for: .seconds(1.2))
        check("9: canvas still editable, and recording again", markupChangeCount == 1 && canvas.canUndo)

        log(failures == 0 ? "SUMMARY: ALL PASS" : "SUMMARY: \(failures) FAILURE(S)")
        terminate()
    }

    private static var failures = 0

    private static func check(_ name: String, _ passed: Bool) {
        if !passed { failures += 1 }
        log("\(passed ? "PASS" : "FAIL") \(name)")
    }

    // MARK: - Canvas geometry

    /// Draws a short zig-zag in the middle of the canvas view, in screen
    /// coordinates. In-process synthetic events never reach the remote
    /// canvas, so this has to go through the HID event tap.
    private static func drawStroke(in viewController: PaperMarkupViewController, window: NSWindow, offsetX: CGFloat = 0) async {
        let view = viewController.view
        let inWindow = view.convert(view.bounds, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        let start = CGPoint(x: onScreen.midX - 120 + offsetX, y: onScreen.midY)
        log("drawing stroke from \(start) within canvas view \(onScreen)")
        await postDrag(
            fromCocoa: start,
            points: [
                CGPoint(x: 40, y: 40), CGPoint(x: 80, y: -40),
                CGPoint(x: 120, y: 40), CGPoint(x: 160, y: 0),
            ],
            stepsPerSegment: 6
        )
    }

    // MARK: - Event posting

    /// Offsets are relative to `start`, in Cocoa screen coordinates.
    private static func postDrag(
        fromCocoa start: CGPoint,
        points offsets: [CGPoint],
        stepsPerSegment: Int = 8,
        stepDelayMs: Int = 12
    ) async {
        let cgStart = cgPoint(fromCocoa: start)
        post(.leftMouseDown, at: cgStart)
        var previous = CGPoint.zero
        for offset in offsets {
            for step in 1...stepsPerSegment {
                let progress = CGFloat(step) / CGFloat(stepsPerSegment)
                let x = previous.x + (offset.x - previous.x) * progress
                let y = previous.y + (offset.y - previous.y) * progress
                post(.leftMouseDragged, at: CGPoint(x: cgStart.x + x, y: cgStart.y - y))
                try? await Task.sleep(for: .milliseconds(stepDelayMs))
            }
            previous = offset
        }
        post(.leftMouseUp, at: CGPoint(x: cgStart.x + previous.x, y: cgStart.y - previous.y))
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// Virtual key 6 is `z` on any layout (the code is positional).
    private static func postCommandZ(shift: Bool) {
        let flags: CGEventFlags = shift ? [.maskCommand, .maskShift] : [.maskCommand]
        log("posting \(shift ? "⌘⇧Z" : "⌘Z")")
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: isDown)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }

    /// Cocoa global coords (bottom-left origin, y up) → CG event coords
    /// (top-left origin of the primary display, y down).
    private static func cgPoint(fromCocoa point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    private static func makeSyntheticImage(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(gray: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static func terminate() {
        log("terminating")
        NSApp.terminate(nil)
    }
}
