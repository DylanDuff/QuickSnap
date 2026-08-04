//
//  OnboardingHotkeysStep.swift
//  QuickSnap
//

import SwiftUI

/// The shortcuts, shown and editable.
///
/// Teaching is half the point: OCR and Copy for AI are reachable *only* by
/// shortcut or menu, so someone who never sees this screen may never learn
/// they exist. The other half is conflicts — `RegisterEventHotKey` consumes a
/// combination system-wide and fails silently when the system already owns
/// it, so the earliest possible chance to change one is worth having.
///
/// Reuses `HotkeyRecorderField` wholesale, which brings the recording
/// behaviour, the validity rules, and the "clear it from the other action"
/// handling with it.
struct OnboardingHotkeysStep: View {
    /// Not read directly — it re-renders the list when the setting behind
    /// `HotkeyAction.isAvailable` changes, same as the Settings tab.
    @AppStorage(AppSettings.Keys.captureIndexingEnabled)
    private var isIndexingEnabled = AppSettings.Defaults.captureIndexingEnabled

    var body: some View {
        OnboardingStepLayout(
            systemImage: "command",
            title: "Keyboard shortcuts",
            message: "These work in any app while QuickSnap is running. Click one to change it."
        ) {
            VStack(spacing: 0) {
                ForEach(Array(HotkeyAction.allCases.filter(\.isAvailable).enumerated()), id: \.element) { index, action in
                    if index > 0 { Divider() }
                    HStack {
                        Text(action.displayName)
                        Spacer()
                        HotkeyRecorderField(action: action)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )
        }
    }
}

#Preview {
    OnboardingHotkeysStep()
        .padding(36)
        .frame(width: 620, height: 480)
}
