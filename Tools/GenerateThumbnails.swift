#!/usr/bin/env swift
//
//  GenerateThumbnails.swift
//  QuickSnap
//
//  Draws the option thumbnails used by `ImageOptionPicker` and writes them
//  into the asset catalog as imagesets with light and dark variants.
//
//  Run from the repo root:
//
//      swift Tools/GenerateThumbnails.swift
//
//  Lives outside `QuickSnap/` on purpose: that folder is a synchronized file
//  group, so a .swift file inside it would be compiled into the app target.
//
//  The thumbnails are illustrations, not live previews — they don't show the
//  user's real wallpaper or their chosen solid colour. Re-run this after
//  editing the drawing code and commit the regenerated PNGs.
//

import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - Geometry

/// Logical (point) size of every thumbnail. The picker scales images to fit
/// its own layout, so this is really just the aspect ratio plus enough
/// resolution to stay crisp — see `ImageOptionPicker.Layout`.
let tileSize = CGSize(width: 120, height: 84)

/// Where the mock window sits in the three padded styles. Deliberately
/// overruns the tile on the right and bottom: the window is understood to
/// continue past the frame, which reads as a screenshot rather than an icon.
/// Identical across those styles so switching options doesn't shift it.
let windowRect = CGRect(x: 38, y: 21, width: 96, height: 74)

let windowCornerRadius: CGFloat = 7

// MARK: - Palette

enum Appearance: String, CaseIterable {
    case light
    case dark
}

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

struct Theme {
    let windowFill: CGColor
    let windowStroke: CGColor
    /// The two checkerboard squares standing in for transparency.
    let checkerLight: CGColor
    let checkerDark: CGColor
    /// Illustrative background for the solid-colour option. Not the user's
    /// configured colour — picked per appearance so the mock window still
    /// reads against it.
    let solidFill: CGColor
    /// Wallpaper gradient, top-left to bottom-right.
    let wallpaperStops: [CGColor]
    let shadowAlpha: CGFloat

    static func of(_ appearance: Appearance) -> Theme {
        switch appearance {
        case .light:
            Theme(
                windowFill: color(0xECECEE),
                windowStroke: color(0xC6C6CB),
                checkerLight: color(0xFFFFFF),
                checkerDark: color(0xDEDEE2),
                solidFill: color(0xC9C9CE),
                wallpaperStops: [color(0x3E86C9), color(0x9FD0EA), color(0xE8F4FA)],
                shadowAlpha: 0.28
            )
        case .dark:
            Theme(
                windowFill: color(0x2C2C2E),
                windowStroke: color(0x4C4C50),
                checkerLight: color(0x3C3C3F),
                checkerDark: color(0x2E2E31),
                solidFill: color(0x4A4A4E),
                wallpaperStops: [color(0x14324F), color(0x2C6B99), color(0x74AECB)],
                shadowAlpha: 0.5
            )
        }
    }
}

/// Same in both appearances — traffic lights don't change colour.
let trafficLightColors = [color(0xFF5F57), color(0xFEBC2E), color(0x28C840)]

// MARK: - Drawing

func drawWindow(in context: CGContext, rect: CGRect, cornerRadius: CGFloat, theme: Theme, castsShadow: Bool) {
    let body = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    if castsShadow {
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: 3),
            blur: 7,
            color: color(0x000000, alpha: theme.shadowAlpha)
        )
        context.addPath(body)
        context.setFillColor(theme.windowFill)
        context.fillPath()
        context.restoreGState()
    } else {
        context.addPath(body)
        context.setFillColor(theme.windowFill)
        context.fillPath()
    }

    context.addPath(body.copy(strokingWithWidth: 1, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
    context.setFillColor(theme.windowStroke)
    context.fillPath()

    // Traffic lights, top-left, no separate title bar strip.
    let dotRadius: CGFloat = 3
    let dotSpacing: CGFloat = 9
    var center = CGPoint(x: rect.minX + 11, y: rect.minY + 11)
    for dot in trafficLightColors {
        context.setFillColor(dot)
        context.fillEllipse(in: CGRect(
            x: center.x - dotRadius,
            y: center.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
        center.x += dotSpacing
    }
}

func drawCheckerboard(in context: CGContext, bounds: CGRect, theme: Theme) {
    context.setFillColor(theme.checkerLight)
    context.fill(bounds)

    let square: CGFloat = 7
    context.setFillColor(theme.checkerDark)
    var row = 0
    var y = bounds.minY
    while y < bounds.maxY {
        var column = 0
        var x = bounds.minX
        while x < bounds.maxX {
            if (row + column).isMultiple(of: 2) {
                context.fill(CGRect(x: x, y: y, width: square, height: square).intersection(bounds))
            }
            x += square
            column += 1
        }
        y += square
        row += 1
    }
}

func drawWallpaper(in context: CGContext, bounds: CGRect, theme: Theme) {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let gradient = CGGradient(
        colorsSpace: space,
        colors: theme.wallpaperStops as CFArray,
        locations: [0, 0.55, 1]
    ) else { return }

    context.saveGState()
    context.clip(to: bounds)
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: bounds.minX, y: bounds.maxY),
        end: CGPoint(x: bounds.maxX, y: bounds.minY),
        options: []
    )

    // A soft highlight and two streaks — just enough structure to read as a
    // photograph rather than a flat gradient at thumbnail size.
    if let glow = CGGradient(
        colorsSpace: space,
        colors: [color(0xFFFFFF, alpha: 0.55), color(0xFFFFFF, alpha: 0)] as CFArray,
        locations: [0, 1]
    ) {
        context.drawRadialGradient(
            glow,
            startCenter: CGPoint(x: bounds.minX + 18, y: bounds.minY + 10),
            startRadius: 0,
            endCenter: CGPoint(x: bounds.minX + 18, y: bounds.minY + 10),
            endRadius: bounds.width * 0.6,
            options: []
        )
    }

    context.setStrokeColor(color(0xFFFFFF, alpha: 0.3))
    context.setLineWidth(3)
    context.setLineCap(.round)
    for offset in [CGFloat(-14), 16] {
        context.move(to: CGPoint(x: bounds.minX - 10, y: bounds.midY + offset))
        context.addCurve(
            to: CGPoint(x: bounds.maxX + 10, y: bounds.midY + offset - 26),
            control1: CGPoint(x: bounds.minX + bounds.width * 0.3, y: bounds.midY + offset + 14),
            control2: CGPoint(x: bounds.minX + bounds.width * 0.7, y: bounds.midY + offset - 30)
        )
        context.strokePath()
    }
    context.restoreGState()
}

// MARK: - Tiles

enum Style: String, CaseIterable {
    case wallpaper
    case transparent
    case solidColor
    case trimShadow

    /// Imageset name, matched by `WindowBackgroundStyle.thumbnailName`.
    var assetName: String {
        "WindowBackground" + rawValue.prefix(1).uppercased() + rawValue.dropFirst()
    }
}

func drawTile(_ style: Style, appearance: Appearance, in context: CGContext) {
    let theme = Theme.of(appearance)
    let bounds = CGRect(origin: .zero, size: tileSize)

    switch style {
    case .wallpaper:
        drawWallpaper(in: context, bounds: bounds, theme: theme)
    case .transparent:
        drawCheckerboard(in: context, bounds: bounds, theme: theme)
    case .solidColor:
        context.setFillColor(theme.solidFill)
        context.fill(bounds)
    case .trimShadow:
        // No background at all — the bare window, edge to edge, which is
        // exactly what this style produces.
        drawWindow(
            in: context,
            rect: bounds.insetBy(dx: -1, dy: -1),
            cornerRadius: windowCornerRadius,
            theme: theme,
            castsShadow: false
        )
        return
    }

    context.saveGState()
    context.clip(to: bounds)
    drawWindow(in: context, rect: windowRect, cornerRadius: windowCornerRadius, theme: theme, castsShadow: true)
    context.restoreGState()
}

// MARK: - Output

func renderPNG(_ style: Style, appearance: Appearance, scale: CGFloat, to url: URL) throws {
    let pixelWidth = Int(tileSize.width * scale)
    let pixelHeight = Int(tileSize.height * scale)
    guard let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw Failure("couldn't create a \(pixelWidth)×\(pixelHeight) bitmap context")
    }

    // Flip to a top-left origin so the drawing code above reads the same way
    // the thumbnail does.
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high

    drawTile(style, appearance: appearance, in: context)

    guard let image = context.makeImage() else { throw Failure("couldn't snapshot the bitmap context") }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw Failure("couldn't open \(url.lastPathComponent) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("couldn't encode \(url.lastPathComponent)") }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func contentsJSON(baseName: String) -> String {
    var entries: [String] = []
    for appearance in Appearance.allCases {
        for scale in [1, 2] {
            let suffix = scale == 1 ? "" : "@\(scale)x"
            let filename = "\(baseName)-\(appearance.rawValue)\(suffix).png"
            let appearances = appearance == .dark
                ? """
                      "appearances" : [
                        {
                          "appearance" : "luminosity",
                          "value" : "dark"
                        }
                      ],

                """
                : ""
            entries.append("""
                    {
                \(appearances)      "filename" : "\(filename)",
                      "idiom" : "universal",
                      "scale" : "\(scale)x"
                    }
                """)
        }
    }
    return """
    {
      "images" : [
    \(entries.joined(separator: ",\n"))
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
}

// MARK: - Main

let catalog = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("QuickSnap/Assets.xcassets")

guard FileManager.default.fileExists(atPath: catalog.path) else {
    FileHandle.standardError.write(Data("Run this from the repo root — no asset catalog at \(catalog.path)\n".utf8))
    exit(1)
}

do {
    for style in Style.allCases {
        let imageset = catalog.appendingPathComponent("\(style.assetName).imageset")
        try FileManager.default.createDirectory(at: imageset, withIntermediateDirectories: true)

        for appearance in Appearance.allCases {
            for scale in [1, 2] {
                let suffix = scale == 1 ? "" : "@\(scale)x"
                let url = imageset.appendingPathComponent("\(style.rawValue)-\(appearance.rawValue)\(suffix).png")
                try renderPNG(style, appearance: appearance, scale: CGFloat(scale), to: url)
            }
        }

        try contentsJSON(baseName: style.rawValue)
            .write(to: imageset.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
        print("wrote \(style.assetName).imageset")
    }
} catch {
    FileHandle.standardError.write(Data("failed: \(error)\n".utf8))
    exit(1)
}
