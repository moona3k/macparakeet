import Sparkle
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
    let updater: SPUUpdater

    var body: some View {
        VStack(spacing: 0) {
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
                        TranscribeView(viewModel: transcriptionViewModel, chatViewModel: chatViewModel, showingProgressDetail: $state.showingProgressDetail)
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
                        SettingsView(viewModel: settingsViewModel, llmSettingsViewModel: llmSettingsViewModel, updater: updater)
                    }
                }
                .animation(DesignSystem.Animation.contentSwap, value: state.selectedItem)
            }

            if showGlobalProgressBar {
                globalTranscriptionBottomBar
            }
        }
        .frame(
            minWidth: 860,
            minHeight: DesignSystem.Layout.windowMinHeight
        )
        .onChange(of: transcriptionViewModel.isTranscribing) { _, isTranscribing in
            if !isTranscribing {
                state.showingProgressDetail = false
            }
        }
    }

    /// Show the global bottom bar when transcribing, except when on Transcribe tab with detail expanded
    private var showGlobalProgressBar: Bool {
        transcriptionViewModel.isTranscribing
            && transcriptionViewModel.currentTranscription == nil
            && !(state.selectedItem == .transcribe && state.showingProgressDetail)
    }

    private var globalTranscriptionBottomBar: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            SpinnerRingView(size: 18, revolutionDuration: 2.0, tintColor: DesignSystem.Colors.accent)

            Text(transcriptionViewModel.transcribingFileName)
                .font(DesignSystem.Typography.caption)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("\u{00B7}")
                .foregroundStyle(.tertiary)

            Text(transcriptionViewModel.progressHeadline)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let fraction = transcriptionViewModel.transcriptionProgress {
                Text("\(Int((fraction * 100).rounded()))%")
                    .font(DesignSystem.Typography.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                state.selectedItem = .transcribe
                state.showingProgressDetail = true
            } label: {
                Text("View")
                    .font(DesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(DesignSystem.Colors.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                            .fill(DesignSystem.Colors.accent.opacity(0.1))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.cardBackground)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}
