import MacParakeetCore
import SwiftUI

/// Shows where the language request sits in the assembled prompt and the exact
/// text sent, so the setting reads as a request to the model rather than a
/// translation step.
struct AIResultLanguageExplainer: View {
    let policy: MeetingAIOutputLanguagePolicy

    private static let promptOrder: [(title: String, isLanguage: Bool)] = [
        ("Your prompt", false),
        ("Meeting notes, if included", false),
        ("Language instruction", true),
        ("Extra instructions", false),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text(
                """
                MacParakeet adds one instruction to the end of every AI prompt. The model does the writing; \
                nothing is translated afterward.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.xs) { promptOrderSteps(showsArrows: true) }
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    promptOrderSteps(showsArrows: false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "Prompt order: your prompt, meeting notes if included, language instruction, then extra instructions"
            )

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Instruction sent to the model")
                    .font(DesignSystem.Typography.micro.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text(policy.assemblyInstruction)
                    .font(DesignSystem.Typography.micro.monospaced())
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius, style: .continuous)
                    .fill(DesignSystem.Colors.surfaceElevated)
            )

            Text(
                """
                Extra instructions come last, so asking for a language there, such as \u{201C}Write in French,\u{201D} \
                overrides this setting for that result.
                """
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func promptOrderSteps(showsArrows: Bool) -> some View {
        ForEach(Array(Self.promptOrder.enumerated()), id: \.offset) { index, step in
            if showsArrows && index > 0 {
                Image(systemName: "chevron.right")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.textTertiary)
            }
            Text(step.title)
                .font(DesignSystem.Typography.micro.weight(.semibold))
                .foregroundStyle(step.isLanguage ? DesignSystem.Colors.accent : DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule()
                        .fill(
                            step.isLanguage
                                ? DesignSystem.Colors.accent.opacity(0.14)
                                : DesignSystem.Colors.surfaceElevated
                        )
                )
        }
    }
}

extension PinnedLanguageOption {
    static let followTranscript = PinnedLanguageOption(
        code: MeetingAIOutputLanguagePolicy.followTranscript.configurationValue,
        title: MeetingAIOutputLanguagePolicy.followTranscript.displayTitle,
        searchTerms: ["follow transcript", "follow-transcript", "transcript", "auto"]
    )
}
