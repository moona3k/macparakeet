import SwiftUI

/// Red-tinted bordered button with built-in confirmation alert.
///
/// Wraps the SwiftUI `.alert` modifier and `Button(role: .destructive)` pattern
/// behind a single primitive, so the Reset & Cleanup card can declare three
/// destructive actions without each one re-implementing the confirmation
/// dance. Uses the native `.alert` modifier — a custom modal would buy a
/// different look but no actual behavior the platform doesn't already give us.
///
/// `accessibilityLabel` overrides the visible button text for VoiceOver. This
/// matters in the Reset & Cleanup card where each row's title carries the
/// "what" ("Dictation history") and the visible button is just the verb
/// ("Clear…") — VoiceOver users hear the row title via the surrounding
/// `rowText`, but their cursor still lands on the button alone, so the button
/// needs to read as a complete instruction in isolation.
struct SettingsDestructiveButton: View {
    let title: String
    let accessibilityLabelOverride: String?
    let confirmationTitle: String
    let confirmationMessage: String
    let confirmButtonLabel: String
    let action: () -> Void

    @State private var isPresented = false

    init(
        title: String,
        accessibilityLabel: String? = nil,
        confirmationTitle: String,
        confirmationMessage: String,
        confirmButtonLabel: String,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accessibilityLabelOverride = accessibilityLabel
        self.confirmationTitle = confirmationTitle
        self.confirmationMessage = confirmationMessage
        self.confirmButtonLabel = confirmButtonLabel
        self.action = action
    }

    var body: some View {
        Button(role: .destructive) {
            isPresented = true
        } label: {
            Text(title)
                .foregroundStyle(DesignSystem.Colors.errorRed)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(accessibilityLabelOverride ?? title)
        .alert(confirmationTitle, isPresented: $isPresented) {
            Button("Cancel", role: .cancel) {}
            Button(confirmButtonLabel, role: .destructive, action: action)
        } message: {
            Text(confirmationMessage)
        }
    }
}

#Preview("Light", traits: .fixedLayout(width: 420, height: 200)) {
    VStack(spacing: DesignSystem.Spacing.md) {
        SettingsDestructiveButton(
            title: "Clear All Dictations...",
            confirmationTitle: "Clear All Dictations?",
            confirmationMessage: "This will permanently delete all dictations and their audio files. This cannot be undone.",
            confirmButtonLabel: "Clear All"
        ) {}

        SettingsDestructiveButton(
            title: "Reset Lifetime Stats...",
            confirmationTitle: "Reset Lifetime Stats?",
            confirmationMessage: "This will zero your lifetime stats. Your dictation history is not affected.",
            confirmButtonLabel: "Reset"
        ) {}
    }
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.light)
}

#Preview("Dark", traits: .fixedLayout(width: 420, height: 200)) {
    VStack(spacing: DesignSystem.Spacing.md) {
        SettingsDestructiveButton(
            title: "Clear All Dictations...",
            confirmationTitle: "Clear All Dictations?",
            confirmationMessage: "This will permanently delete all dictations.",
            confirmButtonLabel: "Clear All"
        ) {}
    }
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.dark)
}
