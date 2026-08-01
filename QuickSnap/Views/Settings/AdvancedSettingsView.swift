//
//  AdvancedSettingsView.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Advanced tab — deliberately **not** a bucket for power-user features.
/// Anything a user would go looking for belongs on the page it relates to;
/// what lands here is the narrow category of things that are diagnostic or
/// destructive: permission troubleshooting, a bug-report summary, file
/// retention, and reset.
struct AdvancedSettingsView: View {
    @AppStorage(AppSettings.Keys.retentionDays)
    private var retentionDays = AppSettings.Defaults.retentionDays

    @AppStorage(AppSettings.Keys.uploadTimeoutSeconds)
    private var uploadTimeout = AppSettings.Defaults.uploadTimeoutSeconds

    @AppStorage(AppSettings.Keys.uploadRetryCount)
    private var uploadRetries = AppSettings.Defaults.uploadRetryCount

    @State private var hasScreenRecordingAccess = false
    @State private var expiredFileCount = 0
    @State private var isConfirmingReset = false
    @State private var isConfirmingCleanup = false
    @State private var didCopyDiagnostics = false

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Screen Recording") {
                    HStack(spacing: 10) {
                        Label(
                            hasScreenRecordingAccess ? "Granted" : "Not granted",
                            systemImage: hasScreenRecordingAccess
                                ? "checkmark.circle.fill"
                                : "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(hasScreenRecordingAccess ? .green : .orange)

                        Button("Re-check") { refreshPermission() }

                        Button("Open System Settings") {
                            ScreenRecordingPermission.openSystemSettings()
                        }
                    }
                }

                // The single most common source of "QuickSnap is broken"
                // confusion — macOS keeps handing the old answer to an
                // already-running process. Say it before it bites.
                Text("macOS often keeps reporting the old answer to an app that's already running. If you've just granted access and captures still fail, quit and reopen QuickSnap.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Uploading") {
                LabeledContent("Request timeout") {
                    SliderWithValue(value: $uploadTimeout, in: 5...120, step: 5) {
                        "\(Int($0))s"
                    }
                }

                LabeledContent("Retry attempts") {
                    Stepper(value: $uploadRetries, in: 0...5) {
                        Text(uploadRetries == 0 ? "Don't retry" : "\(uploadRetries)")
                            .monospacedDigit()
                    }
                }

                Text("Only transient failures are retried — timeouts, dropped connections, and server errors. A rejected key or a missing bucket fails immediately.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Storage") {
                LabeledContent("Delete captures after") {
                    HStack(spacing: 10) {
                        Picker("Delete captures after", selection: $retentionDays) {
                            Text("Never").tag(0)
                            Text("7 days").tag(7)
                            Text("30 days").tag(30)
                            Text("90 days").tag(90)
                            Text("1 year").tag(365)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)

                        if retentionDays > 0 {
                            Button("Clean Up Now") { isConfirmingCleanup = true }
                                .disabled(expiredFileCount == 0)
                        }
                    }
                }

                if retentionDays > 0 {
                    Text(expiredFileCount == 0
                        ? "Nothing is old enough to remove yet."
                        : "\(expiredFileCount) file\(expiredFileCount == 1 ? "" : "s") can be moved to the Trash.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                // The safety property is the whole reason this feature is
                // acceptable in a user-chosen folder — state it plainly.
                Text("Only files QuickSnap saved are ever removed, and they go to the Trash, not straight to deletion. Anything else in the folder is left alone, even if it's older.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                HStack(spacing: 10) {
                    Button("Copy Diagnostics") { copyDiagnostics() }

                    if didCopyDiagnostics {
                        Label("Copied", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.footnote)
                    }
                }

                Text("Copies your version, permission state, and settings summary for bug reports. Server addresses, keys, and folder paths are excluded.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Reset") {
                Button("Reset All Settings…", role: .destructive) {
                    isConfirmingReset = true
                }

                Text("Restores every setting to its default and removes stored upload credentials from the Keychain. Your saved screenshots are not touched.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear {
            refreshPermission()
            refreshExpiredCount()
        }
        .onChange(of: retentionDays) { refreshExpiredCount() }
        .confirmationDialog(
            "Reset all settings?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Reset Everything", role: .destructive) {
                AppSettings.resetAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every preference returns to its default and your Immich and S3 credentials are removed. This can't be undone.")
        }
        .confirmationDialog(
            "Move \(expiredFileCount) file\(expiredFileCount == 1 ? "" : "s") to the Trash?",
            isPresented: $isConfirmingCleanup,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { cleanUpNow() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only captures QuickSnap saved, older than the retention period, are affected.")
        }
    }

    private func refreshPermission() {
        hasScreenRecordingAccess = ScreenRecordingPermission.isGranted
    }

    /// Off the main thread: enumerating the save folder is TCC-gated and can
    /// block inside the syscall on first access (see CLAUDE.md).
    private func refreshExpiredCount() {
        let days = retentionDays
        Task {
            let count = await Task.detached(priority: .utility) {
                SaveFolderCleaner.countExpired(olderThan: days)
            }.value
            expiredFileCount = count
        }
    }

    private func cleanUpNow() {
        let days = retentionDays
        Task {
            _ = await Task.detached(priority: .utility) {
                SaveFolderCleaner.clean(olderThan: days)
            }.value
            refreshExpiredCount()
        }
    }

    /// A redacted summary for bug reports. Deliberately excludes server
    /// addresses, bucket names, key prefixes and the save folder path —
    /// people paste this into public issue trackers.
    private func copyDiagnostics() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"

        let summary = """
        QuickSnap \(version) (\(build))
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Screen Recording: \(ScreenRecordingPermission.isGranted ? "granted" : "not granted")
        Launch at login: \(LoginItem.isEnabled)
        Displays: \(NSScreen.screens.count)

        Format: \(AppSettings.imageFormat.displayName) at \(Int(AppSettings.imageQuality * 100))%
        Filename template: \(AppSettings.filenameTemplate == AppSettings.Defaults.filenameTemplate ? "default" : "custom")
        Custom save folder: \(UserDefaults.standard.string(forKey: AppSettings.Keys.saveFolderPath)?.isEmpty == false)
        Pointer in captures: \(AppSettings.showsCursorInCaptures)
        Window background: \(AppSettings.windowBackgroundStyle.rawValue)
        Retention: \(AppSettings.retentionDays == 0 ? "never" : "\(AppSettings.retentionDays) days")

        After capture — save: \(AppSettings.savesAfterCapture), \
        copy: \(AppSettings.copiesAfterCapture), preview: \(AppSettings.showsPreviewAfterCapture)

        Uploading: \(AppSettings.uploadDestination == nil ? "not configured" : AppSettings.uploadProvider.displayName)
        Auto-upload: \(AppSettings.uploadsAfterCapture)
        Copies link: \(AppSettings.uploadCopiesLink)
        Timeout: \(Int(AppSettings.uploadTimeoutSeconds))s, retries: \(AppSettings.uploadRetryCount)
        """

        ScreenshotSaver.copyToClipboard(summary)
        didCopyDiagnostics = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyDiagnostics = false
        }
    }
}


#Preview {
    AdvancedSettingsView()
        .frame(width: 520, height: 450)
}
