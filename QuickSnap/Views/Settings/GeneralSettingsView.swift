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
    /// Only consulted while Notification Center is the selected presentation.
    /// Assumed granted until the system says otherwise, so the warning doesn't
    /// flash on the way to the answer.
    @State private var hasNotificationAccess = true

    @AppStorage(AppSettings.Keys.showPreviewAfterCapture)
    private var showsPreview = AppSettings.Defaults.showPreviewAfterCapture

    @AppStorage(AppSettings.Keys.copyAfterCapture)
    private var copiesToClipboard = AppSettings.Defaults.copyAfterCapture

    @AppStorage(AppSettings.Keys.previewDoubleClickOpensMarkup)
    private var doubleClickOpensMarkup = AppSettings.Defaults.previewDoubleClickOpensMarkup
    @AppStorage(AppSettings.Keys.saveAfterCapture)
    private var savesToDisk = AppSettings.Defaults.saveAfterCapture

    @AppStorage(AppSettings.Keys.previewPosition)
    private var previewPosition = AppSettings.Defaults.previewPosition

    @AppStorage(AppSettings.Keys.toastPosition)
    private var toastPosition = AppSettings.Defaults.toastPosition

    @AppStorage(AppSettings.Keys.previewAutoDismissSeconds)
    private var previewAutoDismissSeconds = AppSettings.Defaults.previewAutoDismissSeconds

    @AppStorage(AppSettings.Keys.toastAutoDismissSeconds)
    private var toastAutoDismissSeconds = AppSettings.Defaults.toastAutoDismissSeconds

    @AppStorage(AppSettings.Keys.showTextPreviewInToast)
    private var showsTextPreviewInToast = AppSettings.Defaults.showTextPreviewInToast

    @AppStorage(AppSettings.Keys.copyForAIIncludesText)
    private var copyForAIIncludesText = AppSettings.Defaults.copyForAIIncludesText

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

            // TEMPORARY — for testing the first-run flow. Remove this
            // section (and nothing else) once onboarding has been signed off;
            // `OnboardingCoordinator.replay()` exists only for it.
            Section("Setup") {
                LabeledContent("First-run setup") {
                    Button("Show Again…") {
                        OnboardingCoordinator.shared.replay()
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

                if showsPreview {
                    Toggle("Double-click the preview to mark it up", isOn: $doubleClickOpensMarkup)
                }

                if !showsPreview && !copiesToClipboard && !savesToDisk {
                    Text("With all three off, screenshots are discarded as soon as they're captured.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Notifications") {
                Picker("Screenshot appears", selection: $previewPosition) {
                    ForEach(NotificationPosition.previewCases, id: \.self) { position in
                        Text(position.displayName)
                    }
                }
                .pickerStyle(.segmented)

                if previewPosition == .dynamic {
                    Text("Dynamic puts the preview over whatever you just captured. Full-screen captures use the bottom corner.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Picker("Confirmations appear", selection: $toastPosition) {
                    ForEach(NotificationPosition.toastCases, id: \.self) { position in
                        Text(position.displayName)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: toastPosition) { _, position in
                    // Ask at the switch that causes it, rather than mid-capture
                    // behind an overlay.
                    guard position == .notificationCenter else { return }
                    SystemNotifier.shared.requestAuthorizationIfNeeded { granted in
                        hasNotificationAccess = granted
                    }
                }

                if toastPosition == .notificationCenter {
                    Text("Confirmations go to Notification Center instead of appearing over your work. You'll see the result of an upload, but not its progress.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if !hasNotificationAccess {
                        HStack(spacing: 10) {
                            Label("QuickSnap can't post notifications", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)

                            Button("Open System Settings") {
                                SystemNotifier.openSystemSettings()
                            }

                            Button("Re-check") { refreshNotificationAuthorization() }
                        }
                    }
                }

                LabeledContent("Screenshot disappears") {
                    SliderWithValue(value: $previewAutoDismissSeconds, in: 1...AppSettings.previewAutoDismissNeverThreshold, step: 0.5) {
                        $0 >= AppSettings.previewAutoDismissNeverThreshold ? "Never" : String(format: "%.1f s", $0)
                    }
                }

                // Notification Center owns its own timing, so there's nothing
                // for this to control under that option.
                if toastPosition != .notificationCenter {
                    LabeledContent("Confirmations disappear") {
                        SliderWithValue(value: $toastAutoDismissSeconds, in: 1...8, step: 0.5) {
                            String(format: "%.1f s", $0)
                        }
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

            Section("Copy for AI") {
                Toggle("Include the text in the image", isOn: $copyForAIIncludesText)

                Text("Copy for AI puts the screenshot on the clipboard along with the app it came from and, if you want, the text in it. One paste gives a chat or coding tool the whole picture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Window Screenshots") {
                // Labelled above rather than with `LabeledContent`, whose
                // trailing column would squeeze the thumbnails.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Background")
                    ImageOptionPicker(
                        selection: $windowBackgroundStyle,
                        options: WindowBackgroundStyle.allCases.map {
                            .init(value: $0, imageName: Self.thumbnailName(for: $0), label: $0.displayName)
                        }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
        .onAppear {
            launchesAtLogin = LoginItem.isEnabled
            if toastPosition == .notificationCenter {
                refreshNotificationAuthorization()
            }
        }
    }

    /// Re-reads the system's answer — it can change in System Settings while
    /// QuickSnap is running, and the request itself is answered asynchronously.
    private func refreshNotificationAuthorization() {
        SystemNotifier.shared.refreshAuthorization { granted in
            hasNotificationAccess = granted
        }
    }

    /// Imageset for each background style, written by
    /// `Tools/GenerateThumbnails.swift`. Mapped here rather than on
    /// `WindowBackgroundStyle` itself, which is a Services type and stays
    /// UI-agnostic.
    private static func thumbnailName(for style: WindowBackgroundStyle) -> String {
        switch style {
        case .wallpaper: "WindowBackgroundWallpaper"
        case .transparent: "WindowBackgroundTransparent"
        case .solidColor: "WindowBackgroundSolidColor"
        case .trimShadow: "WindowBackgroundTrimShadow"
        }
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
                pixelHeight: 1800,
                description: "login form validation error"
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
