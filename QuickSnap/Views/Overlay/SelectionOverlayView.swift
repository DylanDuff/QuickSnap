//
//  SelectionOverlayView.swift
//  QuickSnap
//

import AppKit
import ScreenCaptureKit

protocol SelectionOverlayViewDelegate: AnyObject {
    func selectionOverlayView(_ view: SelectionOverlayView, didSelectAreaRect rect: CGRect)
    func selectionOverlayView(_ view: SelectionOverlayView, didSelectWindow window: SCWindow)
    func selectionOverlayViewDidCancel(_ view: SelectionOverlayView)
}

/// A window candidate for "Capture Window" mode, with its frame already
/// converted into this screen's local, top-left-origin coordinate space.
struct SelectionWindowCandidate {
    let window: SCWindow
    let localFrame: CGRect
}

enum SelectionMode {
    case area
    case window(candidates: [SelectionWindowCandidate])
}

final class SelectionOverlayView: NSView {
    weak var delegate: SelectionOverlayViewDelegate?
    private let mode: SelectionMode

    private var dragOrigin: CGPoint?
    private var currentRect: CGRect?
    private var highlightedCandidate: SelectionWindowCandidate?

    private static let scrimColor = NSColor.black.withAlphaComponent(0.35)
    private static let selectionBorderColor = NSColor(red: 0.2, green: 0.55, blue: 1, alpha: 1)

    init(frame: NSRect, mode: SelectionMode) {
        self.mode = mode
        super.init(frame: frame)
        if case .window = mode {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.crosshair.set()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        Self.scrimColor.setFill()
        bounds.fill()

        switch mode {
        case .area:
            guard let rect = currentRect else { return }
            drawCutout(rect)
            drawDimensionLabel(for: rect)
        case .window:
            guard let candidate = highlightedCandidate else { return }
            drawCutout(candidate.localFrame)
        }
    }

    private func drawCutout(_ rect: CGRect) {
        NSGraphicsContext.saveGraphicsState()
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        NSGraphicsContext.restoreGraphicsState()

        Self.selectionBorderColor.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        border.stroke()
    }

    private func drawDimensionLabel(for rect: CGRect) {
        let text = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let padding = CGPoint(x: 6, y: 3)
        var origin = CGPoint(x: rect.minX, y: rect.maxY + 6)
        if origin.y + size.height + padding.y * 2 > bounds.maxY {
            origin.y = rect.minY - size.height - padding.y * 2 - 6
        }
        let labelRect = CGRect(x: origin.x, y: origin.y, width: size.width + padding.x * 2, height: size.height + padding.y * 2)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: labelRect, xRadius: 4, yRadius: 4).fill()
        text.draw(at: CGPoint(x: labelRect.minX + padding.x, y: labelRect.minY + padding.y), withAttributes: attributes)
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        switch mode {
        case .area:
            dragOrigin = convert(event.locationInWindow, from: nil)
            currentRect = nil
        case .window:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard case .area = mode, let origin = dragOrigin else { return }
        let point = convert(event.locationInWindow, from: nil)
        currentRect = CGRect(
            x: min(origin.x, point.x),
            y: min(origin.y, point.y),
            width: abs(point.x - origin.x),
            height: abs(point.y - origin.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch mode {
        case .area:
            defer { dragOrigin = nil; currentRect = nil }
            guard let rect = currentRect, rect.width >= 3, rect.height >= 3 else {
                delegate?.selectionOverlayViewDidCancel(self)
                return
            }
            delegate?.selectionOverlayView(self, didSelectAreaRect: rect)
        case .window:
            guard let candidate = highlightedCandidate else {
                delegate?.selectionOverlayViewDidCancel(self)
                return
            }
            delegate?.selectionOverlayView(self, didSelectWindow: candidate.window)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard case .window(let candidates) = mode else { return }
        let point = convert(event.locationInWindow, from: nil)
        let match = candidates.first { $0.localFrame.contains(point) }
        if match?.window.windowID != highlightedCandidate?.window.windowID {
            highlightedCandidate = match
            needsDisplay = true
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            delegate?.selectionOverlayViewDidCancel(self)
        } else {
            super.keyDown(with: event)
        }
    }
}
