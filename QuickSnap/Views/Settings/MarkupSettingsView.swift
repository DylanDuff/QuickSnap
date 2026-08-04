//
//  MarkupSettingsView.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Markup tab: the defaults new annotation windows open with (color and
/// stroke size), and the toolbar's contents and order (`MarkupToolbarEditor`).
/// Uses `@AppStorage` with `AppSettings.Keys`/`Defaults`, like the other tabs.
struct MarkupSettingsView: View {
    @AppStorage(AppSettings.Keys.markupDefaultColor)
    private var defaultColorHex = AppSettings.Defaults.markupDefaultColor

    @AppStorage(AppSettings.Keys.markupDefaultStrokeStep)
    private var defaultStrokeStep = AppSettings.Defaults.markupDefaultStrokeStep

    @AppStorage(AppSettings.Keys.markupClosesAfterSave)
    private var closesAfterSave = AppSettings.Defaults.markupClosesAfterSave

    var body: some View {
        Form {
            Section("Defaults") {
                LabeledContent("Color") {
                    HStack(spacing: 10) {
                        ForEach(MarkupToolbar.presetColors, id: \.self) { preset in
                            presetColorButton(preset)
                        }

                        Divider().frame(height: 18)

                        ColorPicker("Custom color", selection: defaultColor, supportsOpacity: false)
                            .labelsHidden()
                            .help("Custom color…")
                    }
                }

                LabeledContent("Stroke size") {
                    HStack(spacing: 8) {
                        ForEach(0..<AppSettings.markupStrokeStepCount, id: \.self) { step in
                            strokeStepButton(step)
                        }
                    }
                }

                Text("Sizes scale with each screenshot, so your strokes look the same whether you capture a small window or a whole screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("After saving") {
                Toggle("Close the editor", isOn: $closesAfterSave)

                Text("Saving finishes the edit, so the window gets out of your way. Your original screenshot is never overwritten either way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Toolbar") {
                MarkupToolbarEditor()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Bridges the ColorPicker to the `#RRGGBB` string stored in defaults.
    private var defaultColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexString: defaultColorHex) ?? .systemRed) },
            set: { defaultColorHex = NSColor($0).hexString }
        )
    }

    private func presetColorButton(_ preset: Color) -> some View {
        let isSelected = NSColor(preset).hexString == defaultColorHex
        return Button {
            defaultColorHex = NSColor(preset).hexString
        } label: {
            Circle()
                .fill(preset)
                .overlay(Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1))
                .frame(width: 18, height: 18)
                .background(
                    Circle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .padding(-3)
                        .opacity(isSelected ? 1 : 0)
                )
        }
        .buttonStyle(PressScaleButtonStyle())
    }

    /// Same preview language as the markup toolbar: the `scribble.variable`
    /// squiggle at the step's font weight.
    private func strokeStepButton(_ step: Int) -> some View {
        Button {
            defaultStrokeStep = step
        } label: {
            Image(systemName: "scribble.variable")
                .font(.system(size: 15, weight: MarkupToolbar.strokeStepWeights[step]))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(step == defaultStrokeStep ? Color.accentColor.opacity(0.25) : .clear)
                )
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleButtonStyle())
    }
}


#Preview {
    MarkupSettingsView()
        .frame(width: 520, height: 450)
}
