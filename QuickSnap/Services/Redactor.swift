//
//  Redactor.swift
//  QuickSnap
//

import CoreGraphics

/// Burns opaque boxes into a capture.
///
/// **This is destructive, and that is the whole point.** A blur or a black
/// rectangle drawn as markup is an object in an editable document: it can be
/// selected, moved and deleted, and every export path that doesn't flatten
/// it leaks what it was covering. Redaction replaces the pixels — after this
/// runs, the covered text is not in the image any more, in any layer, at any
/// resolution.
///
/// Solid black rather than a blur or pixelation for the same reason: heavy
/// pixelation of a short string is theoretically recoverable, which is an
/// unacceptable property for an API key, and a black box also reads
/// unambiguously as "removed on purpose" to whoever receives the screenshot.
nonisolated enum Redactor {
    /// Slack around each box, in pixels. Text boxes from Vision hug the
    /// glyphs, and an antialiased edge left poking out is both ugly and, for
    /// a short token, occasionally readable.
    static let padding: CGFloat = 3

    /// Returns a copy of `image` with `rects` painted out. Rects are in the
    /// image's own pixel space with a **top-left origin** — the space Vision
    /// converts to and the markup canvas uses — and are flipped here for
    /// Core Graphics, which is bottom-left.
    ///
    /// Returns `image` unchanged when there's nothing to redact or a context
    /// can't be made, so a caller can always use the result.
    static func redacting(_ image: CGImage, rects: [CGRect]) -> CGImage {
        guard !rects.isEmpty else { return image }

        let width = image.width
        let height = image.height
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return image
        }

        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image, in: bounds)
        context.setFillColor(gray: 0, alpha: 1)

        for rect in rects {
            let padded = rect.insetBy(dx: -padding, dy: -padding)
            let flipped = CGRect(
                x: padded.minX,
                y: CGFloat(height) - padded.maxY,
                width: padded.width,
                height: padded.height
            )
            context.fill(flipped.intersection(bounds).integral)
        }

        return context.makeImage() ?? image
    }
}
