//
//  ImageResizer.swift
//  QuickSnap
//

import CoreGraphics

/// Proportional downscaling, for the one place that needs a smaller copy of a
/// capture rather than the real thing: images returned over MCP.
///
/// A retina full-screen capture is several thousand pixels wide and, once
/// base64'd into a JSON-RPC response, runs to tens of megabytes — enough to
/// blow a model's context on a single tool call. The MCP tools send a
/// downscaled copy inline and hand back the full-resolution file path
/// alongside it, so an agent that needs the detail can read the file.
nonisolated enum ImageResizer {
    /// `image` scaled so its longest edge is at most `maxDimension`, or the
    /// original when it already fits (or when the redraw fails — a slightly
    /// large image beats none).
    static func downscaled(_ image: CGImage, maxDimension: Int) -> CGImage {
        let longestEdge = max(image.width, image.height)
        guard longestEdge > maxDimension, maxDimension > 0 else { return image }

        let scale = Double(maxDimension) / Double(longestEdge)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))

        guard let colorSpace = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
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

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }
}
