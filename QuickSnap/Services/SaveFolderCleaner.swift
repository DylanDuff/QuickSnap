//
//  SaveFolderCleaner.swift
//  QuickSnap
//

import Foundation

/// Deletes old captures from the save folder, when retention is switched on.
///
/// Two safety rules, both non-negotiable — this deletes user files from a
/// folder the user picked, on an unsandboxed app:
///
/// 1. **Only files carrying QuickSnap's own extended attribute** (`FileTag`)
///    are ever considered. A folder full of the user's own images is
///    untouched even if retention is on and the folder is `~/Documents`.
/// 2. **Never recursive.** Only the save folder's immediate contents are
///    scanned, so a nested project folder can't be walked into.
///
/// `nonisolated` and always called off the main thread: enumerating a
/// TCC-protected folder can block on the consent prompt (see CLAUDE.md).
nonisolated enum SaveFolderCleaner {
    /// Deletes tagged captures older than `days`, returning the files that
    /// actually went — the caller needs them to drop the matching rows from
    /// the search index, since a hit that opens nothing is worse than no
    /// hit. `days <= 0` means retention is off and is a no-op.
    @discardableResult
    static func clean(olderThan days: Int, in directory: URL = ScreenshotSaver.saveDirectory) -> [URL] {
        guard days > 0 else { return [] }

        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }

        var deleted: [URL] = []
        for url in contents {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff,
                  // The safety rule: ours, or we don't touch it.
                  FileTag.isMarked(url)
            else {
                continue
            }

            if (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
                deleted.append(url)
            }
        }
        return deleted
    }

    /// How many files *would* be deleted, without deleting anything — backs
    /// the settings preview so the user can see the blast radius first.
    static func countExpired(olderThan days: Int, in directory: URL = ScreenshotSaver.saveDirectory) -> Int {
        guard days > 0 else { return 0 }

        let cutoff = Date().addingTimeInterval(-Double(days) * 24 * 60 * 60)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return 0
        }

        return contents.count { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate
            else {
                return false
            }
            return modified < cutoff && FileTag.isMarked(url)
        }
    }
}
