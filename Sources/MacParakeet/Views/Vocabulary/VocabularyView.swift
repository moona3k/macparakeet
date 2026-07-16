import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct VocabularyView: View {
    @Bindable var settingsViewModel: SettingsViewModel
    @Bindable var customWordsViewModel: CustomWordsViewModel
    @Bindable var textSnippetsViewModel: TextSnippetsViewModel
    @Bindable var backupViewModel: VocabularyBackupViewModel

    @State private var showCustomWords = false
    @State private var showTextSnippets = false
    @State private var hoveredCardTitle: String?
    @State private var hoveredModeTitle: String?

    private var selectedMode: Dictation.ProcessingMode {
        Dictation.ProcessingMode(rawValue: settingsViewModel.processingMode) ?? .raw
    }

    private var selectedInsertionStyle: DictationInsertionStyle {
        settingsViewModel.dictationInsertionStyle
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                pageHeader
                modeSelectionCard
                voiceReturnCard
                if selectedMode == .raw {
                    rawModeCard
                } else {
                    pipelineCard
                    VocabularyBackupSection(
                        viewModel: backupViewModel,
                        wordCount: settingsViewModel.customWordCount,
                        snippetCount: settingsViewModel.snippetCount
                    )
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
        .sheet(isPresented: $showCustomWords) {
            settingsViewModel.refreshStats()
        } content: {
            CustomWordsView(
                viewModel: customWordsViewModel,
                recognitionStatus: settingsViewModel.customVocabularyRecognitionStatus
            )
                .frame(width: 640, height: 560)
        }
        .sheet(isPresented: $showTextSnippets) {
            settingsViewModel.refreshStats()
        } content: {
            TextSnippetsView(viewModel: textSnippetsViewModel)
                .frame(width: 640, height: 560)
        }
        .onAppear {
            settingsViewModel.refreshStats()
        }
    }

    // MARK: - Header

    private var pageHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Vocabulary")
                .font(DesignSystem.Typography.pageTitle)
            Text("How your voice becomes text — entirely on your Mac.")
                .font(DesignSystem.Typography.bodySmall)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, DesignSystem.Spacing.xs)
    }

    // MARK: - Mode Selection

    private var modeSelectionCard: some View {
        vocabularyCard(
            title: "Mode",
            subtitle: "Switch anytime. Takes effect on your next dictation.",
            icon: "slider.horizontal.3"
        ) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 220), spacing: DesignSystem.Spacing.md)],
                spacing: DesignSystem.Spacing.md
            ) {
                modeCard(
                    title: "Raw",
                    subtitle: "As spoken",
                    detail: "Exactly as you spoke it. No corrections applied.",
                    icon: "waveform",
                    isSelected: selectedMode == .raw
                ) {
                    settingsViewModel.processingMode = Dictation.ProcessingMode.raw.rawValue
                }

                modeCard(
                    title: "Clean",
                    subtitle: "Polished",
                    detail: "Polishes your text — removes fillers, fixes words, expands snippets.",
                    icon: "sparkles",
                    isSelected: selectedMode == .clean
                ) {
                    settingsViewModel.processingMode = Dictation.ProcessingMode.clean.rawValue
                }

            }
        }
    }

    // MARK: - Pipeline Cards

    private var pipelineCard: some View {
        vocabularyCard(
            title: "Clean Pipeline",
            subtitle: "These steps run in order on every Clean dictation.",
            icon: "list.number"
        ) {
            VStack(spacing: 0) {
                insertionStyleRow

                dividerLine

                pipelineStep(
                    number: 1,
                    title: "Remove fillers",
                    detail: "uh, umm, uhh",
                    actionTitle: nil,
                    action: nil
                )

                dividerLine

                pipelineStep(
                    number: 2,
                    title: "Fix words",
                    detail: "\(customWordCountLabel) · \(settingsViewModel.customVocabularyRecognitionStatus.title)",
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
                    title: "Shape text",
                    detail: "Spacing, casing, and ending punctuation",
                    actionTitle: nil,
                    action: nil
                )
            }
            .padding(.top, 2)
        }
    }

    private var customWordCountLabel: String {
        "\(settingsViewModel.customWordCount) custom correction\(settingsViewModel.customWordCount == 1 ? "" : "s")"
    }

    private var insertionStyleRow: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "text.cursor")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.accent)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(DesignSystem.Colors.accent.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("Insertion style")
                    .font(DesignSystem.Typography.body)
                Text(selectedInsertionStyle.detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            VStack(alignment: .trailing, spacing: 6) {
                Picker("Insertion style", selection: $settingsViewModel.dictationInsertionStyle) {
                    ForEach(DictationInsertionStyle.allCases, id: \.self) { style in
                        Text(style.displayTitle).tag(style)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 210)

                Text(selectedInsertionStyle.previewText)
                    .font(DesignSystem.Typography.caption.monospaced())
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                            .fill(DesignSystem.Colors.surfaceElevated)
                    )
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }

    // MARK: - Voice Return

    private var voiceReturnCard: some View {
        vocabularyCard(
            title: "Voice Return",
            subtitle: "Submit commands, send messages, or confirm prompts — hands-free.",
            icon: "return"
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Toggle(isOn: $settingsViewModel.voiceReturnEnabled) {
                        Text("Enable Voice Return")
                            .font(DesignSystem.Typography.body)
                    }
                    .parakeetSwitch()
                }

                if settingsViewModel.voiceReturnEnabled {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Trigger phrases")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(.secondary)

                        if settingsViewModel.voiceReturnTriggers.isEmpty {
                            Text("Add at least one trigger phrase to activate Voice Return.")
                                .font(DesignSystem.Typography.micro)
                                .foregroundStyle(DesignSystem.Colors.warningAmber)
                        } else {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                                ForEach(Array(settingsViewModel.voiceReturnTriggers.enumerated()), id: \.element) { index, trigger in
                                    voiceReturnTriggerRow(trigger: trigger, index: index)
                                }
                            }
                        }

                        voiceReturnAddRow
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "info.circle")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("Say any listed phrase at the end of a dictation to simulate a Return keypress. The trigger must be the last words spoken — if it appears mid-sentence, it's pasted as normal text.")
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(.secondary)
                        }

                        let trigger = settingsViewModel.voiceReturnExampleTrigger
                        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                            exampleRow(input: "git status \(trigger)", result: "Pastes \"git status\" + presses ⏎", fires: true)
                            exampleRow(input: "\(trigger)", result: "Just presses ⏎ (nothing to paste)", fires: true)
                            if let secondaryTrigger = settingsViewModel.voiceReturnTriggers.dropFirst().first {
                                exampleRow(input: "git status \(secondaryTrigger)", result: "Also presses ⏎", fires: true)
                            }
                            exampleRow(input: "the \(trigger) was broken", result: "Pastes as-is — trigger is mid-sentence", fires: false)
                            exampleRow(input: "git status", result: "Pastes as-is — no trigger spoken", fires: false)
                        }
                        .padding(.leading, DesignSystem.Spacing.lg)
                    }

                }
            }
        }
    }

    private func voiceReturnTriggerRow(trigger: String, index: Int) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "return")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(trigger)
                .font(DesignSystem.Typography.caption.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: DesignSystem.Spacing.sm)
            DeleteIconButton(
                helpText: settingsViewModel.voiceReturnTriggers.count > 1
                    ? "Remove trigger phrase"
                    : "Voice Return needs at least one trigger phrase",
                accessibilityName: "Remove \(trigger)"
            ) {
                settingsViewModel.deleteVoiceReturnTrigger(at: index)
            }
            .disabled(settingsViewModel.voiceReturnTriggers.count <= 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 360)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private var voiceReturnAddRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ParakeetTextField(
                    placeholder: "Add phrase",
                    text: $settingsViewModel.voiceReturnNewTrigger,
                    onSubmit: { settingsViewModel.addVoiceReturnTrigger() }
                )
                .frame(maxWidth: 250)

                Button {
                    settingsViewModel.addVoiceReturnTrigger()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .parakeetAction(.secondary)
                .disabled(
                    settingsViewModel.voiceReturnNewTrigger
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty
                )
            }

            if let message = settingsViewModel.voiceReturnErrorMessage {
                Text(message)
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
            }
        }
    }

    private var rawModeCard: some View {
        vocabularyCard(
            title: "Raw Mode Active",
            subtitle: "Text processing is off.",
            icon: "waveform.badge.exclamationmark"
        ) {
            Text("Switch to Clean mode when you want post-processing before paste/export.")
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
        let isHovered = hoveredCardTitle == title
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
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
                hoveredCardTitle = hovering ? title : nil
            }
        }
    }

    private func exampleRow(input: String, result: String, fires: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: fires ? "checkmark.circle.fill" : "xmark.circle")
                .font(.system(size: 12))
                .foregroundStyle(fires ? DesignSystem.Colors.successGreen : .secondary)
            Text("\"\(input)\"")
                .font(DesignSystem.Typography.caption.monospaced())
                .foregroundStyle(.primary)
            Text("→")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.tertiary)
            Text(result)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
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
        let isHovered = hoveredModeTitle == title
        return Button(action: action) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(isSelected ? DesignSystem.Colors.accent : .secondary)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.accent)
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
            .scaleEffect(isHovered ? 1.01 : 1.0)
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
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredModeTitle = hovering ? title : nil
            }
        }
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
                .parakeetAction(.secondary)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.md)
    }
}
