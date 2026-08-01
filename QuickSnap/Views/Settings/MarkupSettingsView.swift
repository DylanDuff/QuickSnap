//
//  MarkupSettingsView.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Markup tab: the defaults new annotation windows open with (color and
/// stroke size) and which output buttons the markup toolbar shows. Uses
/// `@AppStorage` with `AppSettings.Keys`/`Defaults`, like the other tabs.
struct MarkupSettingsView: View {
    @AppStorage(AppSettings.Keys.markupDefaultColor)
    private var defaultColorHex = AppSettings.Defaults.markupDefaultColor

    @AppStorage(AppSettings.Keys.markupDefaultStrokeStep)
    private var defaultStrokeStep = AppSettings.Defaults.markupDefaultStrokeStep

    @AppStorage(AppSettings.Keys.markupShowsCopyButton)
    private var showsCopyButton = AppSettings.Defaults.markupShowsCopyButton

    @AppStorage(AppSettings.Keys.markupShowsSaveButton)
    private var showsSaveButton = AppSettings.Defaults.markupShowsSaveButton

    @AppStorage(AppSettings.Keys.markupShowsSaveAsButton)
    private var showsSaveAsButton = AppSettings.Defaults.markupShowsSaveAsButton

    @AppStorage(AppSettings.Keys.markupShowsDragButton)
    private var showsDragButton = AppSettings.Defaults.markupShowsDragButton

    @AppStorage(AppSettings.Keys.markupShowsRedactionButton)
    private var showsRedactionButton = AppSettings.Defaults.markupShowsRedactionButton

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

                Text("Stroke sizes are relative — each screenshot gets widths proportional to its own dimensions.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Toolbar Save Options") {
                Toggle("Copy to clipboard", isOn: $showsCopyButton)
                    .disabled(isOnlyEnabledOption(showsCopyButton))

                Toggle("Save to screenshots folder", isOn: $showsSaveButton)
                    .disabled(isOnlyEnabledOption(showsSaveButton))

                Toggle("Save As…", isOn: $showsSaveAsButton)
                    .disabled(isOnlyEnabledOption(showsSaveAsButton))

                Toggle("Drag out as a file", isOn: $showsDragButton)
                    .disabled(isOnlyEnabledOption(showsDragButton))

                Text("Choose which output buttons the markup toolbar shows. At least one stays on, so an annotated screenshot can always leave the editor. Saved copies never overwrite the original.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Tools") {
                Toggle("Check for sensitive text", isOn: $showsRedactionButton)

                Text("Adds a button that reads the screenshot on this Mac and highlights anything that looks like a key, token or card number, so you can black it out. The same check runs automatically before an upload, if uploading is switched on.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// A toggle is locked while it's the only output option still enabled.
    private func isOnlyEnabledOption(_ option: Bool) -> Bool {
        option && [showsCopyButton, showsSaveButton, showsSaveAsButton, showsDragButton].filter(\.self).count == 1
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
