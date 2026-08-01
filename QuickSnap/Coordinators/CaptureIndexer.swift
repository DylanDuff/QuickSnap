//
//  CaptureIndexer.swift
//  QuickSnap
//

import Combine
import CoreGraphics
import Foundation

/// Keeps `CaptureIndex` in step with the save folder: indexes each capture
/// as it's saved, walks the folder once for everything taken before the
/// index existed, and drops rows whose files have gone.
///
/// The index is derived data, so every operation here is best-effort and
/// silent. A capture that fails to index is still a saved screenshot; the
/// only consequence is that it won't turn up in search until the next
/// rebuild, and the user has better things to be told about.
final class CaptureIndexer: nonisolated ObservableObject {
    /// Shared because the Settings scene needs to watch and drive the same
    /// indexer the capture path feeds, and the two have no other connection
    /// — the same reason `MCPServerStatus` is a singleton.
    static let shared = CaptureIndexer()

    /// How far through the folder walk we are — nil when nothing is
    /// running. The settings UI is the only reader.
    @Published private(set) var backfill: BackfillProgress?
    /// Rows currently in the index, refreshed after any bulk operation.
    @Published private(set) var indexedCount = 0

    struct BackfillProgress: Equatable {
        var completed: Int
        var total: Int

        var fraction: Double {
            total > 0 ? Double(completed) / Double(total) : 0
        }
    }

    private var backfillTask: Task<Void, Never>?

    private init() {}

    // MARK: - Per-capture

    /// Records a capture that has just been saved. `analysis` comes from the
    /// same `CaptureAnalyzer` pass the `{describe}` rename uses — running
    /// Vision a second time here would double the cost of every capture for
    /// an answer we already have.
    func index(_ url: URL, analysis: CaptureAnalyzer.Analysis, context: FilenameContext) {
        let entry = CaptureIndexEntry(
            url: url,
            name: url.deletingPathExtension().lastPathComponent,
            appName: context.appName,
            windowTitle: context.windowTitle,
            caption: analysis.description,
            transcript: analysis.recognizedText,
            modifiedAt: Date()
        )
        Task {
            try? await CaptureIndex.shared.index(entry)
            await refreshCount()
        }
    }

    /// Follows a `{describe}` rename, so the row keeps pointing at the file.
    func captureMoved(from oldURL: URL, to newURL: URL) {
        Task { try? await CaptureIndex.shared.move(from: oldURL, to: newURL) }
    }

    /// Drops rows for files retention has just trashed.
    func captureFilesRemoved(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Task {
            try? await CaptureIndex.shared.remove(urls)
            await refreshCount()
        }
    }

    // MARK: - Bulk

    /// Reconciles against the folder, then indexes anything in it that isn't
    /// in the index yet. Called once at launch.
    ///
    /// There is deliberately **no "already backfilled" flag.** One was tried
    /// and immediately went wrong: the flag outlived the database it was
    /// describing, so a missing or emptied index was never rebuilt and
    /// search silently returned nothing forever. Deriving the work from a
    /// diff of the folder against the index instead is self-correcting, and
    /// costs a directory listing and one `SELECT` per launch — which is also
    /// what makes turning indexing on later, or restoring a capture from the
    /// Trash, work without any special case.
    func startIfNeeded() {
        guard AppSettings.isCaptureIndexingEnabled else { return }
        Task {
            await reconcile()
            await refreshCount()
            startBackfill()
        }
    }

    /// Walks the save folder, indexing anything missing or changed.
    ///
    /// Background priority, one file at a time, because this is OCR over
    /// every capture the user has ever taken and it must not make the
    /// machine feel busy. Cancellable at any point, and resumable for free:
    /// the work list is recomputed from the folder-against-index diff every
    /// time, so stopping halfway and starting again picks up where it left
    /// off rather than starting over.
    func startBackfill() {
        guard backfillTask == nil else { return }

        backfillTask = Task(priority: .background) { [weak self] in
            defer {
                self?.backfillTask = nil
                self?.backfill = nil
            }

            let entries = await Task.detached(priority: .background) {
                CaptureLibrary.all()
            }.value
            let fingerprints = (try? await CaptureIndex.shared.fingerprints()) ?? [:]

            let outstanding = entries.filter { entry in
                guard let indexedAt = fingerprints[entry.url.path] else { return true }
                // A file edited outside QuickSnap (annotated and re-saved
                // over, say) is worth re-reading.
                return abs(indexedAt.timeIntervalSince(entry.modifiedAt)) > 1
            }
            guard !outstanding.isEmpty else {
                await self?.refreshCount()
                return
            }

            self?.backfill = BackfillProgress(completed: 0, total: outstanding.count)

            for (offset, entry) in outstanding.enumerated() {
                if Task.isCancelled { return }
                await self?.indexExistingCapture(entry)
                self?.backfill = BackfillProgress(completed: offset + 1, total: outstanding.count)
            }

            await self?.refreshCount()
        }
    }

    func cancelBackfill() {
        backfillTask?.cancel()
        backfillTask = nil
        backfill = nil
    }

    /// Throws the index away and walks the folder again — the escape hatch
    /// for an index that has drifted, and the only way to pick up captions
    /// for captures indexed while intelligence was switched off.
    func rebuild() {
        cancelBackfill()
        Task {
            try? await CaptureIndex.shared.removeAll()
            await refreshCount()
            startBackfill()
        }
    }

    func refreshCount() async {
        indexedCount = (try? await CaptureIndex.shared.count()) ?? 0
    }

    // MARK: - Support

    /// Reads one existing capture off disk and indexes it. The capture's app
    /// and window aren't recoverable from the file, so those columns stay
    /// empty for backfilled rows — the transcript is what makes them
    /// findable, and it's the part that matters.
    private func indexExistingCapture(_ entry: CaptureLibrary.Entry) async {
        guard let image = await Task.detached(priority: .background, operation: {
            CaptureLibrary.image(at: entry.url)
        }).value else {
            return
        }

        let analysis = await CaptureAnalyzer.analyze(image, describes: AppSettings.isAIEnabled)
        let indexEntry = CaptureIndexEntry(
            url: entry.url,
            name: entry.url.deletingPathExtension().lastPathComponent,
            appName: nil,
            windowTitle: nil,
            caption: analysis.description,
            transcript: analysis.recognizedText,
            modifiedAt: entry.modifiedAt
        )
        try? await CaptureIndex.shared.index(indexEntry)
    }

    private func reconcile() async {
        let paths = await Task.detached(priority: .background) {
            Set(CaptureLibrary.all().map(\.url.path))
        }.value
        try? await CaptureIndex.shared.reconcile(against: paths)
    }
}
