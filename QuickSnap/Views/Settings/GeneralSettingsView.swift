//
//  GeneralSettingsView.swift
//  QuickSnap
//

import SwiftUI
import AppKit

struct GeneralSettingsView: View {
    @AppStorage(AppSettings.Keys.saveFolderPath)
    private var saveFolderPath = ""

    @AppStorage(AppSettings.Keys.filenameTemplate)
    private var filenameTemplate = AppSettings.Defaults.filenameTemplate

    @AppStorage(AppSettings.Keys.imageFormat)
    private var imageFormat = AppSettings.Defaults.imageFormat

    @AppStorage(AppSettings.Keys.imageQuality)
    private var imageQuality = AppSettings.Defaults.imageQuality

    @AppStorage(AppSettings.Keys.showsCursorInCaptures)
    private var showsCursor = AppSettings.Defaults.showsCursorInCaptures

    @State private var launchesAtLogin = false
    @State private var isShowingTokenLegend = false

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
            Section("Startup") {
                Toggle("Launch QuickSnap at login", isOn: launchAtLoginBinding)

                if LoginItem.isDeniedBySystem {
                    HStack(spacing: 8) {
                        Label(
                            "Login items are blocked for QuickSnap in System Settings.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                        .font(.footnote)

                        Button("Open") { LoginItem.openSystemLoginItemsSettings() }
                            .controlSize(.small)
                    }
                }
            }

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

                LabeledContent("File name") {
                    HStack(spacing: 8) {
                        TextField(AppSettings.Defaults.filenameTemplate, text: $filenameTemplate)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()

                        Button {
                            isShowingTokenLegend.toggle()
                        } label: {
                            Image(systemName: "curlybraces")
                        }
                        .help("Show available tokens")
                        .popover(isPresented: $isShowingTokenLegend, arrowEdge: .bottom) {
                            tokenLegend
                        }

                        if filenameTemplate != AppSettings.Defaults.filenameTemplate {
                            Button("Reset") {
                                filenameTemplate = AppSettings.Defaults.filenameTemplate
                            }
                        }
                    }
                }

                // Live preview, so a template's effect is visible before a
                // capture rather than after it.
                Text(filenamePreview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                LabeledContent("Format") {
                    Picker("Format", selection: $imageFormat) {
                        ForEach(ImageFormat.allCases) { format in
                            Text(format.displayName).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                }

                if imageFormat.isLossy {
                    LabeledContent("Quality") {
                        SliderWithValue(value: $imageQuality, in: 0.3...1, step: 0.05) {
                            "\(Int($0 * 100))%"
                        }
                    }

                    Text("JPEG can't store transparency, so window captures with a transparent background stay PNG.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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

            Section("Capture") {
                Toggle("Include the pointer in captures", isOn: $showsCursor)

                Text("Text Recognition captures never include the pointer.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .onAppear { launchesAtLogin = LoginItem.isEnabled }
    }

    /// Rendered against representative values rather than the live
    /// frontmost app — the frontmost app while Settings is open is
    /// QuickSnap itself, which would be a misleading preview.
    private var filenamePreview: String {
        let name = FilenameTemplate.render(
            filenameTemplate,
            context: FilenameContext(
                date: Date(),
                appName: "Safari",
                windowTitle: "Apple",
                pixelWidth: 2880,
                pixelHeight: 1800
            ),
            counter: 42
        )
        let format = ImageFormat(rawValue: imageFormat.rawValue) ?? .png
        return "Example: \(name).\(format.fileExtension)"
    }

    private var tokenLegend: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tokens")
                .font(.headline)
                .padding(.bottom, 2)

            ForEach(FilenameTemplate.tokens, id: \.token) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(entry.token)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(width: 76, alignment: .leading)

                    Text(entry.description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Text("Anything else is used literally. Names that collide get a number appended.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    /// Reads the real `SMAppService` status rather than a stored flag — the
    /// user can revoke login items in System Settings, and the toggle has to
    /// follow that. A failed registration snaps the toggle back.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchesAtLogin },
            set: { newValue in
                LoginItem.setEnabled(newValue)
                launchesAtLogin = LoginItem.isEnabled
            }
        )
    }

    /// Bridges the ColorPicker to the `#RRGGBB` string stored in defaults.
    private var windowBackgroundColor: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hexString: windowBackgroundColorHex) ?? .white) },
            set: { windowBackgroundColorHex = NSColor($0).hexString }
        )
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
