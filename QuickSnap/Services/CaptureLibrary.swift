//
//  CaptureLibrary.swift
//  QuickSnap
//

import Foundation

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
