import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

/// Shown when the user asks to remember speakers, before anything is stored.
///
/// A sheet rather than an alert: this needs several lines and a refusable
/// affirmation, and the acceptance button carries the affirmation itself, so
/// there is no way to accept without reading what is being affirmed.
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
                "A voice sample is biometric data, and laws such as BIPA, CUBI and the GDPR regulate keeping one. What they require differs, and the responsibility is yours as the person recording."
            )
            point(
                "lock.laptopcomputer",
                "Samples stay on this Mac. They are never uploaded, never written to exports or support bundles, and you can delete any of them at any time."
            )
            point(
                "clock.arrow.circlepath",
                "Voices you never name are held for at most seven days, then deleted."
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
