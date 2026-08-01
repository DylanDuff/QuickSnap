//
//  ScreenshotSaver.swift
//  QuickSnap
//

import AppKit
import UniformTypeIdentifiers

enum ScreenshotSaverError: Error {
    case encodingFailed
}

/// `nonisolated`: file writes must be callable off the main thread — the
/// first write into a TCC-protected folder (e.g. ~/Documents) blocks inside
/// the syscall until the user answers the system privacy prompt, and doing
/// that on the main thread freezes the whole app (see CLAUDE.md).
nonisolated enum ScreenshotSaver {
    static var saveDirectory: URL {
        AppSettings.saveFolder
    }

    /// Creates the save folder if needed. Doubles as the deliberate first
    /// touch of the TCC-protected location so the system consent prompt can
    /// be triggered at a controlled moment — call off the main thread.
    static func prepareSaveDirectory() throws {
        try FileManager.default.createDirectory(at: saveDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Naming

    /// The filename (no extension) for a capture, per the user's template.
    /// Falls back to the default template when unset — so the out-of-box
    /// naming is still `QuickSnap yyyy-MM-dd at HH.mm.ss`.
    static func name(for context: FilenameContext = FilenameContext()) -> String {
        resolvedName(for: context).value
    }

    /// The same name, but keeping the inputs it was rendered from — so a
    /// `{describe}` rename can re-render the template later without every
    /// other token drifting. Advances the `{counter}` exactly once, like
    /// `name(for:)` does.
    static func resolvedName(for context: FilenameContext = FilenameContext()) -> ResolvedFilename {
        ResolvedFilename(
            template: AppSettings.filenameTemplate,
            context: context,
            counter: AppSettings.nextFilenameCounter()
        )
    }

    /// Legacy convenience for the places that just want a timestamped name
    /// and have no capture context: the Save As… suggestion and drag-out
    /// naming for captures that were never written to disk.
    static func timestampedName(for date: Date = Date()) -> String {
        name(for: FilenameContext(date: date))
    }

    // MARK: - Encoding

    /// Encodes `image` in `format`. The single encoder shared by everything
    /// that needs image bytes — disk writes and uploads alike.
    ///
    /// `quality` (0…1) applies only to lossy formats.
    static func imageData(
        _ image: CGImage,
        format: ImageFormat = AppSettings.imageFormat,
        quality: Double = AppSettings.imageQuality
    ) throws -> Data {
        let format = effectiveFormat(for: image, requested: format)

        switch format {
        case .png:
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else {
                throw ScreenshotSaverError.encodingFailed
            }
            return data

        case .jpeg:
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(
                using: .jpeg,
                properties: [.compressionFactor: quality]
            ) else {
                throw ScreenshotSaverError.encodingFailed
            }
            return data

        case .heic:
            // NSBitmapImageRep has no HEIC writer; go through ImageIO.
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(
                output, format.contentType.identifier as CFString, 1, nil
            ) else {
                throw ScreenshotSaverError.encodingFailed
            }
            CGImageDestinationAddImage(destination, image, [
                kCGImageDestinationLossyCompressionQuality: quality,
            ] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else {
                throw ScreenshotSaverError.encodingFailed
            }
            return output as Data
        }
    }

    /// JPEG can't carry an alpha channel, and a transparent window capture
    /// flattened onto black is almost never what someone wants — so a
    /// capture with real transparency silently stays PNG. Nothing is lost;
    /// the file is just bigger than asked for.
    static func effectiveFormat(for image: CGImage, requested: ImageFormat) -> ImageFormat {
        guard requested.discardsAlpha, hasAlpha(image) else { return requested }
        return .png
    }

    private static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .first, .last, .premultipliedFirst, .premultipliedLast:
            return true
        default:
            return false
        }
    }

    // MARK: - Writing

    /// Saves into the configured folder under the user's naming template,
    /// returning the URL actually written (which may differ from the first
    /// choice if that name was taken).
    @discardableResult
    static func save(_ image: CGImage, context: FilenameContext = FilenameContext()) throws -> URL {
        try save(image, name: resolvedName(for: context))
    }

    /// Saves under an already-resolved name, for the capture path — which
    /// keeps the name around so a `{describe}` rename can re-render it.
    @discardableResult
    static func save(_ image: CGImage, name: ResolvedFilename) throws -> URL {
        try prepareSaveDirectory()

        let format = effectiveFormat(for: image, requested: AppSettings.imageFormat)
        let url = uniqueURL(
            in: saveDirectory,
            baseName: name.value,
            fileExtension: format.fileExtension
        )
        try write(image, to: url, format: format)
        return url
    }

    /// Renames a saved capture in place, keeping its extension and taking a
    /// free name on collision. Returns the URL the file now lives at — the
    /// original when the name didn't change.
    ///
    /// The `FileTag` xattr rides along with the move (verified: `mv` within
    /// a volume preserves extended attributes), so retention still
    /// recognises the file afterwards. Don't reimplement this as
    /// copy-then-delete, which would drop the tag and orphan the file from
    /// cleanup.
    @discardableResult
    static func rename(_ url: URL, toBaseName baseName: String) throws -> URL {
        let target = uniqueURL(
            in: url.deletingLastPathComponent(),
            baseName: baseName,
            fileExtension: url.pathExtension
        )
        guard target != url else { return url }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Writes `image` to a specific URL, inferring the format from the URL's
    /// extension so an `NSSavePanel` choice is honoured. Used by Save As….
    static func write(_ image: CGImage, to url: URL, format: ImageFormat? = nil) throws {
        let format = format ?? ImageFormat.allCases.first {
            $0.fileExtension.caseInsensitiveCompare(url.pathExtension) == .orderedSame
        } ?? AppSettings.imageFormat

        try imageData(image, format: format).write(to: url)
        // Tag it as ours so retention can safely clean up later without ever
        // touching files QuickSnap didn't create.
        FileTag.mark(url)
    }

    /// Writes to a unique temporary location — `baseName` if given (the
    /// annotation toolbar's drag-out names the dropped file), else the
    /// naming template. The OS owns cleanup of the temporary directory.
    static func writeTemporaryImage(
        _ image: CGImage,
        named baseName: String? = nil,
        format requestedFormat: ImageFormat? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSnap Drags", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let format = effectiveFormat(for: image, requested: requestedFormat ?? AppSettings.imageFormat)
        let url = directory.appendingPathComponent(
            "\(baseName ?? name()).\(format.fileExtension)"
        )
        try write(image, to: url, format: format)
        return url
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext`… if taken. Templates
    /// without a time or counter token (`{app}` alone, say) collide
    /// constantly, and silently overwriting a previous capture would be the
    /// worst possible outcome.
    private static func uniqueURL(in directory: URL, baseName: String, fileExtension: String) -> URL {
        let candidate = directory.appendingPathComponent("\(baseName).\(fileExtension)")
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        for suffix in 2...999 {
            let next = directory.appendingPathComponent("\(baseName) \(suffix).\(fileExtension)")
            if !FileManager.default.fileExists(atPath: next.path) { return next }
        }
        // Pathological: fall back to something guaranteed unique.
        return directory.appendingPathComponent("\(baseName) \(UUID().uuidString).\(fileExtension)")
    }

    // MARK: - Clipboard

    static func copyToClipboard(_ image: CGImage) {
        let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([nsImage])
    }

    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Puts `image` and `text` on the clipboard as **one item with two
    /// representations**, so whichever the paste target understands is what
    /// it gets: a terminal takes the text, a chat window takes the picture.
    /// Two separate items wouldn't do — most readers only ever look at the
    /// first one.
    ///
    /// Kept apart from `copyToClipboard(_ image:)`, which writes an `NSImage`
    /// and lets AppKit offer its full set of representations. That's the more
    /// compatible write for an image alone, but it can't carry the text
    /// alongside.
    static func copyToClipboard(_ image: CGImage, text: String) {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if let png = try? imageData(image, format: .png) {
            item.setData(png, forType: .png)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
    }
}
