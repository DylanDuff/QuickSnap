//
//  ImageOptionPicker.swift
//  QuickSnap
//

import SwiftUI

/// A picker whose options are pictures instead of words: a row of labelled
/// thumbnails with the selected one ringed in the accent colour.
///
/// Everything specific to a setting lives in its images, so wiring this up
/// for a future setting is a set of imagesets plus an `Option` array — there
/// is deliberately no drawing code here to extend. Thumbnails are authored
/// by `Tools/GenerateThumbnails.swift`; keep them all at
/// `Layout.thumbnailAspectRatio` so the row's tiles stay the same height.
///
/// Tiles share the available width evenly, so the row stays inside a Form
/// however many options there are (past five or so they get small enough
/// that a plain `Picker` is the better control).
/// Outside the generic type: a nested enum in one can't hold static stored
/// properties.
private enum Layout {
    static let thumbnailAspectRatio: CGFloat = 120.0 / 84.0
    static let cornerRadius: CGFloat = 6
    static let ringWidth: CGFloat = 2.5
    /// Gap between the thumbnail and the selection ring around it.
    static let ringInset: CGFloat = 4
    static let columnSpacing: CGFloat = 10
    static let labelSpacing: CGFloat = 6
}

struct ImageOptionPicker<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        /// Imageset name in `Assets.xcassets`.
        let imageName: String
        let label: String

        var id: Value { value }
    }

    @Binding var selection: Value
    let options: [Option]

    var body: some View {
        HStack(alignment: .top, spacing: Layout.columnSpacing) {
            ForEach(options) { option in
                optionButton(option)
            }
        }
        .animation(Motion.revealSpring, value: selection)
        .accessibilityElement(children: .contain)
    }

    private func optionButton(_ option: Option) -> some View {
        let isSelected = option.value == selection
        return Button {
            selection = option.value
        } label: {
            VStack(spacing: Layout.labelSpacing) {
                thumbnail(option, isSelected: isSelected)
                Text(option.label)
                    .font(.callout)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressScaleButtonStyle(pressedScale: 0.97))
        .accessibilityLabel(option.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func thumbnail(_ option: Option, isSelected: Bool) -> some View {
        Image(option.imageName)
            .resizable()
            .aspectRatio(Layout.thumbnailAspectRatio, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: Layout.cornerRadius))
            // A hairline keeps a thumbnail whose edges match the window
            // background (the light checkerboard, a pale solid) from
            // bleeding into the Form behind it.
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cornerRadius)
                    .strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            }
            .padding(Layout.ringInset)
            .overlay {
                RoundedRectangle(cornerRadius: Layout.cornerRadius + Layout.ringInset)
                    .strokeBorder(Color.accentColor, lineWidth: Layout.ringWidth)
                    .opacity(isSelected ? 1 : 0)
            }
    }
}
