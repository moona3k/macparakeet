import SwiftUI
import MacParakeetViewModels

enum SidebarItem: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case dictations = "Dictations"
    case vocabulary = "Vocabulary"
    case feedback = "Feedback"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcribe: return "waveform"
        case .dictations: return "clock.arrow.circlepath"
        case .vocabulary: return "book.fill"
        case .feedback: return "bubble.left.and.text.bubble.right"
        case .settings: return "gearshape"
        }
    }

    /// Primary features — the core things users do
    static let primaryItems: [SidebarItem] = [.transcribe, .dictations]

    /// Configuration and support items
    static let configItems: [SidebarItem] = [.vocabulary, .feedback, .settings]
}

struct MainWindowView: View {
    @Bindable var state: MainWindowState

    let transcriptionViewModel: TranscriptionViewModel
    let historyViewModel: DictationHistoryViewModel
    let settingsViewModel: SettingsViewModel
    let llmSettingsViewModel: LLMSettingsViewModel
    let chatViewModel: TranscriptChatViewModel
    let customWordsViewModel: CustomWordsViewModel
    let textSnippetsViewModel: TextSnippetsViewModel
    let feedbackViewModel: FeedbackViewModel

    var body: some View {
        NavigationSplitView {
            List(selection: $state.selectedItem) {
                Section {
                    ForEach(SidebarItem.primaryItems) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .tag(item)
                    }
                }

                Section {
                    ForEach(SidebarItem.configItems) { item in
                        Label(item.rawValue, systemImage: item.icon)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .tint(DesignSystem.Colors.accent)
            .navigationSplitViewColumnWidth(min: 170, ideal: DesignSystem.Layout.sidebarMinWidth, max: 240)
        } detail: {
            Group {
                switch state.selectedItem {
                case .transcribe:
                    TranscribeView(viewModel: transcriptionViewModel, chatViewModel: chatViewModel)
                case .dictations:
                    DictationHistoryView(viewModel: historyViewModel)
                case .vocabulary:
                    VocabularyView(
                        settingsViewModel: settingsViewModel,
                        customWordsViewModel: customWordsViewModel,
                        textSnippetsViewModel: textSnippetsViewModel
                    )
                case .feedback:
                    FeedbackView(viewModel: feedbackViewModel)
                case .settings:
                    SettingsView(viewModel: settingsViewModel, llmSettingsViewModel: llmSettingsViewModel)
                }
            }
            .animation(DesignSystem.Animation.contentSwap, value: state.selectedItem)
        }
        .frame(
            minWidth: 860,
            minHeight: DesignSystem.Layout.windowMinHeight
        )
    }
}
