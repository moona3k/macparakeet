import SwiftUI

/// Hover-aware card shell used across all Settings tabs.
///
/// API surface (kept small on purpose):
/// - `title` + `subtitle` + `icon` — required, drives the header
/// - `status` — optional `SettingsStatusChip.Status` + label, sits in the
///   header's trailing slot. Use this when the card has a single dominant
///   status the user cares about at a glance (e.g. "Permissions: 1 missing").
/// - `content` — the card body
///
/// Kept visually identical to the prior `SettingsCardContainer` so the
/// foundation refactor introduces zero perceptual change. The status chip slot
/// is purely additive — existing callers omit it and look identical.
struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let iconTint: Color?
    let statusChip: SettingsCardStatus?
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false

    init(
        title: String,
        subtitle: String,
        icon: String,
        iconTint: Color? = nil,
        status: SettingsCardStatus? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.iconTint = iconTint
        self.statusChip = status
        self.content = content
    }

    var body: some View {
        let resolvedIconTint = iconTint ?? DesignSystem.Colors.accent
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(resolvedIconTint)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(resolvedIconTint.opacity(0.12))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.sectionTitle)
                        .accessibilityAddTraits(.isHeader)
                    Text(subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: DesignSystem.Spacing.sm)

                if let chip = statusChip {
                    SettingsStatusChip(status: chip.status, label: chip.label)
                }
            }

            content()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(isHovered ? DesignSystem.Shadows.cardHover : DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(
                    isHovered ? DesignSystem.Colors.accent.opacity(0.2) : DesignSystem.Colors.border.opacity(0.6),
                    lineWidth: 0.5
                )
        )
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                isHovered = hovering
            }
        }
    }
}

/// Lightweight value used in `SettingsCard.init(status:)` so callers don't have
/// to nest a chip view in their card declaration.
struct SettingsCardStatus: Equatable {
    let status: SettingsStatusChip.Status
    let label: String

    init(_ status: SettingsStatusChip.Status, label: String) {
        self.status = status
        self.label = label
    }
}

#Preview("Light", traits: .fixedLayout(width: 560, height: 320)) {
    VStack(spacing: DesignSystem.Spacing.lg) {
        SettingsCard(
            title: "Dictation",
            subtitle: "Global hotkey and silence behavior.",
            icon: "waveform"
        ) {
            Text("Card body content goes here.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
        }

        SettingsCard(
            title: "Permissions",
            subtitle: "Microphone and Accessibility are required.",
            icon: "lock.shield",
            status: SettingsCardStatus(.recommended, label: "1 missing")
        ) {
            Text("Permission rows would render here.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.light)
}

#Preview("Dark", traits: .fixedLayout(width: 560, height: 320)) {
    VStack(spacing: DesignSystem.Spacing.lg) {
        SettingsCard(
            title: "Dictation",
            subtitle: "Global hotkey and silence behavior.",
            icon: "waveform"
        ) {
            Text("Card body content goes here.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
        }

        SettingsCard(
            title: "Permissions",
            subtitle: "Microphone and Accessibility are required.",
            icon: "lock.shield",
            status: SettingsCardStatus(.recommended, label: "1 missing")
        ) {
            Text("Permission rows would render here.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
        }
    }
    .padding()
    .background(DesignSystem.Colors.background)
    .preferredColorScheme(.dark)
}
