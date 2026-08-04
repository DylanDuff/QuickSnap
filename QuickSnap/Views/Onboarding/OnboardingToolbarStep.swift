//
//  OnboardingToolbarStep.swift
//  QuickSnap
//

import SwiftUI

/// The markup toolbar's contents, arranged before the user has ever opened
/// the editor.
///
/// That ordering is deliberate but worth knowing about: this is the one step
/// asking about something the user hasn't seen yet, so the copy has to do the
/// explaining the tools themselves normally would, and the whole thing is
/// skippable with a sensible default already in place. `MarkupToolbarEditor`
/// is embedded as-is — it's the same editor as Settings → Markup, writing the
/// same stored layout, so nothing here can drift from it.
struct OnboardingToolbarStep: View {
    var body: some View {
        OnboardingStepLayout(
            systemImage: "slider.horizontal.3",
            title: "Your markup tools",
            message: "Double-click a screenshot's preview to mark it up. This is the toolbar you'll get — drag anything you want into it, and anything you don't back out."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                MarkupToolbarEditor()

                Text("Undo and redo, zoom, and the export buttons all have keyboard shortcuts whether or not they're in the toolbar.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

#Preview {
    OnboardingToolbarStep()
        .padding(36)
        .frame(width: 620, height: 480)
}
