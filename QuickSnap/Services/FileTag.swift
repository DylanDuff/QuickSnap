//
//  FileTag.swift
//  QuickSnap
//

import Foundation

/// Marks files QuickSnap wrote, using an extended attribute.
///
/// This exists so retention (`SaveFolderCleaner`) can delete old captures
/// **without ever touching a file QuickSnap didn't create**. The save folder
/// is user-chosen and the app is unsandboxed, so "delete images older than N
/// days in this folder" would be an unacceptable amount of trust — point it
/// at `~/Documents` by accident and it eats your files.
///
/// Matching on the filename template instead would be fragile (the template
/// is user-editable and changes over time). An xattr is set at write time,
/// travels with the file on a rename or move within a volume, and is simply
/// absent on anything we didn't write.
///
/// The failure mode is deliberately one-directional: if the attribute is
/// lost (copied across filesystems that don't support xattrs, restored from
/// some backups), the file is treated as *not ours* and is kept. Retention
/// under-deletes rather than over-deletes.
nonisolated enum FileTag {
    private static let name = "com.dylanduff.quicksnap.managed"

    /// Tags `url` as written by QuickSnap. Best-effort: a failure here must
    /// never fail the save itself — the consequence is only that retention
    /// won't clean this file up later.
    static func mark(_ url: URL) {
        let value = Array("1".utf8)
        _ = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return setxattr(path, name, value, value.count, 0, 0)
        }
    }

    static func isMarked(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return getxattr(path, name, nil, 0, 0, 0) >= 0
        }
    }
}
