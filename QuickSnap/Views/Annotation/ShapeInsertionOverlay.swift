//
//  ShapeInsertionOverlay.swift
//  QuickSnap
//

import PaperKit
import SwiftUI

/// Transparent drag surface shown over the markup canvas while an insertion
/// is armed (`MarkupCanvasController.pendingInsertion` is non-nil): the user
/// drags out the shape/line with a live preview, and the final geometry is
/// inserted into the markup on mouse-up. A bare click (or Esc) backs out.
///
/// This view must only be mounted while an insertion is pending — any layer
/// above the PaperKit canvas kills the canvas's mouse input at the
/// window-server level (see CLAUDE.md). During the drag that's exactly what
/// we want; the rest of the time the overlay must not exist at all.
struct ShapeInsertionOverlay: View {
    @ObservedObject var controller: MarkupCanvasController
    @State private var dragStart: CGPoint?
    @State private var dragLocation: CGPoint?

    var body: some View {
        GeometryReader { geometry in
            // View points → image pixels through the current viewport (the
            // canvas may be zoomed/panned): uniform scale plus the visible
            // frame's origin offset.
            let visible = controller.visibleCanvasFrame
            let scale = visible.width / max(geometry.size.width, 1)
            ZStack {
                // Must actually render pixels: a non-drawing layer (Color.clear)
                // doesn't occlude the remote PaperKit surface at the
                // window-server level, so input keeps flowing to the canvas
                // and never reaches this overlay's gesture. The dim also
                // signals "drag to place" mode.
                Color.black.opacity(0.15)
                if let start = dragStart, let location = dragLocation {
                    preview(from: start, to: location, scale: scale)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragStart = value.startLocation
                        dragLocation = value.location
                    }
                    .onEnded { value in
                        dragStart = nil
                        dragLocation = nil
                        let start = value.startLocation
                        let end = value.location
                        guard hypot(end.x - start.x, end.y - start.y) >= 4 else {
                            controller.cancelPendingInsertion()
                            return
                        }
                        controller.completePendingInsertion(
                            from: CGPoint(x: visible.minX + start.x * scale, y: visible.minY + start.y * scale),
                            to: CGPoint(x: visible.minX + end.x * scale, y: visible.minY + end.y * scale)
                        )
                    }
            )
        }
        .pointerStyle(.rectSelection)
        .background(
            Button("") { controller.cancelPendingInsertion() }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
        )
    }

    /// Live preview in view points, approximating how PaperKit will render
    /// the inserted markup (stroke width is scaled down from image pixels).
    @ViewBuilder
    private func preview(from start: CGPoint, to end: CGPoint, scale: CGFloat) -> some View {
        let lineWidth = max(1, controller.strokeWidth / scale)
        switch controller.pendingInsertion {
        case .shape(let shape):
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            shapePath(shape, in: rect)
                .stroke(controller.color, lineWidth: lineWidth)
        case .line(let arrow):
            linePath(from: start, to: end, arrow: arrow, headLength: max(lineWidth * 4, 10))
                .stroke(
                    controller.color,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                )
        case nil:
            EmptyView()
        }
    }

    private func shapePath(_ shape: ShapeConfiguration.Shape, in rect: CGRect) -> Path {
        switch shape {
        case .ellipse:
            Path(ellipseIn: rect)
        default:
            Path(roundedRect: rect, cornerRadius: min(8, min(rect.width, rect.height) / 4))
        }
    }

    private func linePath(from start: CGPoint, to end: CGPoint, arrow: Bool, headLength: CGFloat) -> Path {
        Path { path in
            path.move(to: start)
            path.addLine(to: end)
            guard arrow else { return }
            let angle = atan2(end.y - start.y, end.x - start.x)
            for offset in [CGFloat.pi * 5 / 6, -CGFloat.pi * 5 / 6] {
                path.move(to: end)
                path.addLine(to: CGPoint(
                    x: end.x + cos(angle + offset) * headLength,
                    y: end.y + sin(angle + offset) * headLength
                ))
            }
        }
    }
}
