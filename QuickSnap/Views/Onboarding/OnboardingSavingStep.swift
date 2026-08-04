//
//  OnboardingSavingStep.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Where captures go, and what happens the moment one is taken.
///
/// This step also does something invisible: appearing here warms up access to
/// the save folder off the main thread. The first write into a TCC-protected
/// folder (~/Documents and friends) blocks *inside the file syscall* until the
/// user answers a system prompt, and the whole reason `prepareSaveFolderAccess`
/// exists is to keep that prompt away from a capture in progress. Answering it
/// here, on a screen that is visibly about saving files, is the best moment
/// it will ever have.
struct OnboardingSavingStep: View {
    @AppStorage(AppSettings.Keys.saveFolderPath) private var saveFolderPath = ""
    @AppStorage(AppSettings.Keys.showPreviewAfterCapture)
    private var showsPreview = AppSettings.Defaults.showPreviewAfterCapture
    @AppStorage(AppSettings.Keys.copyAfterCapture)
    private var copiesToClipboard = AppSettings.Defaults.copyAfterCapture
    @AppStorage(AppSettings.Keys.saveAfterCapture)
    private var savesToDisk = AppSettings.Defaults.saveAfterCapture

    var body: some View {
        OnboardingStepLayout(
            systemImage: "folder",
            title: "Saving screenshots",
            message: "Captures land in a folder and on your clipboard. Both are optional — plenty of people only ever paste."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Save to")
                        .font(.subheadline.weight(.medium))

                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)

                        Text(saveFolderDisplayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                            .help(saveFolderDisplayPath)

                        Spacer()

                        Button("Choose…", action: chooseSaveFolder)

                        if !saveFolderPath.isEmpty {
                            Button("Reset") { saveFolderPath = "" }
                                .help("Use the default folder (~/Documents/QuickSnap)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("After a screenshot")
                        .font(.subheadline.weight(.medium))

                    Toggle("Show it in a floating preview", isOn: $showsPreview)
                    Toggle("Copy it to the clipboard", isOn: $copiesToClipboard)
                    Toggle("Save it to the folder above", isOn: $savesToDisk)
                }
            }
        }
        .task {
            // Off the main thread, always — see the note above the type.
            await Task.detached(priority: .userInitiated) {
                try? ScreenshotSaver.prepareSaveDirectory()
            }.value
        }
    }

    private var saveFolderDisplayPath: String {
        let url = ScreenshotSaver.saveDirectory
        return url.path(percentEncoded: false)
            .replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = ScreenshotSaver.saveDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolderPath = url.path(percentEncoded: false)
    }
}

#Preview {
    OnboardingSavingStep()
        .padding(36)
        .frame(width: 620, height: 480)
}
