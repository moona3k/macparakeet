import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

struct CustomWordsView: View {
    @Bindable var viewModel: CustomWordsViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Custom Words")
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
                TextField("Search words...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // List
            if viewModel.filteredWords.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "character.textbox")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(viewModel.words.isEmpty ? "No custom words yet" : "No matches")
                        .foregroundStyle(.secondary)
                    if viewModel.words.isEmpty {
                        Text("Add vocabulary anchors to enforce correct casing,\nor corrections to fix common STT errors.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                }
                Spacer()
            } else {
                List {
                    ForEach(viewModel.filteredWords) { word in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { word.isEnabled },
                                set: { _ in viewModel.toggleEnabled(word) }
                            ))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(word.word)
                                    .opacity(word.isEnabled ? 1.0 : 0.5)
                                if let replacement = word.replacement {
                                    Text("-> \(replacement)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                } else {
                                    Text("(vocabulary anchor)")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }

                            Spacer()

                            Button(role: .destructive) {
                                viewModel.pendingDeleteWord = word
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
                    TextField("Word or phrase", text: $viewModel.newWord)
                        .textFieldStyle(.roundedBorder)
                    TextField("Replacement (optional)", text: $viewModel.newReplacement)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        viewModel.addWord()
                    }
                    .disabled(viewModel.newWord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding()
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
}
