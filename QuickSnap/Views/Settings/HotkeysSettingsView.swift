//
//  HotkeysSettingsView.swift
//  QuickSnap
//

import SwiftUI
import AppKit
import Carbon.HIToolbox

struct HotkeysSettingsView: View {
    /// Not read directly — it's what makes the list re-render when the
    /// setting behind `HotkeyAction.isAvailable` changes, so the Search row
    /// appears and disappears with the feature it triggers.
    @AppStorage(AppSettings.Keys.captureIndexingEnabled)
    private var isIndexingEnabled = AppSettings.Defaults.captureIndexingEnabled

    var body: some View {

        Form {
            Section("Capture") {
                ForEach(HotkeyAction.allCases.filter(\.isAvailable), id: \.self) { action in
                    LabeledContent(action.displayName) {
                        HotkeyRecorderField(action: action)
                    }
                }
            }

            Section {
                Text("Shortcuts work system-wide while QuickSnap is running. Click one to change it, or ✕ to remove it — an action with no shortcut still works from the menu bar, and stops taking that key combination away from other apps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {

                ScreenshotShortcutsView()
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)

    }
}


// MARK: - Recorder

/// Click-to-record shortcut field. While recording, a local key monitor
/// captures the next combination: Esc cancels, Delete clears the shortcut,
/// anything `HotkeyShortcut(event:)` rejects beeps. Assigning a combination
/// already used by another action clears it there — a shortcut can only
/// trigger one thing.
struct HotkeyRecorderField: View {
    private let action: HotkeyAction

    @AppStorage private var storedData: Data
    @State private var isRecording = false
    @State private var keyMonitor: Any?

    init(action: HotkeyAction) {
        self.action = action
        _storedData = AppStorage(wrappedValue: Data(), AppSettings.Keys.hotkey(for: action))
    }

    private var shortcut: HotkeyShortcut? {
        HotkeyShortcut.decode(storedData)
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stopRecording() : beginRecording()
            } label: {
                Text(isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "None"))
                    .font(.body.monospaced())
                    .foregroundStyle(isRecording ? .secondary : .primary)
                    .frame(minWidth: 96)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)

            // Clearing was only reachable by pressing Delete *while
            // recording*, which nobody discovers. Kept in the layout at zero
            // opacity when there's nothing to clear, so the recorder buttons
            // stay aligned down the column.
            Button {
                clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(PressScaleButtonStyle())
            .help("Remove this shortcut. The action stays in the menu bar.")
            .opacity(shortcut == nil ? 0 : 1)
            .disabled(shortcut == nil)
            .accessibilityHidden(shortcut == nil)
        }
        .onDisappear { stopRecording() }
    }

    /// Empty `Data` means *explicitly cleared*, as opposed to an absent key
    /// meaning "use the action's default" — so this sticks across launches
    /// instead of the default being registered back over it.
    private func clear() {
        storedData = Data()
        stopRecording()
    }

    private func beginRecording() {
        isRecording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordingKeyDown(event)
            return nil // Swallow the keystroke — it's being recorded, not typed.
        }
    }

    private func stopRecording() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
        isRecording = false
    }

    private func handleRecordingKeyDown(_ event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            stopRecording()
        case kVK_Delete:
            clear()
        default:
            guard let newShortcut = HotkeyShortcut(event: event) else {
                NSSound.beep()
                return
            }
            assign(newShortcut)
            stopRecording()
        }
    }

    private func assign(_ newShortcut: HotkeyShortcut) {
        for other in HotkeyAction.allCases where other != action {
            if AppSettings.hotkey(for: other) == newShortcut {
                UserDefaults.standard.set(Data(), forKey: AppSettings.Keys.hotkey(for: other))
            }
        }
        storedData = newShortcut.encoded
    }
}

struct ScreenshotShortcutsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            
            Text("How to reassign default shortcuts")
                .font(.headline)
            
            // The Markdown link creates an inline clickable button
            Text("1. Open [Keyboard Settings](x-apple.systempreferences:com.apple.preference.keyboard) and click **Keyboard Shortcuts...**")
            
            Text("2. Select **Screenshots** from the left sidebar.")
            
            Text("3. Uncheck the boxes to remove the shortcuts.")
            
        }
    }
}

#Preview {
    HotkeysSettingsView()
        .frame(width: 520, height: 400)
}
