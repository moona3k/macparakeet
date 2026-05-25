import SwiftUI
import MacParakeetCore

/// Settings card surfacing the LLM-refined subtitle export feature.
///
/// Why a card (not just the Export popover toggle): the popover toggle
/// is per-export and easy to miss. This card discovers the feature and
/// exposes the one knob users actually want to tune for cost — the
/// reviewer batch size — without making them re-toggle on every export.
///
/// Storage: writes back through `TranscriptExportPreferences` so the
/// Export popover reads the exact same value next time it opens. The
/// card and the popover are two windows onto one shared
/// `TranscriptExportOptions` blob in `UserDefaults`.
struct SubtitleRefinementCard: View {
    /// Display-only — pulled from `LLMSettingsViewModel.effectiveModelName`.
    /// Lets the user verify which model their refinement calls will hit
    /// before they commit a 30-minute export to it.
    let currentModelName: String
    /// When `false`, the card shows a friendlier empty-state hint
    /// pointing at the AI Setup card above instead of letting the user
    /// configure refinement that won't actually run.
    let isLLMConfigured: Bool

    @State private var options: TranscriptExportOptions = TranscriptExportPreferences.loadOptions()

    var body: some View {
        SettingsCard(
            title: "AI Subtitle Refinement",
            subtitle: "LLM-assisted cue layout and review for SRT / VTT exports.",
            icon: "wand.and.stars",
            iconTint: DesignSystem.Colors.accent
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                Toggle(
                    "Enable AI refinement for subtitle exports by default",
                    isOn: Binding(
                        get: { options.subtitleConfig.useLLMRefinement },
                        set: { newValue in
                            options.subtitleConfig.useLLMRefinement = newValue
                            persist()
                        }
                    )
                )
                .font(DesignSystem.Typography.body)
                .disabled(!isLLMConfigured)

                if !isLLMConfigured {
                    Text("Configure a provider in **AI Setup** above to enable refinement.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Sends batches of adjacent cues to **\(currentModelName)** for context-aware boundary fixes. Slightly slower; uses your LLM provider's quota.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if options.subtitleConfig.useLLMRefinement && isLLMConfigured {
                    Divider()
                        .padding(.vertical, 2)

                    batchSizeSection
                }
            }
        }
        // Keep in sync when the popover changes the same blob — re-reads
        // on each appear so the card never shows a stale value.
        .onAppear { options = TranscriptExportPreferences.loadOptions() }
    }

    /// The cost knob. Each batch is one LLM call. A 30-min export with
    /// ~400 pairs takes ~400 calls at batch=1, ~80 at batch=5, ~40 at
    /// batch=10. Higher batch sizes use less of your LLM quota but the
    /// model has more boundaries to track in one shot — informal testing
    /// shows 5 is the sweet spot for Gemma 4 / DeepSeek class models.
    private var batchSizeSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .center) {
                Text("Reviewer batch size")
                    .font(DesignSystem.Typography.body)
                Spacer()
                Text("\(options.subtitleConfig.reviewerPairsPerBatch)")
                    .font(DesignSystem.Typography.body.monospacedDigit())
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            Slider(
                value: Binding(
                    get: { Double(options.subtitleConfig.reviewerPairsPerBatch) },
                    set: { newValue in
                        options.subtitleConfig.reviewerPairsPerBatch = Int(newValue.rounded())
                        persist()
                    }
                ),
                in: 1...10,
                step: 1
            )
            .controlSize(.small)

            Text("Smaller batches = more LLM calls but tighter context per cue. Larger batches = fewer calls but the model tracks more boundaries at once. 5 is recommended.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func persist() {
        TranscriptExportPreferences.saveOptions(options)
    }
}
