import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

enum SidebarItem: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case dictations = "Dictations"
    case settings = "Settings"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcribe: return "waveform"
        case .dictations: return "clock.arrow.circlepath"
        case .settings: return "gearshape"
        }
    }
}

struct MainWindowView: View {
    @Bindable var state: MainWindowState

    let transcriptionViewModel: TranscriptionViewModel
    let historyViewModel: DictationHistoryViewModel
    let settingsViewModel: SettingsViewModel

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $state.selectedItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .frame(minWidth: DesignSystem.Layout.sidebarMinWidth)
        } detail: {
            switch state.selectedItem {
            case .transcribe:
                TranscribeView(viewModel: transcriptionViewModel)
            case .dictations:
                DictationHistoryView(viewModel: historyViewModel)
            case .settings:
                SettingsView(viewModel: settingsViewModel)
            }
        }
        .frame(
            minWidth: DesignSystem.Layout.sidebarMinWidth + DesignSystem.Layout.contentMinWidth,
            minHeight: DesignSystem.Layout.windowMinHeight
        )
    }
}
