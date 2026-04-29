import SwiftUI

/// Standard row inside a `SettingsCard`: leading title + caption, trailing
/// control. The trailing slot is generic — drop in a `Toggle`, `Picker`,
/// `Button`, or any composed view.
///
/// Replaces the inline `settingsToggleRow(...)` helper in the old Settings
/// view, generalised so the same primitive serves all rows (toggle, picker,
/// hotkey recorder, status chip).
struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String
    let alignment: VerticalAlignment
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        detail: String,
        alignment: VerticalAlignment = .center,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.alignment = alignment
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: alignment, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            trailing()
        }
    }
}

/// Convenience for the common case: a row whose trailing control is a
/// `Toggle`. Visually identical to the old `settingsToggleRow` helper so
/// migration is byte-for-byte compatible.
///
/// VoiceOver reads the row as one element ("Save dictation history,
/// switch, off"). The visible title is the toggle's accessibility label
/// so the toggle isn't an orphaned "switch, off" announcement.
struct SettingsToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, detail: detail, alignment: .top) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
    }
}

#Preview("Light", traits: .fixedLayout(width: 560, height: 320)) {
    @Previewable @State var toggleOn = true
    @Previewable @State var toggleOff = false

    return VStack(spacing: DesignSystem.Spacing.md) {
        SettingsToggleRow(
            title: "Show dictation pill at all times",
            detail: "When off, the pill hides until you press the hotkey.",
            isOn: $toggleOn
        )

        Divider()

        SettingsToggleRow(
            title: "Launch at login",
            detail: "Start MacParakeet automatically when you sign in.",
            isOn: $toggleOff
        )

        Divider()

        SettingsRow(
            title: "Silence delay",
            detail: "How long silence must persist before dictation stops."
        ) {
            Text("2 sec")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
        }
    }
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.cardBackground)
    .preferredColorScheme(.light)
}

#Preview("Dark", traits: .fixedLayout(width: 560, height: 320)) {
    @Previewable @State var toggleOn = true
    @Previewable @State var toggleOff = false

    return VStack(spacing: DesignSystem.Spacing.md) {
        SettingsToggleRow(
            title: "Show dictation pill at all times",
            detail: "When off, the pill hides until you press the hotkey.",
            isOn: $toggleOn
        )

        Divider()

        SettingsToggleRow(
            title: "Launch at login",
            detail: "Start MacParakeet automatically when you sign in.",
            isOn: $toggleOff
        )
    }
    .padding(DesignSystem.Spacing.lg)
    .background(DesignSystem.Colors.cardBackground)
    .preferredColorScheme(.dark)
}
