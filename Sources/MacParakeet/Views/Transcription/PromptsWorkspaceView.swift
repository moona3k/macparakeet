import SwiftUI
import MacParakeetViewModels

enum PromptsWorkspaceSection: String, CaseIterable, Identifiable {
    case transcriptPrompts = "Transcript prompts"
    case liveAsk = "Live Ask"

    static let defaultSection = Self.transcriptPrompts

    var id: Self { self }
}

/// The sidebar home for transcript output instructions and the questions used
/// while a meeting is in progress. Each section keeps its established manager
/// and repository-backed view model.
struct PromptsWorkspaceView: View {
    let promptsViewModel: PromptsViewModel
    let quickPromptsViewModel: QuickPromptsViewModel

    @State private var section = PromptsWorkspaceSection.defaultSection

    var body: some View {
        VStack(spacing: 0) {
            Picker("Prompt section", selection: $section) {
                ForEach(PromptsWorkspaceSection.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Prompt section")
            .frame(width: 340)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.xl)
            .background(DesignSystem.Colors.surface)

            Divider()

            switch section {
            case .transcriptPrompts:
                PromptLibraryView(
                    viewModel: promptsViewModel,
                    showsDismissButton: false
                )
            case .liveAsk:
                AskPromptsSheet(
                    viewModel: quickPromptsViewModel,
                    isEmbedded: true
                )
                .onAppear {
                    quickPromptsViewModel.refresh()
                }
                .onDisappear {
                    quickPromptsViewModel.cancelCreating()
                    quickPromptsViewModel.editingPrompt = nil
                    quickPromptsViewModel.refresh()
                }
            }
        }
    }
}
