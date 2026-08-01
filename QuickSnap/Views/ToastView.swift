//
//  ToastView.swift
//  QuickSnap
//

import SwiftUI

/// The transient confirmation pill shown by `ToastController` (e.g. "Text
/// copied" after an OCR capture). Pure presentation — it doesn't dismiss
/// itself; the controller owns timing. An optional `detail` line shows a
/// preview of what was copied, wrapped to at most two lines.
struct ToastView: View {
    let message: String
    let systemImage: String
    var detail: String?

    enum Layout {
        /// Widest the whole pill may get, and the only thing that limits how
        /// far the detail line runs before wrapping — it works as a width
        /// *proposal* from `ToastController`, so shorter text still
        /// shrink-wraps. Don't reach for `.frame(maxWidth:)` on the detail
        /// instead: a flexible frame grows to fill the proposal, which pads
        /// every toast out to full width. And don't measure with
        /// `NSHostingView.fittingSize` — that's a *minimum* size, so wrapping
        /// text collapses to its narrowest layout and even a short detail
        /// comes back wrapped and truncated.
        static let maxWidth: CGFloat = 400
        /// Kept off the pill's own edges so the panel's shadow isn't clipped.
        static let shadowInset: CGFloat = 2
    }

    var body: some View {
        HStack(alignment: detailText == nil ? .center : .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 3) {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)

                if let detailText {
                    Text(detailText)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, detailText == nil ? 10 : 12)
        .background(.regularMaterial, in: shape)
        .overlay(shape.stroke(.quaternary, lineWidth: 1))
        .padding(Layout.shadowInset)
    }

    /// Runs of whitespace — including the newlines a multi-line OCR grab is
    /// full of — collapse to single spaces, so the two available lines carry
    /// as much of the copied text as they can. The clipboard keeps the
    /// original; this is preview text only.
    private var detailText: String? {
        guard let detail else { return nil }
        let collapsed = detail.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Pill for a bare message; softer rounded rect once the two-line
    /// detail makes a capsule's end-caps look swollen.
    private var shape: AnyShape {
        detailText == nil
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}


#Preview {
    VStack(spacing: 12) {
        ToastView(message: "No text found", systemImage: "text.magnifyingglass")
        ToastView(
            message: "Text copied to clipboard",
            systemImage: "checkmark.circle.fill",
            detail: "It has no drawing"
        )
        ToastView(
            message: "Text copied to clipboard",
            systemImage: "checkmark.circle.fill",
            detail: "let styled = await Task.detached(priority: .userInitiated) {\nWindowBackgroundRenderer.render(window: image, style: style)"
        )
    }
    .frame(width: ToastView.Layout.maxWidth)
    .padding()
}
