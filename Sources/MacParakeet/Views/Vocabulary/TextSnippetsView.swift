import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct TextSnippetsView: View {
    @Bindable var viewModel: TextSnippetsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var hoveredSnippetID: UUID?
    @State private var showTips = false
    @FocusState private var triggerFieldFocused: Bool
    @FocusState private var expansionFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SheetAutoFocusSuppressor()
                .frame(width: 0, height: 0)

            VocabSheetHeader(
                title: "Text Snippets",
                subtitle: "Say a short phrase, paste a longer one.",
                onDone: { dismiss() }
            )

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    ParakeetTextField(
                        placeholder: "Search snippets…",
                        text: $viewModel.searchText,
                        leadingSystemImage: "magnifyingglass",
                        showsClearButton: true
                    )

                    snippetsSection
                    addSection
                    tipsDisclosure
                }
                .padding(DesignSystem.Spacing.lg)
            }
        }
        .alert(
            "Delete Snippet?",
            isPresented: Binding(
                get: { viewModel.pendingDeleteSnippet != nil },
                set: { if !$0 { viewModel.pendingDeleteSnippet = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                viewModel.pendingDeleteSnippet = nil
            }
            Button("Delete", role: .destructive) {
                viewModel.confirmDelete()
            }
        } message: {
            if let snippet = viewModel.pendingDeleteSnippet {
                Text("Delete \"\(snippet.trigger)\"? This cannot be undone.")
            }
        }
    }

    // MARK: - Sections

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VocabSectionHeader(title: "Snippet Rules") {
                Text(snippetsCountLabel)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }

            if viewModel.filteredSnippets.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.Spacing.xl)
                    .vocabGroup()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.filteredSnippets.enumerated()), id: \.element.id) { index, snippet in
                        if index > 0 {
                            Divider().padding(.leading, VocabMetrics.rowDividerInset)
                        }
                        snippetRow(snippet)
                    }
                }
                .vocabGroup()
            }
        }
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            VocabSectionHeader(
                title: "Add Snippet",
                subtitle: "Define a trigger phrase and what it expands to."
            )

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.errorRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                ParakeetTextField(
                    placeholder: "Trigger phrase",
                    text: $viewModel.newTrigger,
                    onSubmit: { expansionFieldFocused = true },
                    externalFocus: $triggerFieldFocused
                )
                ParakeetTextField(
                    placeholder: "Expansion",
                    text: $viewModel.newExpansion,
                    onSubmit: attemptAdd,
                    externalFocus: $expansionFieldFocused
                )
                Button("Add", action: attemptAdd)
                    .parakeetAction(.primaryProminent)
                    .controlSize(.large)
                    .disabled(
                        viewModel.newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.newExpansion.trimmingCharacters(in: .whitespaces).isEmpty
                    )
            }
        }
    }

    private var tipsDisclosure: some View {
        DisclosureGroup(isExpanded: $showTips) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                tipRow(
                    icon: "waveform",
                    title: "Speak naturally",
                    detail: "Use real phrases like \"my signature\" — not abbreviations."
                )
                tipRow(
                    icon: "return",
                    title: "Add line breaks",
                    detail: "Put `\\n` in an expansion. `\\n\\n` makes a blank line."
                )
            }
            .padding(.top, DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text("Tips for reliable detection")
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Rows

    private func snippetRow(_ snippet: TextSnippet) -> some View {
        let isHovered = hoveredSnippetID == snippet.id
        let usageHint: String = snippet.useCount > 0
            ? "Used \(snippet.useCount) time\(snippet.useCount == 1 ? "" : "s")"
            : "Not yet used"
        return HStack(spacing: DesignSystem.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { snippet.isEnabled },
                set: { _ in viewModel.toggleEnabled(snippet) }
            ))
            .labelsHidden()
            .parakeetSwitch()
            .controlSize(.small)
            .accessibilityLabel("Enable \(snippet.trigger)")
            .accessibilityHint("Expands during dictation to a saved phrase")

            VStack(alignment: .leading, spacing: 3) {
                Text("\"\(snippet.trigger)\"")
                    .font(DesignSystem.Typography.body)
                    .opacity(snippet.isEnabled ? 1.0 : 0.55)

                Text("Expands to: \(snippet.expansion.replacingOccurrences(of: "\n", with: " ↵ "))")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: DesignSystem.Spacing.sm)

            if snippet.useCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(snippet.useCount)")
                        .font(DesignSystem.Typography.micro.weight(.medium))
                        .monospacedDigit()
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                .help(usageHint)
                .accessibilityLabel(usageHint)
            }

            DeleteIconButton(
                helpText: "Delete \(snippet.trigger)",
                accessibilityName: "Delete \(snippet.trigger)"
            ) {
                viewModel.pendingDeleteSnippet = snippet
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .background(isHovered ? DesignSystem.Colors.rowHoverBackground : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(DesignSystem.Animation.hoverTransition) {
                hoveredSnippetID = hovering ? snippet.id : nil
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "text.insert")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(viewModel.snippets.isEmpty ? "No text snippets yet" : "No matches")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
            if viewModel.snippets.isEmpty {
                Text("Say a trigger phrase during dictation and it expands to full text.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                Button("Add Your First Snippet") {
                    triggerFieldFocused = true
                }
                .parakeetAction(.primary)
                .controlSize(.small)
                .padding(.top, 2)
            }
        }
    }

    private func tipRow(icon: String, title: String, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Helpers

    private var snippetsCountLabel: String {
        let total = viewModel.snippets.count
        let searching = !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        if searching {
            return "\(viewModel.filteredSnippets.count) of \(total)"
        }
        let disabled = viewModel.snippets.filter { !$0.isEnabled }.count
        if disabled > 0 {
            return "\(total) · \(disabled) off"
        }
        return total == 1 ? "1 snippet" : "\(total) snippets"
    }

    private func attemptAdd() {
        let triggerEmpty = viewModel.newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let expansionEmpty = viewModel.newExpansion.trimmingCharacters(in: .whitespaces).isEmpty
        guard !triggerEmpty && !expansionEmpty else { return }
        viewModel.addSnippet()
    }
}
