import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct CustomWordsView: View {
    @Bindable var viewModel: CustomWordsViewModel
    var recognitionStatus: CustomVocabularyBoostingSupportPresentation
    @Environment(\.dismiss) private var dismiss
    @State private var hoveredWordID: UUID?
    @FocusState private var searchFieldFocused: Bool
    @FocusState private var selectionFocused: Bool
    @FocusState private var wordFieldFocused: Bool
    @FocusState private var replacementFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetAutoFocusSuppressor()
                .frame(width: 0, height: 0)

            VocabSheetHeader(
                title: "Custom Words",
                subtitle: recognitionStatus.detail,
                onDone: { dismiss() },
                usesDismissShortcut: !viewModel.isSelecting
            )

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ParakeetTextField(
                        placeholder: "Search words…",
                        text: $viewModel.searchText,
                        leadingSystemImage: "magnifyingglass",
                        showsClearButton: true,
                        externalFocus: $searchFieldFocused
                    )
                    .padding(.bottom, DesignSystem.Spacing.lg)

                    wordsSection
                    if !viewModel.isSelecting {
                        addSection
                            .padding(.top, DesignSystem.Spacing.lg)
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .focusable(viewModel.isSelecting)
            .focused($selectionFocused)
            .focusEffectDisabled(viewModel.isSelecting)
            .onKeyPress(keys: ["a", "A"]) { press in
                guard viewModel.isSelecting, !viewModel.isDeleting,
                    !searchFieldFocused, !wordFieldFocused, !replacementFieldFocused,
                    press.modifiers == .command
                else { return .ignored }
                if !viewModel.areAllFilteredWordsSelected {
                    viewModel.toggleSelectAll()
                }
                return .handled
            }
        }
        .background(DesignSystem.Colors.background)
        .disabled(viewModel.isDeleting)
        .interactiveDismissDisabled(viewModel.isDeleting)
        .onChange(of: viewModel.isSelecting) { _, isSelecting in
            if isSelecting {
                searchFieldFocused = false
                wordFieldFocused = false
                replacementFieldFocused = false
                selectionFocused = true
            }
        }
        .onDisappear {
            viewModel.cancelSelection()
        }
        .alert(
            deletionTitle,
            isPresented: Binding(
                get: { viewModel.pendingDeletion != nil },
                set: { if !$0 { viewModel.cancelDeletion() } }
            ),
            presenting: viewModel.pendingDeletion
        ) { request in
            Button("Cancel", role: .cancel) {
                viewModel.cancelDeletion()
            }
            .keyboardShortcut(.defaultAction)
            Button("Delete", role: .destructive) {
                Task { await viewModel.confirmDelete(request) }
            }
            .parakeetAction(.destructive)
        } message: { request in
            if request.isBulk {
                Text("The selected word rules will be permanently deleted. This cannot be undone.")
            } else if let word = request.words.first {
                Text("Delete \"\(word.word)\"? This cannot be undone.")
            }
        }
    }

    // MARK: - Sections

    private var wordsSection: some View {
        Section {
            if viewModel.filteredWords.isEmpty {
                emptyWordsState
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.xl)
                    .vocabGroup()
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.filteredWords.enumerated()), id: \.element.id) { index, word in
                        if index > 0 {
                            Divider().padding(.leading, VocabMetrics.rowDividerInset)
                        }
                        wordRow(word)
                    }
                }
                .vocabGroup()
            }
        } header: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                if let error = viewModel.deletionErrorMessage {
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                wordsHeader
            }
            .padding(.top, DesignSystem.Spacing.xs)
            .padding(.bottom, DesignSystem.Spacing.sm)
            .background(DesignSystem.Colors.background)
        }
    }

    @ViewBuilder
    private var wordsHeader: some View {
        if viewModel.isSelecting {
            HStack(spacing: DesignSystem.Spacing.sm) {
                SelectAllWordsCheckbox(
                    title: viewModel.searchText.isEmpty ? "Select all" : "Select all matching",
                    state: selectAllState,
                    isEnabled: !viewModel.filteredWords.isEmpty && !viewModel.isDeleting,
                    action: viewModel.toggleSelectAll
                )
                .fixedSize()
                .padding(.leading, DesignSystem.Spacing.md)

                Spacer(minLength: DesignSystem.Spacing.sm)

                Text("\(viewModel.selectedWordIDs.count) selected")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if viewModel.isDeleting {
                    deletionProgress
                }

                Button("Delete…", role: .destructive) {
                    viewModel.requestDeleteSelection()
                }
                .parakeetAction(.destructive)
                .controlSize(.small)
                .disabled(viewModel.selectedWordIDs.isEmpty)
                .accessibilityLabel("Delete selected words")

                Button("Cancel") {
                    viewModel.cancelSelection()
                }
                .parakeetAction(.subtle)
                .controlSize(.small)
                .keyboardShortcut(.cancelAction)
            }
            .frame(minHeight: 28)
        } else {
            VocabSectionHeader(title: "Word Rules") {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Text(wordsCountLabel)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    if viewModel.isDeleting {
                        deletionProgress
                    }

                    Button("Select…") {
                        viewModel.startSelection()
                    }
                    .parakeetAction(.subtle)
                    .controlSize(.small)
                    .disabled(viewModel.filteredWords.isEmpty)
                    .accessibilityLabel("Select words to delete")
                }
            }
            .frame(minHeight: 28)
        }
    }

    private var deletionProgress: some View {
        ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Deleting words")
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
        let isSelected = viewModel.selectedWordIDs.contains(word.id)
        let trimmedReplacement = word.replacement?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let toggleHint: String =
            trimmedReplacement.isEmpty
            ? "Enforces exact spelling"
            : "Replaces with \(trimmedReplacement)"
        return Group {
            if viewModel.isSelecting {
                Toggle(
                    isOn: Binding(
                        get: { viewModel.selectedWordIDs.contains(word.id) },
                        set: { _ in viewModel.toggleSelection(for: word.id) }
                    )
                ) {
                    wordCopy(word, replacement: trimmedReplacement)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .toggleStyle(.checkbox)
                .tint(DesignSystem.Colors.accent)
                .accessibilityLabel("Select \(word.word)")
                .accessibilityHint(toggleHint)
            } else {
                HStack(spacing: DesignSystem.Spacing.md) {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { word.isEnabled },
                            set: { _ in viewModel.toggleEnabled(word) }
                        )
                    )
                    .labelsHidden()
                    .parakeetSwitch()
                    .controlSize(.small)
                    .accessibilityLabel("Enable \(word.word)")
                    .accessibilityHint(toggleHint)

                    wordCopy(word, replacement: trimmedReplacement)

                    Spacer(minLength: DesignSystem.Spacing.sm)

                    DeleteIconButton(
                        helpText: "Delete \(word.word)",
                        accessibilityName: "Delete \(word.word)"
                    ) {
                        viewModel.requestDelete(word)
                    }
                }
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .background(
            isSelected
                ? DesignSystem.Colors.accentLight
                : isHovered ? DesignSystem.Colors.rowHoverBackground : Color.clear
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredWordID = hovering ? word.id : nil
            }
        }
    }

    private func wordCopy(_ word: CustomWord, replacement: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(word.word)
                .font(DesignSystem.Typography.body)
                .opacity(word.isEnabled ? 1.0 : 0.55)

            if !replacement.isEmpty {
                Text("Replaces with: \(replacement)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("Enforces exact spelling")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
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
            if viewModel.words.isEmpty && !viewModel.isSelecting {
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

    private var deletionTitle: String {
        guard let request = viewModel.pendingDeletion, request.isBulk else { return "Delete Word?" }
        return request.count == 1 ? "Delete 1 Word?" : "Delete \(request.count) Words?"
    }

    private var selectAllState: NSControl.StateValue {
        if viewModel.areAllFilteredWordsSelected { return .on }
        return viewModel.selectedWordIDs.isEmpty ? .off : .mixed
    }

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

/// The list header needs a native mixed checkbox with one bulk action, rather
/// than writing through a separate binding for every matching rule.
private struct SelectAllWordsCheckbox: NSViewRepresentable {
    let title: String
    let state: NSControl.StateValue
    let isEnabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(
            checkboxWithTitle: title,
            target: context.coordinator,
            action: #selector(Coordinator.toggle)
        )
        button.allowsMixedState = true
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.contentTintColor = NSColor(DesignSystem.Colors.accent)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = title
        button.state = state
        button.isEnabled = isEnabled
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    @MainActor
    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) {
            self.action = action
        }

        @objc func toggle() { action() }
    }
}
