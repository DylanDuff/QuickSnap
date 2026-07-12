//
//  ToastView.swift
//  QuickSnap
//

import SwiftUI

/// The transient confirmation pill shown by `ToastController` (e.g. "Text
/// copied" after an OCR capture). Pure presentation — it doesn't dismiss
/// itself; the controller owns timing. An optional `detail` line shows a
/// preview of what was copied, truncated to two lines.
struct ToastView: View {
    let message: String
    let systemImage: String
    var detail: String?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            if let detail {
                VStack(alignment: .leading, spacing: 2) {
                    Text(message)
                        .font(.system(size: 13, weight: .medium))

                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .frame(maxWidth: 320, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(message)
                    .font(.system(size: 13, weight: .medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: shape)
        .overlay(
            shape.stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .padding(2)
    }

    /// Pill for a bare message; softer rounded rect once the two-line
    /// detail makes a capsule's end-caps look swollen.
    private var shape: AnyShape {
        detail == nil
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}


#Preview {
    VStack(spacing: 12) {
        ToastView(message: "No text found", systemImage: "text.magnifyingglass")
        ToastView(
            message: "Text copied to clipboard",
            systemImage: "checkmark.circle.fill",
            detail: "let styled = await Task.detached(priority: .userInitiated) {\nWindowBackgroundRenderer.render(window: image, style: style)"
        )
    }
    .padding()
}
