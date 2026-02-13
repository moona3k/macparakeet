import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct CustomWordsView: View {
    @Bindable var viewModel: CustomWordsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                headerCard
                searchCard
                wordsCard
                addWordCard
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
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

    // MARK: - Cards

    private var headerCard: some View {
        managementCard(
            title: "Custom Words",
            subtitle: "Vocabulary anchors and deterministic correction rules.",
            icon: "character.book.closed"
        ) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                metricChip(title: "Total", value: "\(viewModel.words.count)")
                metricChip(title: "Visible", value: "\(viewModel.filteredWords.count)")
                metricChip(title: "Enabled", value: "\(viewModel.words.filter(\.isEnabled).count)")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var searchCard: some View {
        managementCard(
            title: "Search",
            subtitle: "Filter by source word or replacement.",
            icon: "magnifyingglass"
        ) {
            TextField("Search words...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var wordsCard: some View {
        managementCard(
            title: "Word Rules",
            subtitle: "Toggle to enable or disable each rule.",
            icon: "list.bullet"
        ) {
            if viewModel.filteredWords.isEmpty {
                emptyWordsState
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(viewModel.filteredWords) { word in
                        wordRow(word)
                    }
                }
            }
        }
    }

    private var addWordCard: some View {
        managementCard(
            title: "Add Rule",
            subtitle: "Use replacement for correction, or leave blank to enforce exact casing.",
            icon: "plus.circle"
        ) {
            VStack(spacing: DesignSystem.Spacing.sm) {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: DesignSystem.Spacing.sm) {
                    TextField("Word or phrase", text: $viewModel.newWord)
                        .textFieldStyle(.roundedBorder)
                    TextField("Replacement (optional)", text: $viewModel.newReplacement)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        viewModel.addWord()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(viewModel.newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    // MARK: - Rows

    private func wordRow(_ word: CustomWord) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { word.isEnabled },
                set: { _ in viewModel.toggleEnabled(word) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                Text(word.word)
                    .font(DesignSystem.Typography.body)
                    .opacity(word.isEnabled ? 1.0 : 0.55)

                if let replacement = word.replacement {
                    Text("Replaces with: \(replacement)")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Vocabulary anchor")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(role: .destructive) {
                viewModel.pendingDeleteWord = word
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(DesignSystem.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }

    private var emptyWordsState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "character.textbox")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(viewModel.words.isEmpty ? "No custom words yet" : "No matches")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
            if viewModel.words.isEmpty {
                Text("Add vocabulary anchors to enforce casing, or corrections to fix common STT errors.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    // MARK: - Reusable

    private func managementCard<Content: View>(
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

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(DesignSystem.Typography.micro)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DesignSystem.Typography.body.weight(.semibold))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Layout.rowCornerRadius)
                .fill(DesignSystem.Colors.surfaceElevated)
        )
    }
}
