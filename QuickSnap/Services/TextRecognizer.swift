//
//  TextRecognizer.swift
//  QuickSnap
//

import CoreGraphics
import Foundation
import Vision

/// One line of recognized text and where it sits in the image.
///
/// `boundingBox(for:)` is what makes redaction precise: Vision can box an
/// arbitrary substring of a line, so a detected API key is covered by a box
/// around the key itself rather than the whole line it happened to appear on
/// — which would black out the label, the surrounding prose, and often half
/// a settings row.
nonisolated struct RecognizedTextLine: Sendable {
    let text: String
    /// The whole line, in image pixel coordinates, top-left origin — the
    /// same space `CGImage` and the markup canvas use.
    let frame: CGRect
    /// Boxes a range of `text`. Nil when Vision can't place the range, in
    /// which case callers fall back to `frame`.
    let boundingBox: @Sendable (Range<String.Index>) -> CGRect?
}

/// On-device OCR via Vision's modern Swift API (`RecognizeTextRequest`,
/// macOS 15+). Nothing leaves the machine.
nonisolated enum TextRecognizer {
    /// Recognized text in `image`, top-to-bottom, one line per observation.
    /// Empty string when no text was detected.
    static func recognizeText(in image: CGImage) async throws -> String {
        try await recognizeLines(in: image)
            .map(\.text)
            .joined(separator: "\n")
    }

    /// The same recognition, but keeping each line's geometry — what
    /// redaction needs, and what `recognizeText` is written in terms of so
    /// there's only one Vision call to keep configured correctly.
    static func recognizeLines(in image: CGImage) async throws -> [RecognizedTextLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let imageSize = CGSize(width: image.width, height: image.height)
        let observations = try await request.perform(on: image)

        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedTextLine(
                text: candidate.string,
                frame: Self.pixelRect(observation.boundingBox, in: imageSize),
                boundingBox: { range in
                    guard let box = candidate.boundingBox(for: range) else { return nil }
                    return Self.pixelRect(box.boundingBox, in: imageSize)
                }
            )
        }
    }

    /// Vision reports normalized coordinates; `.upperLeft` converts straight
    /// into the image's own pixel space, so nothing downstream has to flip.
    private static func pixelRect(_ box: NormalizedRect, in imageSize: CGSize) -> CGRect {
        box.toImageCoordinates(imageSize, origin: .upperLeft)
    }
}
