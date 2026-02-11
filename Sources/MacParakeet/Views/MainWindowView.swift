import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

enum SidebarItem: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case dictations = "Dictations"
    case vocabulary = "Vocabulary"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcribe: return "waveform"
        case .dictations: return "clock.arrow.circlepath"
        case .vocabulary: return "book.fill"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindowView: View {
    @Bindable var state: MainWindowState

    let transcriptionViewModel: TranscriptionViewModel
    let historyViewModel: DictationHistoryViewModel
    let settingsViewModel: SettingsViewModel
    let customWordsViewModel: CustomWordsViewModel
    let textSnippetsViewModel: TextSnippetsViewModel

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $state.selectedItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 220)
        } detail: {
            Group {
                switch state.selectedItem {
                case .transcribe:
                    TranscribeView(viewModel: transcriptionViewModel)
                case .dictations:
                    DictationHistoryView(viewModel: historyViewModel)
                case .vocabulary:
                    VocabularyView(
                        settingsViewModel: settingsViewModel,
                        customWordsViewModel: customWordsViewModel,
                        textSnippetsViewModel: textSnippetsViewModel
                    )
                case .settings:
                    SettingsView(viewModel: settingsViewModel)
                }
            }
            .animation(DesignSystem.Animation.contentSwap, value: state.selectedItem)
        }
        .frame(
            minWidth: 800,
            minHeight: DesignSystem.Layout.windowMinHeight
        )
    }
}
