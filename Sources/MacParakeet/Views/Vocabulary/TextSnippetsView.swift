import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct TextSnippetsView: View {
    @Bindable var viewModel: TextSnippetsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Text Snippets")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search snippets...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Tip
            HStack {
                Image(systemName: "lightbulb.fill")
                    .foregroundStyle(DesignSystem.Colors.warningAmber)
                    .font(.caption)
                Text("Triggers are natural phrases (e.g. \"my signature\"), not abbreviations, because Parakeet outputs natural speech.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            // List
            if viewModel.filteredSnippets.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "text.insert")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(viewModel.snippets.isEmpty ? "No text snippets yet" : "No matches")
                        .foregroundStyle(.secondary)
                    if viewModel.snippets.isEmpty {
                        Text("Say a trigger phrase during dictation\nand it expands to the full text.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
            } else {
                List {
                    ForEach(viewModel.filteredSnippets) { snippet in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { snippet.isEnabled },
                                set: { _ in viewModel.toggleEnabled(snippet) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text("Say:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("\"\(snippet.trigger)\"")
                                        .opacity(snippet.isEnabled ? 1.0 : 0.5)
                                }
                                HStack(spacing: 4) {
                                    Text("Expands to:")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text(snippet.expansion)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }

                            Spacer()

                            if snippet.useCount > 0 {
                                Text("\(snippet.useCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(.secondary.opacity(0.1)))
                            }

                            Button(role: .destructive) {
                                viewModel.pendingDeleteSnippet = snippet
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            Divider()

            // Add form
            VStack(spacing: 8) {
                if let error = viewModel.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                }

                HStack {
                    TextField("Say: (trigger phrase)", text: $viewModel.newTrigger)
                        .textFieldStyle(.roundedBorder)
                    TextField("Expands to:", text: $viewModel.newExpansion)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        viewModel.addSnippet()
                    }
                    .disabled(
                        viewModel.newTrigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.newExpansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .padding()
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
}
