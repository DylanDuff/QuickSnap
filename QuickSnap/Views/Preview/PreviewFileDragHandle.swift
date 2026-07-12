//
//  PreviewFileDragHandle.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// A drag source for the actual screenshot file — not a tap action, but
/// something to drag straight into Finder, chat apps, or a file input.
struct PreviewFileDragHandle: View {
    let fileURL: URL

    @State private var isHovering = false

    var body: some View {
        Image(systemName: "doc.text.fill.viewfinder")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .previewActionIconStyle()
            .previewIconHoverEffect(isHovering: $isHovering, blocksWindowDrag: true)
            .draggable(fileURL)
    }
}
