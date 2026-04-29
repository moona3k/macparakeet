import SwiftUI

/// First-run / no-config state shown inside a card when there is nothing yet
/// to configure (e.g. AI tab before any provider has been set up). Keeps the
/// card's footprint instead of collapsing it, so the IA reads as deliberate
/// rather than incomplete.
struct SettingsEmptyState: View {
    let icon: String
    let title: String
    let message: String
    let actionLabel: String?
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        message: String,
        actionLabel: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.actionLabel = actionLabel
        self.action = action
    }

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(DesignSystem.Colors.accent.opacity(0.7))
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            Text(title)
                .font(DesignSystem.Typography.sectionTitle)
                .multilineTextAlignment(.center)

            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            if let actionLabel, let action {
                Button(actionLabel, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity)
    }
}

#Preview("With action", traits: .fixedLayout(width: 560, height: 280)) {
    SettingsEmptyState(
        icon: "sparkles",
        title: "No AI provider configured",
        message: "Add Claude, OpenAI, or a local model to power transcript summaries and chat.",
        actionLabel: "Add provider"
    ) {}
        .padding(DesignSystem.Spacing.lg)
        .background(DesignSystem.Colors.cardBackground)
        .preferredColorScheme(.light)
}

#Preview("No action — dark", traits: .fixedLayout(width: 560, height: 240)) {
    SettingsEmptyState(
        icon: "magnifyingglass",
        title: "No matches",
        message: "Try a different keyword."
    )
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.cardBackground)
    .preferredColorScheme(.dark)
}
