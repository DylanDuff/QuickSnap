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
    var onSave: () -> Void
    var onSaveAs: () -> Void
    var onUpload: () -> Void
    var dragFile: AnnotatedFileDrag

    // Which output buttons show — configured in Settings → Markup; live
    // via @AppStorage so open windows follow changes. The settings UI
    // guarantees at least one stays on.
    @AppStorage(AppSettings.Keys.markupShowsCopyButton)
    private var showsCopyButton = AppSettings.Defaults.markupShowsCopyButton
    @AppStorage(AppSettings.Keys.markupShowsSaveButton)
    private var showsSaveButton = AppSettings.Defaults.markupShowsSaveButton
    @AppStorage(AppSettings.Keys.markupShowsSaveAsButton)
    private var showsSaveAsButton = AppSettings.Defaults.markupShowsSaveAsButton
    @AppStorage(AppSettings.Keys.markupShowsDragButton)
    private var showsDragButton = AppSettings.Defaults.markupShowsDragButton
    @AppStorage(AppSettings.Keys.markupShowsUploadButton)
    private var showsUploadButton = AppSettings.Defaults.markupShowsUploadButton
    /// Upload is only offered when a provider is actually switched on — the
    /// button's own toggle isn't enough, or it would appear and then fail.
    @AppStorage(AppSettings.Keys.uploadingEnabled)
    private var uploadingEnabled = AppSettings.Defaults.uploadingEnabled

    /// A preset row that can slide in over the pill's main controls.
    /// Selecting a color or stroke preset swaps back immediately; the shape
    /// row stays open (repeat insertions) until its ✕ dismisses it.
    private enum PresetRow {
        case color
        case stroke
        case shape
    }

    @State private var activePresetRow: PresetRow?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            switch activePresetRow {
            case .color:
                presetColorRow
                    .transition(rowTransition)
            case .stroke:
                presetStrokeRow
                    .transition(rowTransition)
            case .shape:
                presetShapeRow
                    .transition(rowTransition)
            case nil:
                mainControls
                    .transition(rowTransition)
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
    /// top edge while the incoming one rises in from the bottom. Reduced
    /// motion swaps the slide for a plain cross-fade.
    private var rowTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
    }

    private var mainControls: some View {
        HStack(spacing: 6) {
            toolButtons
            divider
            insertButton
            cropButton
            divider
            stylePickers
            if showsCopyButton || showsSaveButton || showsSaveAsButton || showsDragButton || showsUpload {
                divider
                outputButtons
            }
        }
    }

    private var cropButton: some View {
        ToolbarIconButton(systemImage: "crop", isActive: controller.isCropActive) {
            if controller.isCropActive {
                controller.cancelCrop()
            } else {
                controller.beginCrop()
            }
        }
        .help("Crop — drag out the area to keep, Return to apply")
    }

    /// Shared with `MarkupSettingsView`, which offers the same palette for
    /// the default-color setting.
    static let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .pink, .white, .black,
    ]

    /// One font weight per stroke step — how a step is *previewed* on the
    /// `scribble.variable` glyph, here and in `MarkupSettingsView`. Count
    /// matches `AppSettings.markupStrokeStepCount`.
    static let strokeStepWeights: [Font.Weight] = [.ultraLight, .light, .regular, .semibold, .black]

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
                .buttonStyle(PressScaleButtonStyle())
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
        ToolbarIconButton(systemImage: Self.symbolName(for: tool), isActive: controller.tool == tool) {
            controller.tool = tool
        }
        .help(Self.helpText(for: tool))
    }

    private var insertButton: some View {
        ToolbarIconButton(systemImage: "plus.square.on.square", isActive: controller.pendingInsertion != nil) {
            withAnimation(Self.rowSwapAnimation) { activePresetRow = .shape }
        }
        .help("Insert shape, line, or text")
    }

    /// Unlike the color/stroke rows this one doesn't swap back on selection —
    /// arming a shape leaves the row open for repeat insertions; the ✕ (or
    /// picking a color/stroke elsewhere) is what dismisses it.
    private var presetShapeRow: some View {
        HStack(spacing: 6) {
            shapeButton("rectangle", inserts: .shape(.roundedRectangle), help: "Rectangle — drag on the image to place it")
            shapeButton("oval", inserts: .shape(.ellipse), help: "Ellipse — drag on the image to place it")
            shapeButton("line.diagonal", inserts: .line(arrow: false), help: "Line — drag on the image to place it")
            shapeButton("arrow.up.right", inserts: .line(arrow: true), help: "Arrow — drag on the image to place it")
            ToolbarIconButton(systemImage: "character.textbox") {
                controller.insertTextbox()
            }
            .help("Insert text")
            divider
            ToolbarIconButton(systemImage: "xmark", iconSize: 12) {
                withAnimation(Self.rowSwapAnimation) { activePresetRow = nil }
            }
            .help("Close shape picker")
        }
    }

    /// Armed = accent-highlighted; clicking the armed shape again disarms
    /// it. Completing the drag on the canvas also disarms (the controller
    /// clears `pendingInsertion`), but the row stays open either way.
    private func shapeButton(_ systemImage: String, inserts insertion: PendingInsertion, help: String) -> some View {
        ToolbarIconButton(systemImage: systemImage, isActive: controller.pendingInsertion == insertion) {
            controller.pendingInsertion = controller.pendingInsertion == insertion ? nil : insertion
        }
        .help(help)
    }

    private var stylePickers: some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(Self.rowSwapAnimation) { activePresetRow = .color }
            } label: {
                colorSwatch(controller.color, size: 20)
            }
            .buttonStyle(PressScaleButtonStyle())
            .help("Markup color")
            Button {
                withAnimation(Self.rowSwapAnimation) { activePresetRow = .stroke }
            } label: {
                strokeSquiggle(for: controller.strokeWidth, size: 13)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(PressScaleButtonStyle())
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
                    strokeSquiggle(for: preset)
                        .frame(width: 28, height: 28)
                        .background(
                            Circle().fill(preset == nearestPresetToCurrentWidth ? Color.accentColor.opacity(0.25) : .clear)
                        )
                        .contentShape(Circle())
                }
                .buttonStyle(PressScaleButtonStyle())
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

    /// A variable-width squiggle (the same glyph PaperKit-style width
    /// pickers use) whose font weight previews a stroke width — the glyph
    /// stays the same size and its stroke gets heavier, like the brush
    /// itself would.
    private func strokeSquiggle(for width: CGFloat, size: CGFloat = 15) -> some View {
        Image(systemName: "scribble.variable")
            .font(.system(size: size, weight: weightForStrokeWidth(width)))
            .foregroundStyle(.primary)
    }

    /// Maps a stroke width to the nearest step's font weight, log-scaled
    /// across `strokeWidthRange` to match the presets' geometric spacing.
    private func weightForStrokeWidth(_ width: CGFloat) -> Font.Weight {
        let weights = Self.strokeStepWeights
        let range = controller.strokeWidthRange
        guard range.upperBound > range.lowerBound, width > 0 else { return .regular }
        let position = log(width / range.lowerBound) / log(range.upperBound / range.lowerBound)
        let index = Int((min(max(position, 0), 1) * CGFloat(weights.count - 1)).rounded())
        return weights[index]
    }

    /// The upload button needs both its own toggle and a live provider.
    private var showsUpload: Bool {
        showsUploadButton && uploadingEnabled
    }

    private var outputButtons: some View {
        HStack(spacing: 6) {
            if showsDragButton {
                ToolbarIconDragSource(systemImage: "document.viewfinder", payload: dragFile)
                    .help("Drag out as a file")
            }

            if showsCopyButton {
                ToolbarIconButton(systemImage: "doc.on.doc", action: onCopy)
                    .help("Copy annotated image")
            }

            if showsSaveButton {
                ToolbarIconButton(systemImage: "square.and.arrow.down", action: onSave)
                    .help("Save annotated image to your screenshots folder")
            }

            if showsSaveAsButton {
                ToolbarIconButton(systemImage: "square.and.arrow.down.on.square", action: onSaveAs)
                    .help("Save annotated image as…")
            }

            if showsUpload {
                ToolbarIconButton(systemImage: "arrow.up.circle", action: onUpload)
                    .help("Upload annotated image")
            }
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
