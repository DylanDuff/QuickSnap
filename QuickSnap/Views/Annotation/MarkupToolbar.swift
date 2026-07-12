//
//  MarkupToolbar.swift
//  QuickSnap
//

import PaperKit
import SwiftUI

/// The bespoke tools pill under the markup canvas: tool selection
/// (select / pen / marker / highlighter / eraser), shape & text insertion,
/// color and stroke width, and the two output actions (Copy, Save As…).
/// Pure UI — all state lives in `MarkupCanvasController`, and the output
/// actions are closures wired up by `AnnotationCoordinator`.
struct MarkupToolbar: View {
    /// Fixed pill height — part of `AnnotationView.Layout.chromeSize`, which
    /// the window's aspect-ratio lock depends on.
    static let height: CGFloat = 48

    @ObservedObject var controller: MarkupCanvasController
    var onCopy: () -> Void
    var onSaveAs: () -> Void

    /// A preset row that can slide in over the pill's main controls.
    /// Selecting a preset (or a color from the system picker) swaps back.
    private enum PresetRow {
        case color
        case stroke
    }

    @State private var activePresetRow: PresetRow?

    var body: some View {
        ZStack {
            switch activePresetRow {
            case .color:
                presetColorRow
                    .transition(Self.rowTransition)
            case .stroke:
                presetStrokeRow
                    .transition(Self.rowTransition)
            case nil:
                mainControls
                    .transition(Self.rowTransition)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Self.height)
        .background(Capsule().fill(.regularMaterial))
        .clipShape(Capsule())
        .onChange(of: controller.color) {
            // Covers the system color picker, which changes the color
            // without going through a preset swatch's action.
            guard activePresetRow == .color else { return }
            withAnimation(Self.rowSwapAnimation) { activePresetRow = nil }
        }
    }

    private static let rowSwapAnimation: Animation = .snappy(duration: 0.25)

    /// Everything slides upward: the outgoing row exits through the pill's
    /// top edge while the incoming one rises in from the bottom.
    private static let rowTransition: AnyTransition = .asymmetric(
        insertion: .move(edge: .bottom).combined(with: .opacity),
        removal: .move(edge: .top).combined(with: .opacity)
    )

    private var mainControls: some View {
        HStack(spacing: 6) {
            toolButtons
            divider
            insertMenu
            cropButton
            divider
            stylePickers
            divider
            outputButtons
        }
    }

    private var cropButton: some View {
        Button {
            if controller.isCropActive {
                controller.cancelCrop()
            } else {
                controller.beginCrop()
            }
        } label: {
            Image(systemName: "crop")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(controller.isCropActive ? Color.accentColor.opacity(0.25) : .clear)
                )
                .foregroundStyle(controller.isCropActive ? Color.accentColor : Color.primary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Crop — drag out the area to keep, Return to apply")
    }

    private static let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .pink, .white, .black,
    ]

    private var presetColorRow: some View {
        HStack(spacing: 10) {
            ForEach(Self.presetColors, id: \.self) { preset in
                Button {
                    withAnimation(Self.rowSwapAnimation) {
                        controller.color = preset
                        activePresetRow = nil
                    }
                } label: {
                    colorSwatch(preset, size: 22)
                }
                .buttonStyle(.plain)
            }
            divider
            ColorPicker("Custom color", selection: $controller.color, supportsOpacity: false)
                .labelsHidden()
                .help("Custom color…")
        }
    }

    private func colorSwatch(_ color: Color, size: CGFloat) -> some View {
        Circle()
            .fill(color)
            .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
            .frame(width: size, height: size)
    }

    private var divider: some View {
        Divider().frame(height: 22).padding(.horizontal, 4)
    }

    private var toolButtons: some View {
        ForEach(MarkupTool.allCases) { tool in
            toolButton(tool)
        }
    }

    private func toolButton(_ tool: MarkupTool) -> some View {
        Button {
            controller.tool = tool
        } label: {
            Image(systemName: Self.symbolName(for: tool))
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(controller.tool == tool ? Color.accentColor.opacity(0.25) : .clear)
                )
                .foregroundStyle(controller.tool == tool ? Color.accentColor : Color.primary)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(Self.helpText(for: tool))
    }

    private var insertMenu: some View {
        Menu {
            Button("Rectangle") { controller.pendingInsertion = .shape(.roundedRectangle) }
            Button("Ellipse") { controller.pendingInsertion = .shape(.ellipse) }
            Divider()
            Button("Line") { controller.pendingInsertion = .line(arrow: false) }
            Button("Arrow") { controller.pendingInsertion = .line(arrow: true) }
            Divider()
            Button("Text") { controller.insertTextbox() }
        } label: {
            Image(systemName: "plus.square.on.square")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(controller.pendingInsertion != nil ? Color.accentColor : Color.primary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .contentShape(Circle())
        .help("Insert shape, line, or text — drag on the image to place it")
    }

    private var stylePickers: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(Self.rowSwapAnimation) { activePresetRow = .color }
            } label: {
                colorSwatch(controller.color, size: 20)
            }
            .buttonStyle(.plain)
            .help("Markup color")
            Button {
                withAnimation(Self.rowSwapAnimation) { activePresetRow = .stroke }
            } label: {
                strokeDot(for: controller.strokeWidth)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stroke width")
        }
    }

    private var presetStrokeRow: some View {
        HStack(spacing: 10) {
            ForEach(controller.strokeWidthPresets, id: \.self) { preset in
                Button {
                    withAnimation(Self.rowSwapAnimation) {
                        controller.strokeWidth = preset
                        activePresetRow = nil
                    }
                } label: {
                    strokeDot(for: preset)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(preset == nearestPresetToCurrentWidth ? Color.accentColor.opacity(0.25) : .clear)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// The preset closest to the current width — highlighted in the preset
    /// row. "Closest" rather than "equal" so the image-proportional default
    /// width still highlights truthfully when clamping lands it between
    /// presets.
    private var nearestPresetToCurrentWidth: CGFloat? {
        controller.strokeWidthPresets.min {
            abs($0 - controller.strokeWidth) < abs($1 - controller.strokeWidth)
        }
    }

    /// A dot whose diameter previews a stroke width, log-scaled across
    /// `strokeWidthRange` to match the presets' geometric spacing.
    private func strokeDot(for width: CGFloat) -> some View {
        let range = controller.strokeWidthRange
        var position: CGFloat = 1
        if range.upperBound > range.lowerBound {
            position = log(width / range.lowerBound) / log(range.upperBound / range.lowerBound)
        }
        let diameter = 5 + min(max(position, 0), 1) * 11
        return Circle()
            .fill(.primary)
            .frame(width: diameter, height: diameter)
    }

    private var outputButtons: some View {
        HStack(spacing: 6) {
            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Copy annotated image")

            Button {
                onSaveAs()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Save annotated image as…")
        }
    }

    private static func symbolName(for tool: MarkupTool) -> String {
        switch tool {
        case .select: "cursorarrow"
        case .pen: "pencil.tip"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        }
    }

    private static func helpText(for tool: MarkupTool) -> String {
        switch tool {
        case .select: "Select and move markup"
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        }
    }
}
