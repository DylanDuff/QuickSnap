//
//  MarkupToolbarEditor.swift
//  QuickSnap
//

import SwiftUI
import UniformTypeIdentifiers

/// Arranges the markup toolbar: drag an item out of the tray into the pill,
/// drag within the pill to reorder, drag back to the tray to remove.
///
/// The pill here is a **mock, not the live `MarkupToolbar`** — deliberately.
/// The real one is a working control surface whose buttons want the same
/// mouse-down that dragging does, so a draggable copy of it would fight
/// itself. This draws from the same `MarkupToolbarItem.symbolName`, so what
/// you arrange is what you get.
struct MarkupToolbarEditor: View {
    @AppStorage(AppSettings.Keys.markupToolbarLayout)
    private var layoutData = Data()

    /// Where a drop would land, so the gap opens up before the mouse is
    /// released — without it, dropping into a row of identical circles is
    /// guesswork.
    @State private var dropIndex: Int?
    @State private var isOverTray = false

    private enum Layout {
        static let chip: CGFloat = 28
        static let gap: CGFloat = 6
        static let insertionWidth: CGFloat = 3
    }

    private var layout: MarkupToolbarLayout {
        MarkupToolbarLayout.decode(layoutData) ?? .default
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            pill
            hint
            tray
        }
    }

    // MARK: - The pill

    private var pill: some View {
        // Scrolls rather than squeezing: the real pill is one row, so
        // wrapping here would misrepresent it, and a toolbar can hold more
        // items than the settings window is wide even after the window was
        // allowed to grow.
        ScrollView(.horizontal) {
            pillContents
        }
        .scrollIndicators(.never)
        .padding(.horizontal, 10)
        .frame(height: 48)
        .background(.quaternary.opacity(0.5), in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
        .overlay(alignment: .leading) {
            if layout.items.isEmpty {
                Text("Drag items here")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 16)
                    .allowsHitTesting(false)
            }
        }
    }

    private var pillContents: some View {
        HStack(spacing: 0) {
            ForEach(Array(layout.items.enumerated()), id: \.offset) { index, item in
                insertionMarker(at: index)
                chip(item, isPlaced: true)
                    .draggable(DraggedToolbarItem(item: item, sourceIndex: index))
                    .dropDestination(for: DraggedToolbarItem.self) { payloads, _ in
                        move(payloads, to: index)
                    } isTargeted: { targeted in
                        dropIndex = targeted ? index : (dropIndex == index ? nil : dropIndex)
                    }
            }

            // The tail target, so something can be dropped at the end.
            insertionMarker(at: layout.items.count)
            Color.clear
                .frame(width: 40, height: Layout.chip)
                .contentShape(Rectangle())
                .dropDestination(for: DraggedToolbarItem.self) { payloads, _ in
                    move(payloads, to: layout.items.count)
                } isTargeted: { targeted in
                    let end = layout.items.count
                    dropIndex = targeted ? end : (dropIndex == end ? nil : dropIndex)
                }
        }
        .frame(minHeight: 48)
    }

    private func insertionMarker(at index: Int) -> some View {
        Capsule()
            .fill(Color.accentColor)
            .frame(width: dropIndex == index ? Layout.insertionWidth : 0, height: 22)
            .padding(.horizontal, dropIndex == index ? 3 : Layout.gap / 2)
            .animation(Motion.revealSpring, value: dropIndex)
    }

    // MARK: - The tray

    private var tray: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Available")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(layout.availableItems(), id: \.self) { item in
                    HStack(spacing: 8) {
                        chip(item, isPlaced: false)
                        Text(item.label)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .draggable(DraggedToolbarItem(item: item, sourceIndex: nil))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isOverTray ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isOverTray ? Color.accentColor : Color.clear, lineWidth: 1)
        )
        // Dropping here is how an item leaves the toolbar.
        .dropDestination(for: DraggedToolbarItem.self) { payloads, _ in
            remove(payloads)
        } isTargeted: { isOverTray = $0 }
    }

    private var hint: some View {
        HStack(spacing: 6) {
            Text("Drag items to rearrange them, or drag one back to the list below to remove it.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            if layout != .default {
                Button("Reset") { layoutData = Data() }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Chips

    private func chip(_ item: MarkupToolbarItem, isPlaced: Bool) -> some View {
        Group {
            if item == .divider {
                // Drawn as what it is in the pill, rather than as an icon.
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 1, height: 20)
                    .frame(width: Layout.chip, height: Layout.chip)
            } else {
                Image(systemName: item.symbolName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: Layout.chip, height: Layout.chip)
                    .background(Circle().fill(isPlaced ? Color.clear : Color.secondary.opacity(0.12)))
            }
        }
        .help(item.label)
    }

    // MARK: - Mutation

    /// Handles both cases: a reorder (the payload carries where it came
    /// from) and an insert from the tray. Removing before inserting means
    /// the target index has to be adjusted when moving rightward, which is
    /// the one piece of arithmetic here worth reading twice.
    private func move(_ payloads: [DraggedToolbarItem], to index: Int) -> Bool {
        guard let payload = payloads.first else { return false }
        var items = layout.items

        if let source = payload.sourceIndex, items.indices.contains(source) {
            guard source != index else { dropIndex = nil; return false }
            items.remove(at: source)
            items.insert(payload.item, at: source < index ? index - 1 : index)
        } else {
            // Placing something that's already in the toolbar would give two
            // of it; only separators are allowed to repeat.
            guard payload.item.isRepeatable || !items.contains(payload.item) else {
                dropIndex = nil
                return false
            }
            items.insert(payload.item, at: min(index, items.count))
        }

        apply(items)
        return true
    }

    private func remove(_ payloads: [DraggedToolbarItem]) -> Bool {
        guard let payload = payloads.first, let source = payload.sourceIndex else { return false }
        var items = layout.items
        guard items.indices.contains(source) else { return false }
        items.remove(at: source)
        apply(items)
        return true
    }

    private func apply(_ items: [MarkupToolbarItem]) {
        dropIndex = nil
        layoutData = MarkupToolbarLayout(items: items).encoded()
    }
}

/// What's on the pasteboard mid-drag: the item, plus where it came from so a
/// reorder can be told from a fresh placement.
private struct DraggedToolbarItem: Codable, Transferable {
    let item: MarkupToolbarItem
    /// Nil when dragged out of the tray.
    let sourceIndex: Int?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
