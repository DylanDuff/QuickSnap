//
//  OnboardingPermissionStep.swift
//  QuickSnap
//

import AppKit
// Explicit, per this target's `MemberImportVisibility` — SwiftUI's re-export
// isn't enough to reach `autoconnect()`.
import Combine
import SwiftUI

/// Screen Recording permission — the one thing without which nothing in the
/// app works at all.
///
/// It polls rather than checking once: the grant happens in System Settings,
/// in another app, and there's no notification when it lands. It also says
/// the quiet part about relaunching — macOS frequently won't recognise a
/// freshly-granted permission for an already-running process, and someone
/// who grants access and watches the next capture fail anyway concludes the
/// app is broken.
struct OnboardingPermissionStep: View {
    @State private var isGranted = ScreenRecordingPermission.isGranted
    @State private var hasRequested = false

    /// System Settings can't tell us when the switch is flipped, so the only
    /// way the screen updates while the user is over there is to keep asking.
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        OnboardingStepLayout(
            systemImage: "record.circle",
            title: "Allow screen recording",
            message: "macOS asks every app for permission before it can see your screen. QuickSnap can't capture anything until you allow it."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                statusRow

                if !isGranted {
                    HStack(spacing: 10) {
                        Button("Allow Access…") {
                            hasRequested = true
                            // Triggers the system prompt the first time; on
                            // later runs macOS ignores it, which is what the
                            // System Settings button below is for.
                            isGranted = ScreenRecordingPermission.request()
                        }
                        .controlSize(.large)

                        Button("Open System Settings") {
                            ScreenRecordingPermission.openSystemSettings()
                        }
                        .controlSize(.large)
                    }

                    if hasRequested {
                        calloutRelaunch
                    }
                }
            }
        }
        .onReceive(poll) { _ in
            isGranted = ScreenRecordingPermission.isGranted
        }
    }

    private var statusRow: some View {
        Label {
            Text(isGranted ? "Screen recording is allowed." : "Screen recording is not allowed yet.")
                .font(.callout)
        } icon: {
            Image(systemName: isGranted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isGranted ? Color.green : Color.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var calloutRelaunch: some View {
        Label {
            Text("If you've just allowed it in System Settings and captures still fail, quit and reopen QuickSnap. macOS often doesn't hand a new permission to an app that's already running.")
        } icon: {
            Image(systemName: "arrow.clockwise")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    OnboardingPermissionStep()
        .padding(36)
        .frame(width: 620, height: 480)
}
