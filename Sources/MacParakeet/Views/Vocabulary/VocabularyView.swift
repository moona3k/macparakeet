import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct VocabularyView: View {
    @Bindable var settingsViewModel: SettingsViewModel
    @Bindable var customWordsViewModel: CustomWordsViewModel
    @Bindable var textSnippetsViewModel: TextSnippetsViewModel

    @State private var showCustomWords = false
    @State private var showTextSnippets = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                policyHeaderCard
                modeSelectionCard
                capabilityCard
                if settingsViewModel.processingMode == "clean" {
                    pipelineCard
                } else {
                    rawModeCard
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .sheet(isPresented: $showCustomWords) {
            settingsViewModel.refreshStats()
        } content: {
            CustomWordsView(viewModel: customWordsViewModel)
                .frame(minWidth: 620, minHeight: 460)
        }
        .sheet(isPresented: $showTextSnippets) {
            settingsViewModel.refreshStats()
        } content: {
            TextSnippetsView(viewModel: textSnippetsViewModel)
                .frame(minWidth: 620, minHeight: 460)
        }
        .onAppear {
            settingsViewModel.refreshStats()
        }
    }

    // MARK: - Header

    private var policyHeaderCard: some View {
        vocabularyCard(
            title: "Text Processing Policy",
            subtitle: "Choose how dictation text should be delivered to downstream apps.",
            icon: "text.quote"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 130), spacing: DesignSystem.Spacing.sm)],
                spacing: DesignSystem.Spacing.sm
            ) {
                summaryChip(
                    title: "Current Mode",
                    value: settingsViewModel.processingMode == "clean" ? "Clean" : "Raw"
                )
                summaryChip(
                    title: "Custom Words",
                    value: "\(settingsViewModel.customWordCount)"
                )
                summaryChip(
                    title: "Snippets",
                    value: "\(settingsViewModel.snippetCount)"
                )
            }
        }
    }

    // MARK: - Mode Selection

    private var modeSelectionCard: some View {
        vocabularyCard(
            title: "Mode Selection",
            subtitle: "Switch policy instantly. Changes apply to the next dictation.",
            icon: "slider.horizontal.3"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSystem.Spacing.md)],
                spacing: DesignSystem.Spacing.md
            ) {
                modeCard(
                    title: "Raw",
                    subtitle: "As spoken",
                    detail: "No deterministic cleanup. Useful for verbatim capture.",
                    icon: "waveform",
                    isSelected: settingsViewModel.processingMode == "raw"
                ) {
                    settingsViewModel.processingMode = "raw"
                }

                modeCard(
                    title: "Clean",
                    subtitle: "Polished",
                    detail: "Applies deterministic pipeline rules before output.",
                    icon: "sparkles",
                    isSelected: settingsViewModel.processingMode == "clean"
                ) {
                    settingsViewModel.processingMode = "clean"
                }
            }
        }
    }

    private var capabilityCard: some View {
        vocabularyCard(
            title: "What Clean Mode Does",
            subtitle: "Deterministic transforms, no cloud calls.",
            icon: "checkmark.shield"
        ) {
            VStack(spacing: DesignSystem.Spacing.sm) {
                capabilityRow(icon: "wind", text: "Removes common filler words.")
                capabilityRow(icon: "character.book.closed", text: "Applies custom word corrections and casing anchors.")
                capabilityRow(icon: "text.insert", text: "Expands phrase snippets into full text.")
                capabilityRow(icon: "textformat", text: "Normalizes whitespace and punctuation spacing.")
            }
        }
    }

    // MARK: - Pipeline Cards

    private var pipelineCard: some View {
        vocabularyCard(
            title: "Clean Pipeline",
            subtitle: "Ordered deterministic stages.",
            icon: "list.number"
        ) {
            VStack(spacing: 0) {
                pipelineStep(
                    number: 1,
                    title: "Remove fillers",
                    detail: "um, uh, like, you know",
                    actionTitle: nil,
                    action: nil
                )

                dividerLine

                pipelineStep(
                    number: 2,
                    title: "Fix words",
                    detail: "\(settingsViewModel.customWordCount) custom correction\(settingsViewModel.customWordCount == 1 ? "" : "s")",
                    actionTitle: "Manage words",
                    action: {
                        customWordsViewModel.loadWords()
                        showCustomWords = true
                    }
                )

                dividerLine

                pipelineStep(
                    number: 3,
                    title: "Expand snippets",
                    detail: "\(settingsViewModel.snippetCount) phrase snippet\(settingsViewModel.snippetCount == 1 ? "" : "s")",
                    actionTitle: "Manage snippets",
                    action: {
                        textSnippetsViewModel.loadSnippets()
                        showTextSnippets = true
                    }
                )

                dividerLine

                pipelineStep(
                    number: 4,
                    title: "Clean whitespace",
                    detail: "Fixes spacing and punctuation boundaries",
                    actionTitle: nil,
                    action: nil
                )
            }
            .padding(.top, 2)
        }
    }

    private var rawModeCard: some View {
        vocabularyCard(
            title: "Raw Mode Active",
            subtitle: "Pipeline transforms are bypassed.",
            icon: "waveform.badge.exclamationmark"
        ) {
            Text("Switch to Clean mode when you want deterministic corrections, snippet expansion, and formatting cleanup.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Reusable

    private var dividerLine: some View {
        Divider()
            .padding(.leading, 48)
    }

    private func vocabularyCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .frame(width: 30, height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystem.Colors.accent.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DesignSystem.Typography.sectionTitle)
                    Text(subtitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .fill(DesignSystem.Colors.cardBackground)
                .cardShadow(DesignSystem.Shadows.cardRest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                .strokeBorder(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private func summaryChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.body.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private func capabilityRow(icon: String, text: String) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 22)
            Text(text)
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func modeCard(
        title: String,
        subtitle: String,
        detail: String,
        icon: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.successGreen)
                    }
                }

                Text(title)
                    .font(DesignSystem.Typography.sectionTitle)
                    .foregroundStyle(.primary)

                Text(subtitle)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)

                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .fill(isSelected ? DesignSystem.Colors.accentLight : DesignSystem.Colors.surfaceElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Layout.cardCornerRadius)
                    .strokeBorder(
                        isSelected ? DesignSystem.Colors.accent.opacity(0.5) : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.2 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func pipelineStep(
        number: Int,
        title: String,
        detail: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Text("\(number)")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(DesignSystem.Typography.body)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let actionTitle, let action {
                Button(actionTitle) {
                    action()
                }
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .buttonStyle(.bordered)
                .tint(DesignSystem.Colors.accent)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }
}
