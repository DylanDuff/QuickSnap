//
//  TextRecognizer.swift
//  QuickSnap
//

import CoreGraphics
import Vision

/// On-device OCR via Vision's modern Swift API (`RecognizeTextRequest`,
/// macOS 15+). Nothing leaves the machine.
nonisolated enum TextRecognizer {
    /// Recognized text in `image`, top-to-bottom, one line per observation.
    /// Empty string when no text was detected.
    static func recognizeText(in image: CGImage) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let observations = try await request.perform(on: image)
        return observations
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: "\n")
    }
}
