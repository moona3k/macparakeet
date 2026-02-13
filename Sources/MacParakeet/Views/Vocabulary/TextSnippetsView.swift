import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct TextSnippetsView: View {
    @Bindable var viewModel: TextSnippetsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                headerCard
                guidanceCard
                searchCard
                snippetsCard
                addSnippetCard
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background(DesignSystem.Colors.background)
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

    // MARK: - Cards

    private var headerCard: some View {
        managementCard(
            title: "Text Snippets",
            subtitle: "Phrase-triggered deterministic expansion rules.",
            icon: "text.insert"
        ) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                metricChip(title: "Total", value: "\(viewModel.snippets.count)")
                metricChip(title: "Visible", value: "\(viewModel.filteredSnippets.count)")
                metricChip(title: "Enabled", value: "\(viewModel.snippets.filter(\.isEnabled).count)")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var guidanceCard: some View {
        managementCard(
            title: "Guidance",
            subtitle: "Best practice for robust trigger detection.",
            icon: "lightbulb.fill"
        ) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                Text("Use natural trigger phrases (for example, \"my signature\") rather than abbreviations, since Parakeet recognizes natural speech.")
                    .font(DesignSystem.Typography.bodySmall)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var searchCard: some View {
        managementCard(
            title: "Search",
            subtitle: "Filter by trigger phrase or expansion text.",
            icon: "magnifyingglass"
        ) {
            TextField("Search snippets...", text: $viewModel.searchText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var snippetsCard: some View {
        managementCard(
            title: "Snippet Rules",
            subtitle: "Toggle each snippet and track usage volume.",
            icon: "list.bullet"
        ) {
            if viewModel.filteredSnippets.isEmpty {
                emptyState
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(viewModel.filteredSnippets) { snippet in
                        snippetRow(snippet)
                    }
                }
            }
        }
    }

    private var addSnippetCard: some View {
        managementCard(
            title: "Add Snippet",
            subtitle: "Define a trigger phrase and expansion output.",
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
                    TextField("Trigger phrase", text: $viewModel.newTrigger)
                        .textFieldStyle(.roundedBorder)
                    TextField("Expansion", text: $viewModel.newExpansion)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        viewModel.addSnippet()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignSystem.Colors.accent)
                    .disabled(
                        viewModel.newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.newExpansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }

    // MARK: - Rows

    private func snippetRow(_ snippet: TextSnippet) -> some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Toggle("", isOn: Binding(
                get: { snippet.isEnabled },
                set: { _ in viewModel.toggleEnabled(snippet) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text("Trigger:")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                    Text("\"\(snippet.trigger)\"")
                        .font(DesignSystem.Typography.body)
                        .opacity(snippet.isEnabled ? 1.0 : 0.55)
                }

                Text("Expands to: \(snippet.expansion)")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if snippet.useCount > 0 {
                Text("\(snippet.useCount)")
                    .font(DesignSystem.Typography.micro)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
            }

            Button(role: .destructive) {
                viewModel.pendingDeleteSnippet = snippet
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

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "text.insert")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(viewModel.snippets.isEmpty ? "No text snippets yet" : "No matches")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(.secondary)
            if viewModel.snippets.isEmpty {
                Text("Say a trigger phrase during dictation and it expands to full text.")
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
