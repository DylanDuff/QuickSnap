//
//  ScreenshotSaver.swift
//  QuickSnap
//

import AppKit

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

    /// The `QuickSnap yyyy-MM-dd at HH.mm.ss` naming convention, minus the
    /// extension — also used as the suggested Save As… name when a capture
    /// was never written to disk.
    static func timestampedName(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "QuickSnap \(formatter.string(from: date))"
    }

    @discardableResult
    static func save(_ image: CGImage) throws -> URL {
        try prepareSaveDirectory()

        let url = saveDirectory.appendingPathComponent("\(timestampedName()).png")
        try writePNG(image, to: url)
        return url
    }

    /// PNG-encodes `image`. The single encoder shared by everything that
    /// needs PNG bytes — writing to disk and uploading to Immich.
    static func pngData(_ image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw ScreenshotSaverError.encodingFailed
        }
        return data
    }

    /// Writes `image` as PNG to a specific URL rather than minting a fresh
    /// timestamped name — used by Save As… for annotated screenshots.
    static func writePNG(_ image: CGImage, to url: URL) throws {
        try pngData(image).write(to: url)
    }

    /// Writes a PNG to a unique temporary location — `baseName` if given
    /// (the annotation toolbar's drag-out names the dropped file), else the
    /// timestamped naming convention (the preview panel's drag-out for
    /// captures never saved to disk). The OS owns cleanup of the temporary
    /// directory.
    static func writeTemporaryPNG(_ image: CGImage, named baseName: String? = nil) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickSnap Drags", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("\(baseName ?? timestampedName()).png")
        try writePNG(image, to: url)
        return url
    }

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
}
