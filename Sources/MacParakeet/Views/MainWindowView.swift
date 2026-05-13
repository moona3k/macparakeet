import Sparkle
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

enum SidebarItem: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case library = "Library"
    case dictations = "Dictations"
    case transforms = "Transforms"
    case vocabulary = "Vocabulary"
    case feedback = "Feedback"
    case settings = "Settings"
    case discover = "Discover"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcribe: return "waveform"
        case .library: return "square.grid.2x2"
        case .dictations: return "clock.arrow.circlepath"
        case .transforms: return "wand.and.stars"
        case .vocabulary: return "book.fill"
        case .feedback: return "bubble.left.and.text.bubble.right"
        case .settings: return "gearshape"
        case .discover: return "sparkles"
        }
    }

    /// Primary features — the core things users do. Meeting recording is
    /// reachable from the Transcribe tab's third tile (when feature flag is
    /// on); meeting browse lives in `Library` under the `Meetings` filter.
    static let primaryItems: [SidebarItem] = [.transcribe, .library, .dictations]

    /// Configuration and support items. Transforms (ADR-022) is inserted
    /// here at runtime when `AppFeatures.transformsEnabled == true`.
    static var configItems: [SidebarItem] {
        var items: [SidebarItem] = [.vocabulary, .feedback, .settings]
        if AppFeatures.transformsEnabled {
            items.insert(.transforms, at: 0)
        }
        return items
    }

    /// Note: `.discover` is intentionally excluded from the arrays above.
    /// It renders as a pinned card below the sidebar list via `safeAreaInset`.
}

struct MainWindowView: View {
    @Bindable var state: MainWindowState

    let transcriptionViewModel: TranscriptionViewModel
    let historyViewModel: DictationHistoryViewModel
    let settingsViewModel: SettingsViewModel
    let llmSettingsViewModel: LLMSettingsViewModel
    let chatViewModel: TranscriptChatViewModel
    let promptResultsViewModel: PromptResultsViewModel
    let promptsViewModel: PromptsViewModel
    let transformsViewModel: TransformsViewModel
    let customWordsViewModel: CustomWordsViewModel
    let textSnippetsViewModel: TextSnippetsViewModel
    let vocabularyBackupViewModel: VocabularyBackupViewModel
    let feedbackViewModel: FeedbackViewModel
    let discoverViewModel: DiscoverViewModel
    let libraryViewModel: TranscriptionLibraryViewModel
    let meetingPillViewModel: MeetingRecordingPillViewModel
    let updater: SPUUpdater
    let onRecordMeeting: () -> Void
    let onPauseToggleMeeting: (() -> Void)?
    /// Routed to `AppHotkeyCoordinator.suspend` / `resume` while a hotkey
    /// recorder is active. Passed through to `SettingsView`.
    let onHotkeyRecordingStateChanged: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $state.selectedItem) {
                    Section {
                        ForEach(SidebarItem.primaryItems) { item in
                            SidebarItemLabel(item: item)
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
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    DiscoverSidebarCard(
                        viewModel: discoverViewModel,
                        isSelected: state.selectedItem == .discover,
                        onTap: { state.selectedItem = .discover }
                    )
                }
                .navigationSplitViewColumnWidth(min: 170, ideal: DesignSystem.Layout.sidebarMinWidth, max: 240)
            } detail: {
                Group {
                    switch state.selectedItem {
                    case .transcribe:
                        TranscribeView(
                            viewModel: transcriptionViewModel,
                            chatViewModel: chatViewModel,
                            promptResultsViewModel: promptResultsViewModel,
                            promptsViewModel: promptsViewModel,
                            meetingPillViewModel: meetingPillViewModel,
                            meetingPermissionState: meetingPermissionState,
                            showingProgressDetail: $state.showingProgressDetail,
                            onRecordMeeting: onRecordMeeting,
                            onPauseToggleMeeting: onPauseToggleMeeting,
                            onRefreshPermissions: settingsViewModel.refreshPermissions
                        )
                    case .library:
                        if let transcription = transcriptionViewModel.currentTranscription {
                            TranscriptResultView(
                                transcription: transcription,
                                viewModel: transcriptionViewModel,
                                chatViewModel: chatViewModel,
                                promptResultsViewModel: promptResultsViewModel,
                                promptsViewModel: promptsViewModel,
                                onBack: {
                                    transcriptionViewModel.showInputPortal()
                                },
                                onStartNew: {
                                    transcriptionViewModel.showInputPortal()
                                    state.selectedItem = .transcribe
                                },
                                onRetranscribe: { original, speechEngineOverride in
                                    transcriptionViewModel.retranscribe(original, speechEngineOverride: speechEngineOverride)
                                }
                            )
                        } else {
                            TranscriptionLibraryView(
                                viewModel: libraryViewModel,
                                primaryActionTitle: "New Transcription",
                                onPrimaryAction: {
                                    transcriptionViewModel.showInputPortal()
                                    state.selectedItem = .transcribe
                                }
                            ) { transcription in
                                transcriptionViewModel.currentTranscription = transcription
                            }
                        }
                    case .dictations:
                        DictationHistoryView(viewModel: historyViewModel)
                    case .transforms:
                        TransformsView(
                            viewModel: transformsViewModel,
                            llmConfiguredAction: { state.selectedItem = .settings },
                            reservedHotkeys: transformReservedHotkeys,
                            onShortcutRecordingStateChanged: onHotkeyRecordingStateChanged,
                            onBindingsChanged: {
                                NotificationCenter.default.post(name: .transformsBindingsChanged, object: nil)
                            }
                        )
                    case .vocabulary:
                        VocabularyView(
                            settingsViewModel: settingsViewModel,
                            customWordsViewModel: customWordsViewModel,
                            textSnippetsViewModel: textSnippetsViewModel,
                            backupViewModel: vocabularyBackupViewModel
                        )
                    case .feedback:
                        FeedbackView(viewModel: feedbackViewModel)
                    case .settings:
                        SettingsView(
                            viewModel: settingsViewModel,
                            llmSettingsViewModel: llmSettingsViewModel,
                            updater: updater,
                            onHotkeyRecordingStateChanged: onHotkeyRecordingStateChanged
                        )
                    case .discover:
                        DiscoverView(viewModel: discoverViewModel, thoughtsService: DiscoverThoughtsService())
                    }
                }
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
        .onChange(of: transcriptionViewModel.currentTranscription?.id) { _, newID in
            if newID != nil {
                state.selectedItem = .library
            }
        }
    }

    /// Show the global bottom bar when transcribing on any tab except Transcribe (which has its own detailed view)
    private var showGlobalProgressBar: Bool {
        transcriptionViewModel.isTranscribing
            && state.selectedItem != .transcribe
    }

    private var meetingPermissionState: MeetingRecordingTile.PermissionState {
        MeetingRecordingTile.PermissionState(
            microphoneGranted: settingsViewModel.microphoneGranted,
            screenRecordingGranted: settingsViewModel.screenRecordingGranted,
            sourceMode: settingsViewModel.meetingAudioSourceMode
        )
    }

    private var transformReservedHotkeys: [TransformShortcutReservedHotkey] {
        [
            TransformShortcutReservedHotkey(name: "Dictation", trigger: settingsViewModel.hotkeyTrigger),
            TransformShortcutReservedHotkey(name: "Push-to-talk", trigger: settingsViewModel.pushToTalkHotkeyTrigger),
            TransformShortcutReservedHotkey(name: "Meeting recording", trigger: settingsViewModel.meetingHotkeyTrigger),
        ].filter { !$0.trigger.isDisabled }
    }

    private var globalTranscriptionBottomBar: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            SpinnerRingView(size: 18, revolutionDuration: 2.0, tintColor: DesignSystem.Colors.accent)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(transcriptionViewModel.transcribingFileName)
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text("On-device")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.successGreen)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesignSystem.Colors.successGreen.opacity(0.12)))
                }

                HStack(spacing: 6) {
                    Text(transcriptionViewModel.progressHeadline)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("\u{00B7}")
                        .foregroundStyle(.tertiary)

                    Text("Safe to browse elsewhere")
                        .font(DesignSystem.Typography.micro)
                        .foregroundStyle(.tertiary)
                }
            }

            if let fraction = transcriptionViewModel.transcriptionProgress {
                Spacer(minLength: DesignSystem.Spacing.sm)

                HStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(DesignSystem.Colors.accent)
                        .frame(width: 96)

                    Text("\(Int((fraction * 100).rounded()))%")
                        .font(DesignSystem.Typography.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 32, alignment: .trailing)
                }
            }

            Spacer()

            Button {
                transcriptionViewModel.currentTranscription = nil
                state.selectedItem = .transcribe
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

private struct SidebarItemLabel: View {
    let item: SidebarItem

    var body: some View {
        Label(item.rawValue, systemImage: item.icon)
    }
}
