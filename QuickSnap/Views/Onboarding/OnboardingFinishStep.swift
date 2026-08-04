//
//  OnboardingFinishStep.swift
//  QuickSnap
//

import SwiftUI

/// Last screen: the one remaining toggle worth setting, and a disclosure.
///
/// The disclosure is the part that isn't a preference. Capture indexing is on
/// by default — QuickSnap runs local OCR over everything it saves so the
/// search panel can find it — and a screenshot tool quietly reading the text
/// of every capture is exactly the sort of thing a user should hear from us
/// first rather than discover later. Saying it here also surfaces the search
/// panel, which otherwise nobody finds.
struct OnboardingFinishStep: View {
    @AppStorage(AppSettings.Keys.captureIndexingEnabled)
    private var isIndexingEnabled = AppSettings.Defaults.captureIndexingEnabled
    @State private var launchesAtLogin = LoginItem.isEnabled

    var body: some View {
        OnboardingStepLayout(
            systemImage: "checkmark.seal",
            title: "You're set up",
            message: "Two last things, then it's out of your way."
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
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

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Make screenshots searchable", isOn: $isIndexingEnabled)

                    Text("QuickSnap reads the text in each screenshot it saves and keeps an index on this Mac, so you can search your captures by what's in them. Nothing is uploaded, and turning this off removes the search.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                Text("Everything here — and a lot more — lives in Settings, from the menu bar icon.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { launchesAtLogin = LoginItem.isEnabled }
    }

    /// Reads the real `SMAppService` status rather than a stored flag: the
    /// user can revoke login items in System Settings, and a failed
    /// registration has to snap the toggle back. Same pattern as General.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchesAtLogin },
            set: { newValue in
                LoginItem.setEnabled(newValue)
                launchesAtLogin = LoginItem.isEnabled
            }
        )
    }
}

#Preview {
    OnboardingFinishStep()
        .padding(36)
        .frame(width: 620, height: 480)
}
