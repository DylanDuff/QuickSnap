//
//  RedactionOverlay.swift
//  QuickSnap
//

import SwiftUI

/// Review surface shown over the markup canvas while a detector has flagged
/// something (`MarkupCanvasController.pendingRedactions`): each finding is
/// outlined where it sits in the image, clicking one blacks it out for good,
/// and the bar offers "Redact All" or dismissal.
///
/// Like `CropOverlay` and `ShapeInsertionOverlay`, this **must render pixels
/// across the canvas** — the dim — so the window server routes mouse input to
/// the host app rather than straight into the remote PaperKit surface, and it
/// must only be mounted while there's something to review (see CLAUDE.md).
///
/// The dim does double duty here: it's what makes the highlighted regions
/// read as "look at these" rather than as decoration on an otherwise normal
/// editing session.
struct RedactionOverlay: View {
    @ObservedObject var controller: MarkupCanvasController

    @State private var hoveredID: SensitiveMatch.ID?

    private enum Layout {
        static let cornerRadius: CGFloat = 3
        static let outlineWidth: CGFloat = 2
        static let barSpacing: CGFloat = 8
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.28)
                    .contentShape(Rectangle())

                ForEach(controller.pendingRedactions) { match in
                    let frame = viewRect(for: match.rect, in: geometry.size)
                    region(for: match, frame: frame)
                }

                reviewBar(in: geometry.size)
            }
        }
        .background(keyboardShortcuts)
    }

    // MARK: - Regions

    @ViewBuilder
    private func region(for match: SensitiveMatch, frame: CGRect) -> some View {
        let isHovered = hoveredID == match.id
        let tint: Color = match.kind.holdsUpload ? .orange : .yellow

        Button {
            controller.redact([match])
        } label: {
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .fill(tint.opacity(isHovered ? 0.45 : 0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                        .strokeBorder(tint, lineWidth: Layout.outlineWidth)
                )
        }
        .buttonStyle(.plain)
        .help("\(match.kind.label) — \(match.preview). Click to black it out.")
        .frame(width: max(frame.width, 8), height: max(frame.height, 8))
        .offset(x: frame.minX, y: frame.minY)
        .onHover { hovering in
            hoveredID = hovering ? match.id : (hoveredID == match.id ? nil : hoveredID)
        }
        .overlay(alignment: .topLeading) {
            if isHovered {
                Text(match.kind.label)
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(tint, in: Capsule())
                    .foregroundStyle(.black)
                    .fixedSize()
                    .offset(x: frame.minX, y: frame.minY - 20)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Bar

    private func reviewBar(in size: CGSize) -> some View {
        let holding = controller.pendingRedactions.filter(\.kind.holdsUpload).count

        return HStack(spacing: Layout.barSpacing) {
            Image(systemName: holding > 0 ? "exclamationmark.triangle.fill" : "eye.trianglebadge.exclamationmark")
                .foregroundStyle(holding > 0 ? .orange : .yellow)

            VStack(alignment: .leading, spacing: 1) {
                Text(summary)
                    .font(.callout.weight(.medium))
                Text("Click a highlight to black it out. Redaction is permanent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button(controller.continueHeldUpload == nil ? "Redact All" : "Redact All & Upload") {
                controller.redactAllPending()
            }
            .keyboardShortcut(.defaultAction)

            if controller.continueHeldUpload != nil {
                Button("Upload Anyway") { controller.uploadHeldCaptureAsIs() }
            }

            Button(controller.continueHeldUpload == nil ? "Keep" : "Don't Upload") {
                controller.dismissRedactionReview()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .fixedSize()
        .frame(width: size.width, alignment: .center)
        .offset(y: 12)
    }

    private var summary: String {
        let counts = Dictionary(grouping: controller.pendingRedactions, by: \.kind)
            .map { "\($0.value.count) \($0.key.label.lowercased())\($0.value.count == 1 ? "" : "s")" }
            .sorted()
        return counts.joined(separator: ", ")
    }

    // MARK: - Geometry

    /// Canvas pixels → view points. Goes through `visibleCanvasFrame` rather
    /// than assuming fit, so the highlights stay on their text when the user
    /// zooms or pans to read one (see CLAUDE.md).
    private func viewRect(for canvasRect: CGRect, in size: CGSize) -> CGRect {
        let visible = controller.visibleCanvasFrame
        guard visible.width > 0 else { return .zero }
        let scale = size.width / visible.width
        return CGRect(
            x: (canvasRect.minX - visible.minX) * scale,
            y: (canvasRect.minY - visible.minY) * scale,
            width: canvasRect.width * scale,
            height: canvasRect.height * scale
        )
    }

    /// Esc keeps everything as it is — the same "get me out of this mode"
    /// meaning it has in crop and shape insertion.
    private var keyboardShortcuts: some View {
        Button("") { controller.dismissRedactionReview() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}
