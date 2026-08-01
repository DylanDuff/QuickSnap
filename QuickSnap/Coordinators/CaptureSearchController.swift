//
//  CaptureSearchController.swift
//  QuickSnap
//

import AppKit
import Combine
import SwiftUI

/// What the search panel is showing, and what typing in it does.
///
/// Lives with the controller because it's the controller's state — the view
/// only renders it and reports keystrokes back.
final class CaptureSearchModel: nonisolated ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [CaptureSearchResult] = []
    @Published var selectedIndex = 0
    /// True once a query has run and come back with nothing, so the view can
    /// tell "no matches" apart from "nothing typed yet".
    @Published private(set) var hasSearched = false

    private var searchTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Debounced rather than searched per keystroke: FTS5 is fast, but a
        // query per character makes the list flicker through half-typed
        // words on the way to the one the user meant.
        $query
            .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            .removeDuplicates()
            .sink { [weak self] query in self?.run(query) }
            .store(in: &cancellables)
    }

    var selectedResult: CaptureSearchResult? {
        results.indices.contains(selectedIndex) ? results[selectedIndex] : nil
    }

    /// Empty query shows the most recent captures instead of nothing — the
    /// panel is a way into the save folder, not only a search box, and
    /// "the one I just took" is the most common thing being looked for.
    func showRecents() {
        run("")
    }

    func moveSelection(by offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(selectedIndex + offset, 0), results.count - 1)
    }

    func reset() {
        searchTask?.cancel()
        query = ""
        results = []
        selectedIndex = 0
        hasSearched = false
    }

    private func run(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        searchTask = Task { [weak self] in
            let results: [CaptureSearchResult]
            if trimmed.isEmpty {
                results = await Task.detached(priority: .userInitiated) {
                    CaptureLibrary.recent(limit: 20).map(CaptureSearchResult.init(recent:))
                }.value
            } else {
                results = (try? await CaptureIndex.shared.search(trimmed)) ?? []
            }
            guard !Task.isCancelled, let self else { return }
            self.results = results
            self.selectedIndex = 0
            self.hasSearched = !trimmed.isEmpty
        }
    }
}

private extension CaptureSearchResult {
    /// A recent capture shown before anything is typed. It has no match to
    /// report, so there's no snippet — the file's own name is the label.
    init(recent entry: CaptureLibrary.Entry) {
        self.init(
            url: entry.url,
            name: entry.url.deletingPathExtension().lastPathComponent,
            appName: nil,
            windowTitle: nil,
            caption: nil,
            snippet: "",
            modifiedAt: entry.modifiedAt
        )
    }
}

/// Opens and owns the capture search panel.
///
/// The panel is a singleton surface like the preview: opening it while it's
/// already up just re-focuses it, and the hotkey toggles.
@MainActor
final class CaptureSearchController {
    private let model = CaptureSearchModel()
    private var panel: CaptureSearchPanel?
    /// What "open this one for editing" means — the caller decides, same
    /// arrangement as the preview panel's `onEdit`.
    private let onEdit: (CGImage, CaptureFile) -> Void

    private enum Layout {
        static let size = CGSize(width: 620, height: 420)
        /// Fraction of the screen height the panel's top sits at. Spotlight
        /// puts its field in the upper third rather than dead center, which
        /// leaves room for results to grow downward without the whole thing
        /// looking bottom-heavy.
        static let verticalPlacement: CGFloat = 0.22
    }

    init(onEdit: @escaping (CGImage, CaptureFile) -> Void) {
        self.onEdit = onEdit
    }

    func toggle() {
        if panel != nil {
            dismiss()
        } else {
            show()
        }
    }

    func show() {
        guard panel == nil else {
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        model.reset()
        model.showRecents()

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visible.midX - Layout.size.width / 2,
            y: visible.maxY - Layout.size.height - visible.height * Layout.verticalPlacement,
            width: Layout.size.width,
            height: Layout.size.height
        )

        let panel = CaptureSearchPanel(contentRect: frame)
        panel.onDismiss = { [weak self] in self?.dismiss() }
        panel.contentView = NSHostingView(rootView: CaptureSearchView(
            model: model,
            onReveal: { [weak self] result in self?.reveal(result) },
            onEdit: { [weak self] result in self?.edit(result) }
        ))

        // An accessory app can be frontmost without gaining a Dock icon, so
        // unlike the annotation window this needs no activation-policy
        // change — just focus, which the text field can't do without.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func dismiss() {
        guard let panel else { return }
        self.panel = nil
        panel.onDismiss = nil
        panel.close()
        model.reset()
    }

    private func reveal(_ result: CaptureSearchResult) {
        dismiss()
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    /// Opens the capture in an annotation window. The file is read back off
    /// disk rather than kept anywhere — this is a folder browser, and the
    /// image it points at may be weeks old.
    private func edit(_ result: CaptureSearchResult) {
        dismiss()
        Task {
            guard let image = await Task.detached(priority: .userInitiated, operation: {
                CaptureLibrary.image(at: result.url)
            }).value else {
                return
            }
            onEdit(image, CaptureFile(url: result.url))
        }
    }
}
