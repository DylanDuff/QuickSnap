//
//  CropOverlay.swift
//  QuickSnap
//

import SwiftUI

/// Crop surface shown over the markup canvas while crop mode is active
/// (`MarkupCanvasController.isCropActive`): drag out a rect, then adjust it
/// with the corner/edge handles or move it by dragging inside; everything
/// outside the rect is dimmed. Return (or the ✓ button) applies the crop,
/// Esc (or ✕) cancels the whole mode.
///
/// Like `ShapeInsertionOverlay`, this must render pixels across the canvas
/// (the dim) so the window server routes mouse input to the host app instead
/// of the remote PaperKit surface — and must only be mounted while cropping
/// (see CLAUDE.md). Occlusion is per-layer, not per-pixel, so the clear
/// "hole" over the crop region still receives our input.
struct CropOverlay: View {
    @ObservedObject var controller: MarkupCanvasController

    /// The crop rect in view points; nil until the first drag creates one.
    @State private var cropRect: CGRect?
    @State private var activeDrag: DragMode?

    private enum DragMode {
        case creating(anchor: CGPoint)
        case moving(startOrigin: CGPoint)
        case resizing(handle: Handle, startRect: CGRect)
    }

    /// Smallest crop rect edge while dragging, in view points. The final
    /// pixel-space minimum is enforced by `MarkupCanvasController.applyCrop`.
    private static let minimumEdge: CGFloat = 24
    private static let handleHitRadius: CGFloat = 14

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                dimAndSelection(in: geometry.size)
                    .contentShape(Rectangle())
                    .gesture(dragGesture(in: geometry.size))
                if let rect = cropRect {
                    handles(for: rect)
                        .allowsHitTesting(false)
                    confirmBar(for: rect, in: geometry.size)
                } else {
                    hint(in: geometry.size)
                }
            }
        }
        .background(keyboardShortcuts)
    }

    // MARK: - Drag handling

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeDrag == nil {
                    activeDrag = dragMode(at: value.startLocation)
                }
                updateCropRect(with: value, in: size)
            }
            .onEnded { value in
                updateCropRect(with: value, in: size)
                // A bare click that "created" a degenerate rect leaves the
                // previous state: no rect yet → back to the hint.
                if case .creating = activeDrag, let rect = cropRect,
                    rect.width < 4 || rect.height < 4 {
                    cropRect = nil
                }
                activeDrag = nil
            }
    }

    private func dragMode(at point: CGPoint) -> DragMode {
        guard let rect = cropRect else { return .creating(anchor: point) }
        if let handle = Handle.allCases.min(by: {
            $0.position(in: rect).distance(to: point) < $1.position(in: rect).distance(to: point)
        }), handle.position(in: rect).distance(to: point) <= Self.handleHitRadius {
            return .resizing(handle: handle, startRect: rect)
        }
        if rect.contains(point) {
            return .moving(startOrigin: rect.origin)
        }
        return .creating(anchor: point)
    }

    private func updateCropRect(with value: DragGesture.Value, in size: CGSize) {
        switch activeDrag {
        case .creating(let anchor):
            let location = value.location.clamped(to: size)
            cropRect = CGRect(
                x: min(anchor.x, location.x),
                y: min(anchor.y, location.y),
                width: abs(location.x - anchor.x),
                height: abs(location.y - anchor.y)
            )
        case .moving(let startOrigin):
            guard let rect = cropRect else { return }
            cropRect?.origin = CGPoint(
                x: (startOrigin.x + value.translation.width).clamped(0, size.width - rect.width),
                y: (startOrigin.y + value.translation.height).clamped(0, size.height - rect.height)
            )
        case .resizing(let handle, let startRect):
            cropRect = resizedRect(startRect, handle: handle, translation: value.translation, in: size)
        case nil:
            break
        }
    }

    private func resizedRect(_ start: CGRect, handle: Handle, translation: CGSize, in size: CGSize) -> CGRect {
        var minX = start.minX, maxX = start.maxX
        var minY = start.minY, maxY = start.maxY
        if handle.movesMinX { minX = (minX + translation.width).clamped(0, maxX - Self.minimumEdge) }
        if handle.movesMaxX { maxX = (maxX + translation.width).clamped(minX + Self.minimumEdge, size.width) }
        if handle.movesMinY { minY = (minY + translation.height).clamped(0, maxY - Self.minimumEdge) }
        if handle.movesMaxY { maxY = (maxY + translation.height).clamped(minY + Self.minimumEdge, size.height) }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Apply / cancel

    private func apply(in size: CGSize) {
        guard let rect = cropRect, size.width > 0 else {
            controller.cancelCrop()
            return
        }
        // View points → image pixels through the current viewport (the
        // canvas may be zoomed/panned): uniform scale plus the visible
        // frame's origin offset.
        let visible = controller.visibleCanvasFrame
        let scale = visible.width / size.width
        controller.applyCrop(to: CGRect(
            x: visible.minX + rect.minX * scale,
            y: visible.minY + rect.minY * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ))
    }

    // MARK: - Rendering

    /// The dim with the crop rect cut out (even-odd fill), plus the rect's
    /// border. With no rect yet, a uniform dim.
    private func dimAndSelection(in size: CGSize) -> some View {
        ZStack {
            Path { path in
                path.addRect(CGRect(origin: .zero, size: size))
                if let rect = cropRect {
                    path.addRect(rect)
                }
            }
            .fill(Color.black.opacity(0.4), style: FillStyle(eoFill: true))
            if let rect = cropRect {
                Path(rect)
                    .stroke(Color.white.opacity(0.9), lineWidth: 1.5)
            }
        }
        .pointerStyle(cropRect == nil ? .rectSelection : .default)
    }

    private func handles(for rect: CGRect) -> some View {
        ForEach(Handle.allCases, id: \.self) { handle in
            let position = handle.position(in: rect)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1))
                .frame(width: 9, height: 9)
                .shadow(color: .black.opacity(0.4), radius: 2)
                .position(position)
        }
    }

    private func confirmBar(for rect: CGRect, in size: CGSize) -> some View {
        let scale = controller.visibleCanvasFrame.width / max(size.width, 1)
        let barHeight: CGFloat = 32
        // Below the rect when there's room, tucked inside its bottom edge
        // otherwise; always kept within the canvas horizontally.
        let y = min(rect.maxY + 10 + barHeight / 2, size.height - barHeight / 2 - 6)
        return HStack(spacing: 10) {
            Text(verbatim: "\(Int(rect.width * scale)) × \(Int(rect.height * scale))")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Button {
                controller.cancelCrop()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Cancel crop (Esc)")
            Button {
                apply(in: size)
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 22, height: 22)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Apply crop (Return)")
        }
        .padding(.horizontal, 12)
        .frame(height: barHeight)
        .background(Capsule().fill(.regularMaterial))
        .position(
            x: rect.midX.clamped(80, max(size.width - 80, 80)),
            y: y
        )
    }

    private func hint(in size: CGSize) -> some View {
        Text("Drag to select the crop area")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(.black.opacity(0.5)))
            .position(x: size.width / 2, y: size.height / 2)
            .allowsHitTesting(false)
    }

    /// Hidden buttons carrying the Return/Esc shortcuts, same pattern as
    /// `ShapeInsertionOverlay`.
    private var keyboardShortcuts: some View {
        GeometryReader { geometry in
            ZStack {
                Button("") { apply(in: geometry.size) }
                    .keyboardShortcut(.defaultAction)
                Button("") { controller.cancelCrop() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
    }

    // MARK: - Handles

    private enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        /// Handle position as a unit coordinate of the rect (0…1 each axis).
        private var unit: CGPoint {
            switch self {
            case .topLeft: CGPoint(x: 0, y: 0)
            case .top: CGPoint(x: 0.5, y: 0)
            case .topRight: CGPoint(x: 1, y: 0)
            case .right: CGPoint(x: 1, y: 0.5)
            case .bottomRight: CGPoint(x: 1, y: 1)
            case .bottom: CGPoint(x: 0.5, y: 1)
            case .bottomLeft: CGPoint(x: 0, y: 1)
            case .left: CGPoint(x: 0, y: 0.5)
            }
        }

        var movesMinX: Bool { unit.x == 0 }
        var movesMaxX: Bool { unit.x == 1 }
        var movesMinY: Bool { unit.y == 0 }
        var movesMaxY: Bool { unit.y == 1 }

        func position(in rect: CGRect) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * unit.x, y: rect.minY + rect.height * unit.y)
        }
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }

    func clamped(to size: CGSize) -> CGPoint {
        CGPoint(x: x.clamped(0, size.width), y: y.clamped(0, size.height))
    }
}

private extension CGFloat {
    func clamped(_ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lower), upper)
    }
}
