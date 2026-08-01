//
//  CaptureLibrary.swift
//  QuickSnap
//

import CoreGraphics
import Foundation
import ImageIO

/// Read access to the save folder, as a list of captures rather than a list
/// of files.
///
/// **Only files QuickSnap tagged are ever visible here** (`FileTag`), the
/// same invariant that makes retention safe. The save folder is user-chosen
/// and the app is unsandboxed, so an unfiltered listing would let anything
/// reading this — including an MCP client — enumerate and fetch files
/// QuickSnap never wrote.
nonisolated enum CaptureLibrary {
    struct Entry: Sendable {
        let url: URL
        let name: String
        let modifiedAt: Date
        let byteCount: Int
    }

    /// The newest `limit` captures, most recent first.
    static func recent(limit: Int) -> [Entry] {
        entries()
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .prefix(max(0, limit))
            .map { $0 }
    }

    /// Looks a capture up by file name. Any path component in `name` is
    /// rejected outright rather than resolved — the name comes off the wire,
    /// and `../` in it must not walk out of the save folder.
    static func entry(named name: String) -> Entry? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
        let url = AppSettings.saveFolder.appendingPathComponent(name)
        guard FileTag.isMarked(url) else { return nil }
        return entry(at: url)
    }

    /// Every capture in the save folder, newest first — the backfill's work
    /// list. Same tag filter as everything else here.
    static func all() -> [Entry] {
        entries().sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Decodes a capture off disk. Only ever call for a tagged file — the
    /// callers here come through `Entry`, which already guarantees that.
    static func image(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// A downscaled decode for list rows. Going through ImageIO's thumbnail
    /// path rather than decoding the full capture matters: a search result
    /// list would otherwise decode a screenful of retina PNGs to draw them
    /// at 56 points wide.
    static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }

    private static func entries() -> [Entry] {
        let folder = AppSettings.saveFolder
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []

        return contents.filter(FileTag.isMarked).compactMap(entry(at:))
    }

    private static func entry(at url: URL) -> Entry? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modifiedAt = values.contentModificationDate
        else {
            return nil
        }
        return Entry(
            url: url,
            name: url.lastPathComponent,
            modifiedAt: modifiedAt,
            byteCount: values.fileSize ?? 0
        )
    }
}
