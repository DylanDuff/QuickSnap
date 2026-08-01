//
//  CaptureAnalyzer.swift
//  QuickSnap
//

// `MemberImportVisibility` is on for this target, so Foundation has to be
// imported explicitly for `trimmingCharacters(in:)`.
import CoreGraphics
import Foundation

/// Reads what a capture *contains*: its on-screen text, and a short prose
/// description of what it shows.
///
/// One pass, because both consumers want both halves and the expensive part
/// is shared — the on-device model takes no image input (see
/// `FoundationModelsProvider`), so a description is OCR plus the window it
/// came from. Running OCR once for the filename and again for the index
/// would double the cost of every capture for the same answer.
///
/// Nothing here throws. Both halves are enrichment: a capture whose text
/// can't be read, or whose description the model declines to produce, is
/// still a perfectly good screenshot. Callers fall back to their non-AI
/// behaviour on a nil `description`.
nonisolated enum CaptureAnalyzer {
    struct Analysis: Sendable {
        /// On-screen text, empty when there is none (or OCR failed).
        let recognizedText: String
        /// Prose, e.g. "login form validation error". Nil when intelligence
        /// is switched off, the provider is unavailable, or the model
        /// returned nothing usable.
        let description: String?
    }

    /// `describes: false` skips the model entirely and returns OCR alone —
    /// what the index wants when the user hasn't switched intelligence on.
    static func analyze(
        _ image: CGImage,
        appName: String? = nil,
        windowTitle: String? = nil,
        describes: Bool = true
    ) async -> Analysis {
        let recognizedText = (try? await TextRecognizer.recognizeText(in: image)) ?? ""

        guard describes, let provider = AppSettings.aiProvider, provider.availability.isAvailable else {
            return Analysis(recognizedText: recognizedText, description: nil)
        }

        let description = try? await provider.describeCapture(
            CaptureDescriptionRequest(
                recognizedText: recognizedText,
                appName: appName,
                windowTitle: windowTitle
            )
        )
        let trimmed = description?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Analysis(
            recognizedText: recognizedText,
            description: trimmed?.isEmpty == false ? trimmed : nil
        )
    }
}
