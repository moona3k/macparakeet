import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Shown when the user asks to remember speakers, before anything is stored.
///
/// A sheet rather than an alert: this needs several lines and a refusable
/// affirmation. Acceptance requires an explicit button click.
struct VoiceProfileConsentSheet: View {
    @Bindable var viewModel: SettingsViewModel

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header
            points
            actionRow
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(width: 460)
        .background(.thickMaterial)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "waveform.badge.person")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Remember Speakers")
                    .font(DesignSystem.Typography.pageTitle)
                Text("Before MacParakeet keeps anyone's voice.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var points: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            point(
                "person.crop.circle.badge.checkmark",
                "When you name someone in a transcript, MacParakeet can keep a sample of their voice and suggest that name in later meetings. It never applies a name on its own."
            )
            point(
                "hand.raised",
                "Voice profiles contain sensitive biometric information. Only enable this feature when you have permission from the people being recorded."
            )
            point(
                "lock.laptopcomputer",
                "Voice samples stay in your local library and are excluded from transcript exports and support bundles. Manage or delete stored voices in Settings."
            )
            point(
                "clock.arrow.circlepath",
                "Temporary voice samples expire after seven days. Expired samples cannot be used; cleanup runs while MacParakeet is open and resumes at the next launch."
            )
        }
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(text)
                .font(DesignSystem.Typography.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var actionRow: some View {
        HStack {
            Spacer()
            Button("Not Now") {
                viewModel.resolveVoiceprintConsent(accepted: false)
                dismiss()
            }
            .parakeetAction(.secondary)
            .keyboardShortcut(.cancelAction)

            Button("I Have Permission") {
                viewModel.resolveVoiceprintConsent(accepted: true)
                dismiss()
            }
            .parakeetAction(.primaryProminent)
        }
    }
}
