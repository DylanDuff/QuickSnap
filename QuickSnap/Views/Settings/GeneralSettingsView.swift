//
//  GeneralSettingsView.swift
//  QuickSnap
//

import SwiftUI
import AppKit

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.saveFolderPath)
    private var saveFolderPath = ""

    @AppStorage(AppSettings.Keys.showPreviewAfterCapture)
    private var showsPreview = AppSettings.Defaults.showPreviewAfterCapture

    @AppStorage(AppSettings.Keys.copyAfterCapture)
    private var copiesToClipboard = AppSettings.Defaults.copyAfterCapture

    @AppStorage(AppSettings.Keys.saveAfterCapture)
    private var savesToDisk = AppSettings.Defaults.saveAfterCapture

    @AppStorage(AppSettings.Keys.notificationPosition)
    private var notificationPosition = AppSettings.Defaults.notificationPosition

    @AppStorage(AppSettings.Keys.previewAutoDismissSeconds)
    private var previewAutoDismissSeconds = AppSettings.Defaults.previewAutoDismissSeconds

    @AppStorage(AppSettings.Keys.toastAutoDismissSeconds)
    private var toastAutoDismissSeconds = AppSettings.Defaults.toastAutoDismissSeconds

    @AppStorage(AppSettings.Keys.showTextPreviewInToast)
    private var showsTextPreviewInToast = AppSettings.Defaults.showTextPreviewInToast

    @AppStorage(AppSettings.Keys.windowBackgroundStyle)
    private var windowBackgroundStyle = AppSettings.Defaults.windowBackgroundStyle

    @AppStorage(AppSettings.Keys.windowBackgroundPadding)
    private var windowBackgroundPadding = AppSettings.Defaults.windowBackgroundPadding

    @AppStorage(AppSettings.Keys.windowBackgroundColor)
    private var windowBackgroundColorHex = AppSettings.Defaults.windowBackgroundColor

    private var usesCustomFolder: Bool {
        !saveFolderPath.isEmpty
    }

    /// Display path with the home directory abbreviated to `~`.
    private var saveFolderDisplayPath: String {
        (AppSettings.saveFolder.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        Form {
            Section("Screenshots") {
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)

                        Text(saveFolderDisplayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(saveFolderDisplayPath)

                        Button("Choose…") {
                            chooseSaveFolder()
                        }

                        if usesCustomFolder {
                            Button("Reset") {
                                saveFolderPath = ""
                            }
                            .help("Use the default folder (~/Documents/QuickSnap)")
                        }
                    }
                }

                LabeledContent("After screenshot") {
                    HStack(spacing: 16) {
                        Toggle("Show", isOn: $showsPreview)
                        Toggle("Copy", isOn: $copiesToClipboard)
                        Toggle("Save", isOn: $savesToDisk)
                    }
                    .toggleStyle(.checkbox)
                }

                if !showsPreview && !copiesToClipboard && !savesToDisk {
                    Text("With all three off, screenshots are discarded as soon as they're captured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Picker("Appear from", selection: $notificationPosition) {
                    ForEach(NotificationPosition.allCases, id: \.self) { position in
                        Text(position.displayName)
                    }
                }
                .pickerStyle(.segmented)

//                Text("Applies to the screenshot preview and the copied-text confirmation.")
//                    .font(.footnote)
//                    .foregroundStyle(.secondary)

                LabeledContent("Screenshot dissapears") {
                    SliderWithValue(value: $previewAutoDismissSeconds, in: 1...AppSettings.previewAutoDismissNeverThreshold, step: 0.5) {
                        $0 >= AppSettings.previewAutoDismissNeverThreshold ? "Never" : String(format: "%.1f s", $0)
                    }
                }

                LabeledContent("Text Recognition dissapears") {
                    SliderWithValue(value: $toastAutoDismissSeconds, in: 1...8, step: 0.5) {
                        String(format: "%.1f s", $0)
                    }
                }
            }

            Section("Text Recognition") {
                Toggle("Show text preview in confirmation", isOn: $showsTextPreviewInToast)
            }

            Section("Window Screenshots") {
                Picker("Background", selection: $windowBackgroundStyle) {
                    ForEach(WindowBackgroundStyle.allCases, id: \.self) { style in
                        Text(style.displayName)
                    }
                }
                .pickerStyle(.segmented)

                if windowBackgroundStyle != .trimShadow {
                    LabeledContent("Padding") {
                        SliderWithValue(value: $windowBackgroundPadding, in: 0...120, step: 4) {
                            "\(Int($0)) pt"
                        }
                    }
                }

                if windowBackgroundStyle == .solidColor {
                    ColorPicker("Background color", selection: windowBackgroundColor, supportsOpacity: false)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    /// Bridges the ColorPicker to the `#RRGGBB` string stored in defaults.
    private var windowBackgroundColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexString: windowBackgroundColorHex) ?? .white) },
            set: { windowBackgroundColorHex = NSColor($0).hexString }
        )
    }

    /// Slider with a trailing readout of the current value — the shared
    /// shape of General's numeric rows.
    private struct SliderWithValue: View {
        @Binding var value: Double
        let range: ClosedRange<Double>
        let step: Double
        let format: (Double) -> String

        init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String) {
            _value = value
            self.range = range
            self.step = step
            self.format = format
        }

        var body: some View {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(maxWidth: 220)

                Text(format(value))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
            }
        }
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = AppSettings.saveFolder
        panel.prompt = "Choose"
        panel.message = "Choose where QuickSnap saves screenshots"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolderPath = url.path
    }
}


#Preview {
    GeneralSettingsView()
        .frame(width: 520, height: 450)
}
