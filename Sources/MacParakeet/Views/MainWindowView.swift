import Sparkle
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

enum SidebarItem: String, CaseIterable, Identifiable {
    case transcribe = "Transcribe"
    case library = "Library"
    case dictations = "Dictations"
    case meetings = "Meetings"
    case transforms = "Transforms"
    case vocabulary = "Vocabulary"
    case feedback = "Feedback"
    case settings = "Settings"
    case discover = "Discover"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .transcribe: return "waveform"
        case .meetings: return "person.2.wave.2"
        case .library: return "square.grid.2x2"
        case .dictations: return "clock.arrow.circlepath"
        case .transforms: return "wand.and.stars"
        case .vocabulary: return "book.fill"
        case .feedback: return "bubble.left.and.text.bubble.right"
        case .settings: return "gearshape"
        case .discover: return "sparkles"
        }
    }

    /// Primary features — the core things users do. Library remains the
    /// universal archive; Meetings is the workflow space for live/upcoming
    /// and saved meeting work.
    static var primaryItems: [SidebarItem] {
        var items: [SidebarItem] = [.transcribe, .library, .dictations]
        if AppFeatures.meetingRecordingEnabled {
            items.append(.meetings)
        }
        return items
    }

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
    @State private var showGlobalCancelConfirmation = false

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
    let meetingsWorkspaceViewModel: MeetingsWorkspaceViewModel
    let meetingPillViewModel: MeetingRecordingPillViewModel
    let updater: SPUUpdater
    let onRecordMeeting: () -> Void
    let onRecordMeetingFromWorkspace: () -> Void
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
                .tint(DesignSystem.Colors.accent)
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
                    case .meetings:
                        MeetingsView(
                            viewModel: meetingsWorkspaceViewModel,
                            onRecordMeeting: {
                                onRecordMeetingFromWorkspace()
                            },
                            onPauseToggleMeeting: onPauseToggleMeeting,
                            onOpenCalendarSettings: {
                                state.navigateToSettings(tab: .capture, anchor: "meeting")
                            },
                            onOpenAISettings: {
                                state.navigateToSettings(tab: .ai)
                            },
                            onRecoverMeetings: {
                                settingsViewModel.requestPendingMeetingRecovery()
                            },
                            onSelectMeeting: { transcription in
                                transcriptionViewModel.currentTranscription = transcription
                                state.navigateToTranscription(from: .meetings)
                            }
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
                                },
                                onSetUpAI: {
                                    state.navigateToSettings(tab: .ai)
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
                            reservedHotkeys: transformReservedHotkeys,
                            llmConfiguredAction: { state.navigateToSettings(tab: .ai) },
                            onEdit: { state.editingTransform = $0 },
                            onCreate: { state.isCreatingTransform = true },
                            onBindingsChanged: {
                                NotificationCenter.default.post(name: .transformsBindingsChanged, object: nil)
                            }
                        )
                        .sheet(isPresented: $state.isCreatingTransform) {
                            TransformEditorSheetHost(
                                mode: .create,
                                existingPrompts: transformsViewModel.allPrompts,
                                reservedHotkeys: transformReservedHotkeys,
                                onShortcutRecordingStateChanged: onHotkeyRecordingStateChanged,
                                onSave: { prompt in
                                    Task {
                                        if await transformsViewModel.save(prompt) {
                                            state.isCreatingTransform = false
                                            NotificationCenter.default.post(name: .transformsBindingsChanged, object: nil)
                                        }
                                    }
                                },
                                onCancel: { state.isCreatingTransform = false },
                                onReset: nil
                            )
                        }
                        .sheet(item: $state.editingTransform) { transform in
                            TransformEditorSheetHost(
                                mode: .edit(transform),
                                existingPrompts: transformsViewModel.allPrompts,
                                reservedHotkeys: transformReservedHotkeys,
                                onShortcutRecordingStateChanged: onHotkeyRecordingStateChanged,
                                onSave: { prompt in
                                    Task {
                                        if await transformsViewModel.save(prompt) {
                                            state.editingTransform = nil
                                            NotificationCenter.default.post(name: .transformsBindingsChanged, object: nil)
                                        }
                                    }
                                },
                                onCancel: { state.editingTransform = nil },
                                onReset: transform.isBuiltIn ? {
                                    Task {
                                        if await transformsViewModel.resetBuiltIn(
                                            transform,
                                            reservedHotkeys: transformReservedHotkeys
                                        ) {
                                            state.editingTransform = nil
                                            NotificationCenter.default.post(name: .transformsBindingsChanged, object: nil)
                                        } else {
                                            state.editingTransform = nil
                                        }
                                    }
                                } : nil
                            )
                        }
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
                            transformHotkeys: transformsViewModel.transforms,
                            requestedTab: state.requestedSettingsTab,
                            requestedAnchor: state.requestedSettingsAnchor,
                            requestedTabRevision: state.requestedSettingsTabRevision,
                            onRequestedTabConsumed: {
                                state.consumeRequestedSettingsTab()
                            },
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
        .alert("Cancel All Transcriptions?", isPresented: $showGlobalCancelConfirmation) {
            Button("Cancel All", role: .destructive) {
                transcriptionViewModel.cancelBatch()
            }
            Button("Continue", role: .cancel) {}
        } message: {
            Text("This stops the remaining files in the batch. Files already transcribed are kept in your Library.")
        }
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
        .onChange(of: state.selectedItem) { _, newItem in
            // Bulk-selection mode is a History-only affordance living on a
            // process-lifetime singleton, so tear it down at the navigation
            // boundary when the user leaves the Dictations section. Handled here
            // rather than via `DictationHistoryView.onDisappear`, which can fire
            // on transient macOS view-lifecycle events and reset an active
            // selection mid-browse.
            if newItem != .dictations {
                historyViewModel.exitBulkSelection()
            }
        }
    }

    /// Show the global bottom bar when transcribing on any tab except Transcribe (which has its own detailed view)
    private var showGlobalProgressBar: Bool {
        (transcriptionViewModel.isTranscribing || transcriptionViewModel.isBatchActive)
            && state.selectedItem != .transcribe
    }

    private var transformReservedHotkeys: [TransformShortcutReservedHotkey] {
        var reserved: [TransformShortcutReservedHotkey] = [
            TransformShortcutReservedHotkey(
                name: "hands-free dictation",
                trigger: settingsViewModel.hotkeyTrigger,
                conflictMode: .bareModifierDictation
            ),
            TransformShortcutReservedHotkey(
                name: "push to talk",
                trigger: settingsViewModel.pushToTalkHotkeyTrigger,
                conflictMode: .bareModifierDictation
            ),
            TransformShortcutReservedHotkey(name: "file transcription", trigger: settingsViewModel.fileTranscriptionHotkeyTrigger),
            TransformShortcutReservedHotkey(name: "video URL transcription", trigger: settingsViewModel.youtubeTranscriptionHotkeyTrigger),
        ]
        if AppFeatures.meetingRecordingEnabled {
            reserved.append(TransformShortcutReservedHotkey(name: "meeting recording", trigger: settingsViewModel.meetingHotkeyTrigger))
        }
        return reserved.filter { !$0.trigger.isDisabled }
    }

    private var meetingPermissionState: MeetingRecordingTile.PermissionState {
        MeetingRecordingTile.PermissionState(
            microphoneGranted: settingsViewModel.microphoneGranted,
            screenRecordingGranted: settingsViewModel.screenRecordingGranted,
            sourceMode: settingsViewModel.meetingAudioSourceMode
        )
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
                    Text(transcriptionViewModel.isBatchActive
                        ? transcriptionViewModel.batchStatusHeadline
                        : transcriptionViewModel.progressHeadline)
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

            if transcriptionViewModel.isBatchActive {
                Button {
                    showGlobalCancelConfirmation = true
                } label: {
                    Text("Cancel all")
                        .font(DesignSystem.Typography.caption.weight(.semibold))
                        .foregroundStyle(DesignSystem.Colors.errorRed)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Layout.buttonCornerRadius)
                                .fill(DesignSystem.Colors.errorRed.opacity(0.1))
                        )
                }
                .buttonStyle(.plain)
            } else {
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
        }
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .padding(.vertical, DesignSystem.Spacing.sm)
        .background(DesignSystem.Colors.cardBackground)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

private struct TransformEditorSheetHost: View {
    @State private var editorViewModel: TransformEditorViewModel

    let existingPrompts: [Prompt]
    let reservedHotkeys: [TransformShortcutReservedHotkey]
    let onShortcutRecordingStateChanged: (Bool) -> Void
    let onSave: (Prompt) -> Void
    let onCancel: () -> Void
    let onReset: (() -> Void)?

    init(
        mode: TransformEditorViewModel.Mode,
        existingPrompts: [Prompt],
        reservedHotkeys: [TransformShortcutReservedHotkey],
        onShortcutRecordingStateChanged: @escaping (Bool) -> Void,
        onSave: @escaping (Prompt) -> Void,
        onCancel: @escaping () -> Void,
        onReset: (() -> Void)?
    ) {
        _editorViewModel = State(initialValue: TransformEditorViewModel(mode: mode))
        self.existingPrompts = existingPrompts
        self.reservedHotkeys = reservedHotkeys
        self.onShortcutRecordingStateChanged = onShortcutRecordingStateChanged
        self.onSave = onSave
        self.onCancel = onCancel
        self.onReset = onReset
    }

    var body: some View {
        TransformEditorSheet(
            viewModel: editorViewModel,
            existingPrompts: existingPrompts,
            reservedHotkeys: reservedHotkeys,
            onShortcutRecordingStateChanged: onShortcutRecordingStateChanged,
            onSave: onSave,
            onCancel: onCancel,
            onReset: onReset
        )
    }
}

private struct SidebarItemLabel: View {
    let item: SidebarItem

    var body: some View {
        Label(item.rawValue, systemImage: item.icon)
    }
}
