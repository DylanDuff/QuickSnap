//
//  WindowBackgroundRenderer.swift
//  QuickSnap
//

import AppKit

/// Composites a Window-mode capture onto its configured background:
/// padding around the window, a soft drawn shadow, and wallpaper / solid
/// color / transparency behind it. The input is expected to have its alpha
/// preserved and the system shadow excluded (see
/// `ScreenCaptureManager.captureWindow`) — the window's own rounded-corner
/// alpha is what shapes the drawn shadow.
/// `nonisolated` so the wallpaper file read (potentially TCC-gated,
/// depending on where the wallpaper lives) and the compositing can run off
/// the main thread.
nonisolated enum WindowBackgroundRenderer {
    /// - Parameters:
    ///   - paddingPixels: padding on each side, already in pixels (points ×
    ///     backing scale — everything here is in the capture's pixel space).
    ///   - wallpaper: only consulted for `.wallpaper`; when nil (couldn't be
    ///     loaded) that style falls back to the solid color.
    static func render(
        window image: CGImage,
        style: WindowBackgroundStyle,
        paddingPixels: CGFloat,
        backgroundColor: NSColor,
        wallpaper: CGImage?
    ) -> CGImage {
        guard style != .trimShadow else { return image }

        let padding = max(0, paddingPixels.rounded())
        let canvasWidth = image.width + Int(padding) * 2
        let canvasHeight = image.height + Int(padding) * 2

        guard let context = CGContext(
            data: nil,
            width: canvasWidth,
            height: canvasHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }

        let canvasRect = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)

        switch style {
        case .solidColor:
            fill(canvasRect, with: backgroundColor, in: context)
        case .wallpaper:
            if let wallpaper {
                drawAspectFill(wallpaper, into: canvasRect, in: context)
            } else {
                fill(canvasRect, with: backgroundColor, in: context)
            }
        case .transparent, .trimShadow:
            break
        }

        // Shadow scaled to the padding so it never visibly clips at the
        // canvas edge; negative Y offset drops it below the window in CG's
        // bottom-left-origin space.
        if padding > 0 {
            context.setShadow(
                offset: CGSize(width: 0, height: -padding * 0.18),
                blur: padding * 0.55,
                color: CGColor(gray: 0, alpha: 0.4)
            )
        }
        context.draw(image, in: CGRect(x: padding, y: padding, width: CGFloat(image.width), height: CGFloat(image.height)))

        return context.makeImage() ?? image
    }

    /// Loads the wallpaper image for the `.wallpaper` style. The URL comes
    /// from `NSWorkspace.desktopImageURL(for:)`, resolved by the caller on
    /// the main thread — this file read runs off it.
    static func wallpaper(at url: URL?) -> CGImage? {
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private static func fill(_ rect: CGRect, with color: NSColor, in context: CGContext) {
        context.setFillColor(color.usingColorSpace(.sRGB)?.cgColor ?? color.cgColor)
        context.fill(rect)
    }

    /// Draws `image` scaled to cover `rect` entirely (center-cropped), like
    /// the desktop draws the wallpaper itself.
    private static func drawAspectFill(_ image: CGImage, into rect: CGRect, in context: CGContext) {
        let imageSize = CGSize(width: image.width, height: image.height)
        guard imageSize.width > 0, imageSize.height > 0 else { return }

        let scale = max(rect.width / imageSize.width, rect.height / imageSize.height)
        let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = CGRect(
            x: rect.midX - drawSize.width / 2,
            y: rect.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )

        context.saveGState()
        context.clip(to: rect)
        context.draw(image, in: drawRect)
        context.restoreGState()
    }
}
