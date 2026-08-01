//
//  MarkupToolbarLayout.swift
//  QuickSnap
//

import Foundation

/// One thing that can sit in the markup toolbar.
///
/// Kept in Services rather than with the toolbar view because two places
/// need to agree on it — the toolbar that renders the order, and the
/// settings editor that changes it — and because the stored layout is a
/// setting like any other.
nonisolated enum MarkupToolbarItem: String, Codable, CaseIterable, Sendable {
    case select
    case pen
    case highlighter
    case eraser
    case insert
    case crop
    case redact
    case color
    case stroke
    case copy
    case save
    case saveAs
    case dragOut
    case upload
    case divider

    /// Matches the symbol the toolbar actually draws, so the settings editor
    /// shows the same thing the pill will.
    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .insert: return "plus.square.on.square"
        case .crop: return "crop"
        case .redact: return "asterisk.circle"
        case .color: return "paintpalette"
        case .stroke: return "scribble.variable"
        case .copy: return "doc.on.doc"
        case .save: return "square.and.arrow.down"
        case .saveAs: return "square.and.arrow.down.on.square"
        case .dragOut: return "document.viewfinder"
        case .upload: return "arrow.up.circle"
        case .divider: return "line.diagonal"
        }
    }

    var label: String {
        switch self {
        case .select: return "Select"
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .eraser: return "Eraser"
        case .insert: return "Insert"
        case .crop: return "Crop"
        case .redact: return "Check for sensitive text"
        case .color: return "Color"
        case .stroke: return "Stroke size"
        case .copy: return "Copy"
        case .save: return "Save"
        case .saveAs: return "Save As…"
        case .dragOut: return "Drag out"
        case .upload: return "Upload"
        case .divider: return "Separator"
        }
    }

    /// A separator is the one item that can appear more than once, which is
    /// why the tray never removes it and why placed items carry their own
    /// identity rather than being keyed by the item itself.
    var isRepeatable: Bool { self == .divider }

    /// Gets the image out of the editor. Removing every one of these used to
    /// be prevented by a settings interlock; now the annotation window's
    /// keyboard shortcuts (⌘C / ⌘S / ⌘⇧S) are the safety net, so the layout
    /// can be genuinely free.
    var isExport: Bool {
        switch self {
        case .copy, .save, .saveAs, .dragOut, .upload: return true
        default: return false
        }
    }
}

/// The toolbar's contents, in order.
///
/// Stored as JSON in UserDefaults — an absent key means "never customised",
/// which resolves to `.default` rather than to an empty toolbar. That
/// distinction matters: an empty array is a legitimate choice (a pill with
/// nothing in it), so it can't double as "unset".
nonisolated struct MarkupToolbarLayout: Codable, Equatable, Sendable {
    var items: [MarkupToolbarItem]

    /// Reproduces the hardcoded layout the toolbar had before it was
    /// customisable, including where the separators fell.
    static let `default` = MarkupToolbarLayout(items: [
        .select, .pen, .highlighter, .eraser,
        .divider,
        .insert, .crop, .redact,
        .divider,
        .color, .stroke,
        .divider,
        .copy, .save,
    ])

    /// What the tray offers: everything not already placed, plus a separator
    /// (which can be placed any number of times).
    func availableItems() -> [MarkupToolbarItem] {
        MarkupToolbarItem.allCases.filter { item in
            item.isRepeatable || !items.contains(item)
        }
    }

    func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    static func decode(_ data: Data) -> MarkupToolbarLayout? {
        guard !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(MarkupToolbarLayout.self, from: data)
    }

    /// Builds a layout from the five per-button visibility flags the toolbar
    /// used before this existed, so an existing setup carries over instead of
    /// silently reverting to the default arrangement.
    static func migrating(
        showsCopy: Bool,
        showsSave: Bool,
        showsSaveAs: Bool,
        showsDragOut: Bool,
        showsUpload: Bool,
        showsRedact: Bool
    ) -> MarkupToolbarLayout {
        var items: [MarkupToolbarItem] = [.select, .pen, .highlighter, .eraser, .divider, .insert, .crop]
        if showsRedact { items.append(.redact) }
        items += [.divider, .color, .stroke]

        let exports: [MarkupToolbarItem] = [
            showsDragOut ? .dragOut : nil,
            showsCopy ? .copy : nil,
            showsSave ? .save : nil,
            showsSaveAs ? .saveAs : nil,
            showsUpload ? .upload : nil,
        ].compactMap { $0 }

        if !exports.isEmpty {
            items.append(.divider)
            items += exports
        }
        return MarkupToolbarLayout(items: items)
    }
}
