//
//  IntelligenceSettingsView.swift
//  QuickSnap
//

import AppKit
import SwiftUI

/// Intelligence tab — the master switch for anything that runs a model, plus
/// the features built on it.
///
/// The `AIProvider` seam shipped ahead of this page deliberately: a toggle
/// that controls nothing is dead UI. `{describe}` is the first consumer, so
/// this is where the switch finally lives.
///
/// Availability is read fresh every time the page appears rather than cached
/// — it changes outside the app (Apple Intelligence toggled in System
/// Settings, the model finishing its download).
struct IntelligenceSettingsView: View {
    @AppStorage(AppSettings.Keys.aiEnabled)
    private var isEnabled = AppSettings.Defaults.aiEnabled

    @AppStorage(AppSettings.Keys.filenameTemplate)
    private var filenameTemplate = AppSettings.Defaults.filenameTemplate

    @State private var availability: AIAvailability = .available

    private let provider = FoundationModelsProvider()

    var body: some View {
        Form {
            Section("Apple Intelligence") {
                Toggle("Use on-device intelligence", isOn: $isEnabled)

                Text("Runs entirely on this Mac using Apple's built-in model. No capture, and no text from a capture, is sent anywhere.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if isEnabled {
                    LabeledContent("Status") {
                        HStack(spacing: 10) {
                            switch availability {
                            case .available:
                                Label("Ready", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)

                            case .unavailable(let reason):
                                Label("Unavailable", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)

                                if reason.isResolvableInSystemSettings {
                                    Button("Open System Settings") {
                                        Self.openAppleIntelligenceSettings()
                                    }
                                }
                            }

                            Button("Re-check") { refreshAvailability() }
                        }
                    }

                    if case .unavailable(let reason) = availability {
                        Text(reason.message)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("File names") {
                Toggle("Describe captures in file names", isOn: describesFilenamesBinding)
                    .disabled(!isEnabled)

                Text("Adds the {describe} token to the file name template, so a capture is named for what it shows — “QuickSnap 2026-08-01 login-form-validation-error.png”.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // Both halves of this matter to someone watching their save
                // folder: the file appears immediately under a name that
                // doesn't have the description in it yet, and then moves.
                Text("The screenshot is saved right away and renamed a few seconds later, once the description is ready. If it can't be produced, the file keeps the name it already has.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { refreshAvailability() }
    }

    /// Derived from the template rather than stored separately — the
    /// template is the single source of truth for naming, and a second flag
    /// that could disagree with it would be a bug waiting to happen.
    private var describesFilenamesBinding: Binding<Bool> {
        Binding(
            get: { FilenameTemplate.usesDescription(filenameTemplate) },
            set: { wantsDescription in
                filenameTemplate = wantsDescription
                    ? FilenameTemplate.addingDescription(to: filenameTemplate)
                    : FilenameTemplate.removingDescription(from: filenameTemplate)
            }
        )
    }

    private func refreshAvailability() {
        availability = provider.availability
    }

    /// Apple Intelligence has its own System Settings pane; fall back to the
    /// app's own privacy page if that URL ever stops resolving.
    private static func openAppleIntelligenceSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?AppleIntelligence")
            ?? URL(string: "x-apple.systempreferences:")!
        NSWorkspace.shared.open(url)
    }
}


#Preview {
    IntelligenceSettingsView()
        .frame(width: 520, height: 450)
}
