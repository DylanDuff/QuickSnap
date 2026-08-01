//
//  CaptureContextMarkdown.swift
//  QuickSnap
//

import Foundation

/// Renders a capture and what we know about it as a markdown block, for the
/// Copy for AI action.
///
/// Pasting a bare screenshot into a chat tool throws away everything around
/// it — which app it came from, what the window was called, and any text in
/// the image the model then has to re-read out of pixels. This is that
/// context, in a shape every chat tool accepts.
///
/// The image is referenced by **path** rather than described as attached,
/// because the most valuable reader is a coding agent that can open the file
/// itself. The same clipboard write also carries the image data, so a target
/// that pastes pictures and ignores text still gets the screenshot — see
/// `ScreenshotSaver.copyToClipboard(_:text:)`.
nonisolated enum CaptureContextMarkdown {
    static func render(
        imageURL: URL?,
        appName: String?,
        windowTitle: String?,
        capturedAt: Date = Date(),
        recognizedText: String? = nil
    ) -> String {
        var lines = ["![Screenshot](\(imageReference(imageURL)))"]

        if let appName, !appName.isEmpty {
            let window = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let window, !window.isEmpty, window != appName {
                lines.append("App: \(appName) — \(window)")
            } else {
                lines.append("App: \(appName)")
            }
        }
        lines.append("Captured: \(timestampFormatter.string(from: capturedAt))")

        let text = recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty {
            lines.append("")
            lines.append("Text in image:")
            lines.append(text)
        }

        return lines.joined(separator: "\n")
    }

    /// Markdown link destinations can't contain bare spaces, and a capture's
    /// filename contains several by default — the angle-bracket form is the
    /// spec's own escape for exactly this.
    private static func imageReference(_ url: URL?) -> String {
        guard let url else { return "attached" }
        let path = url.path
        return path.contains(" ") ? "<\(path)>" : path
    }

    /// Plain and sortable rather than locale-formatted: the reader is a
    /// model, and an unambiguous date beats a familiar one.
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
