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
    let currentModelName: String
    /// When `false`, the card shows a friendlier empty-state hint
    /// pointing at the AI Setup card above instead of letting the user
    /// configure refinement that won't actually run.
    let isLLMConfigured: Bool
    /// Resolved model profile from the last successful connection test or save.
    /// `nil` until the first fetch completes.
    let activeProfile: ModelProfile?

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

                    if let profile = activeProfile {
                        modelProfileBadge(profile)
                        Text("Refreshes when you run **Test Connection** in AI Setup. Tunes prompt style, parser tolerance, and the suggested batch size below.")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
    /// batch=10. Higher batch sizes save quota but the model tracks more
    /// boundaries at once. The profile suggestion is tuned per model family
    /// and size class.
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

            if let profile = activeProfile,
               profile.suggestedBatchSize != options.subtitleConfig.reviewerPairsPerBatch {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.accent)
                    Text("Profile suggests **\(profile.suggestedBatchSize)** for \(profile.displayName)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Button("Apply") {
                        options.subtitleConfig.reviewerPairsPerBatch = profile.suggestedBatchSize
                        persist()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                }
            }

            Text("Smaller batches = more LLM calls but tighter context per cue. Larger batches = fewer calls but the model tracks more boundaries at once.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Profile badge

    @ViewBuilder
    private func modelProfileBadge(_ profile: ModelProfile) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "cpu.fill")
                .font(.system(size: 10))
                .foregroundStyle(DesignSystem.Colors.accent.opacity(0.7))

            Text(profileBadgeText(profile))
                .font(DesignSystem.Typography.micro.weight(.medium))
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if profile.quirks.isEmpty == false {
                profileQuirkPills(profile)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                        .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 1)
                )
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func profileBadgeText(_ profile: ModelProfile) -> String {
        var parts = [profile.badge]
        switch profile.parserLeniency {
        case .lenient: parts.append("lenient parser")
        case .strict: parts.append("strict parser")
        case .normal: break
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func profileQuirkPills(_ profile: ModelProfile) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(profile.quirks), id: \.rawValue) { quirk in
                Text(quirkLabel(quirk))
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DesignSystem.Colors.warningAmber.opacity(0.10)))
            }
        }
    }

    private func quirkLabel(_ quirk: ModelProfile.ModelQuirk) -> String {
        switch quirk {
        case .addsLineComments: return "adds comments"
        case .skipsWordIndices: return "skips indices"
        }
    }

    private func persist() {
        TranscriptExportPreferences.saveOptions(options)
    }
}
