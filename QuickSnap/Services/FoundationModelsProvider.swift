//
//  FoundationModelsProvider.swift
//  QuickSnap
//

// `MemberImportVisibility` is on for this target, so Foundation has to be
// imported explicitly — FoundationModels re-exporting it isn't enough.
import Foundation
import FoundationModels

/// The on-device `AIProvider`, backed by Apple's Foundation Models
/// framework (macOS 26+, so unconditionally available at our deployment
/// target).
///
/// This is the right default for a tool that sees the user's screen:
/// nothing leaves the machine, there is no key to configure, and there is no
/// per-capture cost — so features built on it can be offered without a
/// privacy conversation.
///
/// **The system model takes no image input.** Its `respond` overloads accept
/// only `Prompt`/`String` (checked against the SDK's `.swiftinterface`, which
/// is ground truth here) — there is no image or attachment parameter. Every
/// task therefore describes the capture in text: Vision's OCR plus the
/// window it came from. That is a real ceiling on what the on-device path can
/// answer, and the reason `AIProvider`'s requests carry recognized text
/// rather than a `CGImage`.
nonisolated struct FoundationModelsProvider: AIProvider {
    var providerName: String { "Apple Intelligence" }

    var availability: AIAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .unavailable(.deviceNotSupported)
            case .appleIntelligenceNotEnabled: return .unavailable(.appleIntelligenceOff)
            case .modelNotReady: return .unavailable(.modelNotReady)
            @unknown default: return .unavailable(.modelNotReady)
            }
        }
    }

    func describeCapture(_ request: CaptureDescriptionRequest) async throws -> String {
        if case .unavailable(let reason) = availability {
            throw AIProviderError.unavailable(reason)
        }

        let session = LanguageModelSession(instructions: Self.descriptionInstructions)
        let response: LanguageModelSession.Response<CaptureDescription>
        do {
            response = try await session.respond(
                to: prompt(for: request),
                generating: CaptureDescription.self,
                // Greedy sampling so the same capture doesn't describe itself
                // differently on a retry — these descriptions end up in
                // filenames and indexes, where churn is worse than dullness.
                options: GenerationOptions(sampling: .greedy)
            )
        } catch let error as LanguageModelSession.GenerationError {
            throw AIProviderError.generationFailed(error.localizedDescription)
        }

        let summary = response.content.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw AIProviderError.emptyResponse }
        return summary
    }

    // MARK: - Prompt

    private static let descriptionInstructions = """
        You label screenshots of computer software. Given the text visible in \
        a screenshot and the app it came from, reply with a short phrase \
        naming what the screenshot shows — the screen, dialog, error or task, \
        not the app itself.

        Write three to six plain words, lowercase, no punctuation and no \
        trailing period. Prefer wording that appears on screen. Never invent \
        detail that is not in the text you were given.
        """

    private func prompt(for request: CaptureDescriptionRequest) -> String {
        var lines: [String] = []
        if let appName = request.appName {
            lines.append("App: \(appName)")
        }
        if let windowTitle = request.windowTitle, !windowTitle.isEmpty {
            lines.append("Window: \(windowTitle)")
        }

        let text = Self.truncated(request.recognizedText)
        lines.append(text.isEmpty ? "The screenshot contains no readable text." : "Visible text:\n\(text)")
        return lines.joined(separator: "\n")
    }

    /// A full-screen capture's OCR can run to tens of thousands of
    /// characters, which overflows the context window and fails the whole
    /// request. The opening of a screen is also where its identifying text
    /// (titles, headings, the error) almost always is, so taking the head is
    /// both the cheap fix and the right one.
    private static func truncated(_ text: String, limit: Int = 4000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }
}

/// Guided-generation shape for `describeCapture`. Constraining the output to
/// one named field is what keeps the model from answering with a sentence of
/// preamble around the phrase we actually want.
@Generable
private struct CaptureDescription {
    @Guide(description: "A three-to-six word lowercase phrase naming what the screenshot shows.")
    var summary: String
}
