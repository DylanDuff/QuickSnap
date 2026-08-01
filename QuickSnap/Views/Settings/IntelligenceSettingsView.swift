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

    @AppStorage(AppSettings.Keys.captureIndexingEnabled)
    private var isIndexingEnabled = AppSettings.Defaults.captureIndexingEnabled

    @AppStorage(AppSettings.Keys.hotkey(for: .searchCaptures))
    private var searchHotkeyData = Data()

    @State private var availability: AIAvailability = .available

    /// The same indexer the capture path feeds — this page both watches its
    /// progress and drives it.
    @ObservedObject private var indexer = CaptureIndexer.shared

    private let provider = FoundationModelsProvider()

    var body: some View {
        Form {
            Section("Apple Intelligence") {
                Toggle("Use on-device intelligence", isOn: $isEnabled)

                Text("Everything runs on this Mac using Apple's built-in model. Your screenshots and the text in them never leave your computer.")
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

                // One block rather than two: someone watching their save
                // folder needs the naming *and* the fact that the file
                // appears first and moves afterwards.
                Text("Names captures after what they show, like “QuickSnap 2026-08-01 login-form-validation-error.png”, by adding {describe} to your file name template. Screenshots save straight away and are renamed a few seconds later, once the description is ready.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Search") {
                Toggle("Index captures so you can search them", isOn: $isIndexingEnabled)

                Text("Reads the text in each screenshot as you save it, so you can find a capture later by something written in it. The index stays on this Mac, and only screenshots QuickSnap saved are ever read.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                if isIndexingEnabled {
                    LabeledContent("Index") {
                        HStack(spacing: 10) {
                            if let backfill = indexer.backfill {
                                ProgressView(value: backfill.fraction)
                                    .frame(width: 110)
                                Text("\(backfill.completed) of \(backfill.total)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Button("Stop") { indexer.cancelBackfill() }
                            } else {
                                Text("\(indexer.indexedCount) \(indexer.indexedCount == 1 ? "capture" : "captures")")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                Button("Rebuild") { indexer.rebuild() }
                                    .help("Reads every screenshot in your save folder again. Useful after turning on Apple Intelligence, so older captures get descriptions too.")
                            }
                        }
                    }

                    Text("Search from the menu bar, or press \(searchShortcutDescription). Return shows a capture in the Finder, ⌘Return opens it for markup.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            MCPSettingsSection()
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

    /// The recorded shortcut, or a plain description when it's been cleared
    /// — the menu bar item is always there either way.
    private var searchShortcutDescription: String {
        HotkeyShortcut.decode(searchHotkeyData)?.displayString ?? "the shortcut set in Hotkeys"
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
