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
        Form {
            Section("Processing Mode") {
                Picker("Mode", selection: $settingsViewModel.processingMode) {
                    Text("Raw (no processing)").tag("raw")
                    Text("Clean (fillers removed)").tag("clean")
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                Text("Raw outputs STT text as-is. Clean removes filler words, applies custom word corrections, and expands text snippets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settingsViewModel.processingMode == "clean" {
                Section("How It Works") {
                    VStack(alignment: .leading, spacing: 6) {
                        pipelineStep(number: 1, title: "Filler Removal", detail: "Strips um, uh, like, you know")
                        pipelineStep(number: 2, title: "Custom Words", detail: "Fixes domain terms STT gets wrong")
                        pipelineStep(number: 3, title: "Text Snippets", detail: "Expands trigger phrases to full text")
                        pipelineStep(number: 4, title: "Whitespace Cleanup", detail: "Normalizes spacing and punctuation")
                    }
                }

                Section("Tips") {
                    VStack(alignment: .leading, spacing: 8) {
                        tip("Parakeet already handles punctuation and capitalization \u{2014} the pipeline focuses on what STT can\u{2019}t do.")
                        tip("Custom words fix domain terms STT gets wrong (e.g. \u{201c}kubernetes\u{201d} \u{2192} \u{201c}Kubernetes\u{201d}).")
                        tip("Leave replacement empty to enforce casing without changing the word.")
                        tip("Snippet triggers should be natural phrases you\u{2019}d say, not abbreviations.")
                        tip("Changes take effect on the next dictation.")
                    }
                }

                Section("Custom Words") {
                    HStack {
                        Text("Words defined")
                        Spacer()
                        Text("\(settingsViewModel.customWordCount)")
                            .foregroundStyle(.secondary)
                        Button("Manage...") {
                            customWordsViewModel.loadWords()
                            showCustomWords = true
                        }
                    }
                }

                Section("Text Snippets") {
                    HStack {
                        Text("Snippets defined")
                        Spacer()
                        Text("\(settingsViewModel.snippetCount)")
                            .foregroundStyle(.secondary)
                        Button("Manage...") {
                            textSnippetsViewModel.loadSnippets()
                            showTextSnippets = true
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showCustomWords) {
            settingsViewModel.refreshStats()
        } content: {
            CustomWordsView(viewModel: customWordsViewModel)
                .frame(minWidth: 500, minHeight: 400)
        }
        .sheet(isPresented: $showTextSnippets) {
            settingsViewModel.refreshStats()
        } content: {
            TextSnippetsView(viewModel: textSnippetsViewModel)
                .frame(minWidth: 500, minHeight: 400)
        }
        .onAppear {
            settingsViewModel.refreshStats()
        }
    }

    @ViewBuilder
    private func pipelineStep(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func tip(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lightbulb.fill")
                .font(.caption2)
                .foregroundStyle(.yellow)
                .padding(.top, 1)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
