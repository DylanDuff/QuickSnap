//
//  CaptureFile.swift
//  QuickSnap
//

import Combine
import Foundation

/// Where a capture currently lives on disk — a reference, not a value.
///
/// The `{describe}` rename lands a few seconds after the capture, by which
/// time the preview panel is on screen and an annotation window may already
/// be open, both holding the URL the file was *first* written to. Passing
/// this box instead means every "reveal in Finder", drag-out and Save As…
/// suggestion reads the current path at the moment it's used, rather than a
/// path that no longer exists.
///
/// Nil means the capture was never saved to disk (the Save after-capture
/// action is off), and stays nil — there is nothing to rename.
final class CaptureFile: nonisolated ObservableObject {
    @Published private(set) var url: URL?

    init(url: URL? = nil) {
        self.url = url
    }

    func moved(to url: URL) {
        self.url = url
    }
}
