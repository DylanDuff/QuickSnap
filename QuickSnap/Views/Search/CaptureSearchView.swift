//
//  CaptureSearchView.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// The search panel's content: a field, a list of matches, and a hint bar.
///
/// Keyboard handling is deliberately done with zero-sized `Button`s carrying
/// `keyboardShortcut` rather than `onKeyPress`. Shortcuts are resolved
/// through `performKeyEquivalent`, which runs *before* the focused text
/// field's editor sees the key — so ↑/↓ move the selection instead of the
/// insertion point, and ⌘↩ is never swallowed. Plain ↩ still goes through
/// `onSubmit`, which is the field's own idiom.
struct CaptureSearchView: View {
    @ObservedObject var model: CaptureSearchModel
    let onReveal: (CaptureSearchResult) -> Void
    let onEdit: (CaptureSearchResult) -> Void

    @FocusState private var isFieldFocused: Bool

    private enum Layout {
        static let cornerRadius: CGFloat = 14
        static let fieldHeight: CGFloat = 52
        static let rowHeight: CGFloat = 54
        static let thumbnailWidth: CGFloat = 64
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
            hintBar
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Layout.cornerRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .background(keyboardShortcuts)
        .onAppear { isFieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search captures", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($isFieldFocused)
                .onSubmit {
                    if let result = model.selectedResult { onReveal(result) }
                }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    model.showRecents()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(PressScaleButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .frame(height: Layout.fieldHeight)
    }

    @ViewBuilder
    private var results: some View {
        if model.results.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.results.enumerated()), id: \.element.id) { index, result in
                            CaptureSearchRow(
                                result: result,
                                isSelected: index == model.selectedIndex,
                                thumbnailWidth: Layout.thumbnailWidth
                            )
                            .frame(height: Layout.rowHeight)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { onReveal(result) }
                            .onTapGesture { model.selectedIndex = index }
                            .id(index)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .onChange(of: model.selectedIndex) { _, index in
                    // Keyboard selection has to drag the list with it, or
                    // arrowing past the fold selects something invisible.
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(index, anchor: .center)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: model.hasSearched ? "magnifyingglass" : "photo.on.rectangle.angled")
                .font(.system(size: 26))
                .foregroundStyle(.tertiary)

            Text(model.hasSearched ? "No captures match" : "No captures yet")
                .foregroundStyle(.secondary)

            if model.hasSearched {
                Text("Searches file names, text in the image, and what the capture shows.")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
    }

    private var hintBar: some View {
        HStack(spacing: 14) {
            KeyHint(keys: "↩", label: "Reveal in Finder")
            KeyHint(keys: "⌘↩", label: "Open in editor")
            Spacer()
            if !model.results.isEmpty {
                Text("\(model.results.count) \(model.results.count == 1 ? "capture" : "captures")")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(.quaternary.opacity(0.4))
    }

    /// Zero-sized shortcut carriers — see the note on the type.
    private var keyboardShortcuts: some View {
        Group {
            Button("") { model.moveSelection(by: 1) }
                .keyboardShortcut(.downArrow, modifiers: [])
            Button("") { model.moveSelection(by: -1) }
                .keyboardShortcut(.upArrow, modifiers: [])
            Button("") {
                if let result = model.selectedResult { onEdit(result) }
            }
            .keyboardShortcut(.return, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

/// One match: thumbnail, name, whatever explains the match, and where it
/// came from.
private struct CaptureSearchRow: View {
    let result: CaptureSearchResult
    let isSelected: Bool
    let thumbnailWidth: CGFloat

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView

            VStack(alignment: .leading, spacing: 2) {
                Text(result.name)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Text(result.modifiedAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.secondary)
        }
        .padding(.horizontal, 10)
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        }
        .padding(.horizontal, 8)
        .task(id: result.url) { await loadThumbnail() }
    }

    /// The caption says what the capture *is*; the snippet says why it
    /// matched. Prefer the caption when both exist — it reads as a label
    /// rather than a fragment — and fall back to the app it came from.
    private var detail: String? {
        if let caption = result.caption, !caption.isEmpty { return caption }
        if !result.snippet.isEmpty { return result.snippet }
        return result.appName
    }

    @ViewBuilder
    private var thumbnailView: some View {
        Group {
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: thumbnailWidth, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    /// Decoded at thumbnail size off the main thread — a list of retina PNGs
    /// decoded in full to draw them 64 points wide would stutter the panel
    /// on every keystroke.
    private func loadThumbnail() async {
        let url = result.url
        let image = await Task.detached(priority: .userInitiated) {
            CaptureLibrary.thumbnail(at: url, maxPixelSize: 256)
        }.value
        guard let image else { return }
        thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}

/// A keycap and what it does, for the hint bar.
private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(keys)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
