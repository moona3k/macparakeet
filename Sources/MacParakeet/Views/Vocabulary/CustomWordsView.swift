import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct CustomWordsView: View {
    @Bindable var viewModel: CustomWordsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var hoveredWordID: UUID?
    @FocusState private var wordFieldFocused: Bool
    @FocusState private var replacementFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetAutoFocusSuppressor()
                .frame(width: 0, height: 0)

            VocabSheetHeader(
                title: "Custom Words",
                subtitle: "Teach MacParakeet how you say things.",
                onDone: { dismiss() }
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ParakeetTextField(
                        placeholder: "Search words…",
                        text: $viewModel.searchText,
                        leadingSystemImage: "magnifyingglass",
                        showsClearButton: true
                    )

                    wordsSection
                    addSection
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .alert(
            "Delete Word?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteWord != nil },
                set: { if !$0 { viewModel.pendingDeleteWord = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteWord = nil
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
        } message: {
            if let word = viewModel.pendingDeleteWord {
                Text("Delete \"\(word.word)\"? This cannot be undone.")
            }
        }
    }

    // MARK: - Sections

    private var wordsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VocabSectionHeader(title: "Word Rules") {
                Text(wordsCountLabel)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if viewModel.filteredWords.isEmpty {
                emptyWordsState
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.xl)
                    .vocabGroup()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.filteredWords.enumerated()), id: \.element.id) { index, word in
                        if index > 0 {
                            Divider().padding(.leading, VocabMetrics.rowDividerInset)
                        }
                        wordRow(word)
                    }
                }
                .vocabGroup()
            }
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VocabSectionHeader(
                title: "Add Rule",
                subtitle: "Replace a word, or leave the replacement blank to lock its spelling and capitalization."
            )

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                ParakeetTextField(
                    placeholder: "Word or phrase",
                    text: $viewModel.newWord,
                    onSubmit: { replacementFieldFocused = true },
                    externalFocus: $wordFieldFocused
                )
                ParakeetTextField(
                    placeholder: "Replacement (optional)",
                    text: $viewModel.newReplacement,
                    onSubmit: attemptAdd,
                    externalFocus: $replacementFieldFocused
                )
                Button("Add", action: attemptAdd)
                    .parakeetAction(.primaryProminent)
                    .controlSize(.large)
                    .disabled(viewModel.newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !viewModel.newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                rulePreview
                    .transition(.opacity)
            }
        }
        .animation(DesignSystem.Animation.hoverTransition, value: viewModel.newWord.isEmpty)
    }

    @ViewBuilder
    private var rulePreview: some View {
        let word = viewModel.newWord.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = viewModel.newReplacement.trimmingCharacters(in: .whitespacesAndNewlines)
        HStack(spacing: DesignSystem.Spacing.xs) {
            if replacement.isEmpty {
                Text("“\(word)”")
                    .font(DesignSystem.Typography.caption.monospaced())
                    .foregroundStyle(.primary)
                Text("kept exactly — fixes spelling & capitalization")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("“\(word)”")
                    .font(DesignSystem.Typography.caption.monospaced())
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Text("“\(replacement)”")
                    .font(DesignSystem.Typography.caption.monospaced())
                    .foregroundStyle(.primary)
            }
        }
        .padding(.leading, 2)
    }

    // MARK: - Rows

    private func wordRow(_ word: CustomWord) -> some View {
        let isHovered = hoveredWordID == word.id
        let toggleHint: String = word.replacement.map { "Replaces with \($0)" } ?? "Enforces exact spelling"
        return HStack(spacing: DesignSystem.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { word.isEnabled },
                set: { _ in viewModel.toggleEnabled(word) }
            ))
            .labelsHidden()
            .parakeetSwitch()
            .controlSize(.small)
            .accessibilityLabel("Enable \(word.word)")
            .accessibilityHint(toggleHint)

            VStack(alignment: .leading, spacing: 3) {
                Text(word.word)
                    .font(DesignSystem.Typography.body)
                    .opacity(word.isEnabled ? 1.0 : 0.55)

                if let replacement = word.replacement {
                    Text("Replaces with: \(replacement)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Enforces exact spelling")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            DeleteIconButton(
                helpText: "Delete \(word.word)",
                accessibilityName: "Delete \(word.word)"
            ) {
                viewModel.pendingDeleteWord = word
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .background(isHovered ? DesignSystem.Colors.rowHoverBackground : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredWordID = hovering ? word.id : nil
            }
        }
    }

    private var emptyWordsState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "character.textbox")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(viewModel.words.isEmpty ? "No custom words yet" : "No matches")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
            if viewModel.words.isEmpty {
                Text("Add words to fix spelling or capitalization that the speech engine gets wrong.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Add Your First Rule") {
                    wordFieldFocused = true
                }
                .parakeetAction(.primary)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Helpers

    private var wordsCountLabel: String {
        let total = viewModel.words.count
        let searching = !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        if searching {
            return "\(viewModel.filteredWords.count) of \(total)"
        }
        let disabled = viewModel.words.filter { !$0.isEnabled }.count
        if disabled > 0 {
            return "\(total) · \(disabled) off"
        }
        return total == 1 ? "1 rule" : "\(total) rules"
    }

    private func attemptAdd() {
        guard !viewModel.newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        viewModel.addWord()
    }
}
