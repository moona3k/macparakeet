import Foundation
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppEnvironmentConfigurer {
    private final class CoordinatorRefs {
        weak var dictation: DictationFlowCoordinator?
        weak var meeting: MeetingRecordingFlowCoordinator?
    }

    struct Runtime {
        let dictationFlowCoordinator: DictationFlowCoordinator
        let meetingRecordingFlowCoordinator: MeetingRecordingFlowCoordinator
        let hotkeyCoordinator: AppHotkeyCoordinator
        let meetingAutoStartCoordinator: MeetingAutoStartCoordinator?
    }

    struct Callbacks {
        let onMenuBarIconUpdate: () -> Void
        let onPresentEntitlementsAlert: (Error) -> Void
        let onOpenMainWindow: () -> Void
        let onToggleMeetingRecordingFromHotkey: () -> Void
        let onTriggerFileTranscriptionFromHotkey: () -> Void
        let onTriggerYouTubeTranscriptionFromHotkey: () -> Void
        let onHotkeyBecameAvailable: () -> Void
        let onHotkeyUnavailable: () -> Void
    }

    private let transcriptionViewModel: TranscriptionViewModel
    private let historyViewModel: DictationHistoryViewModel
    private let settingsViewModel: SettingsViewModel
    private let customWordsViewModel: CustomWordsViewModel
    private let textSnippetsViewModel: TextSnippetsViewModel
    private let libraryViewModel: TranscriptionLibraryViewModel
    private let meetingsViewModel: TranscriptionLibraryViewModel
    private let llmSettingsViewModel: LLMSettingsViewModel
    private let chatViewModel: TranscriptChatViewModel
    private let promptResultsViewModel: PromptResultsViewModel
    private let promptsViewModel: PromptsViewModel
    private let mainWindowState: MainWindowState
    private weak var liveMeetingCoordinator: MeetingRecordingFlowCoordinator?

    init(
        transcriptionViewModel: TranscriptionViewModel,
        historyViewModel: DictationHistoryViewModel,
        settingsViewModel: SettingsViewModel,
        customWordsViewModel: CustomWordsViewModel,
        textSnippetsViewModel: TextSnippetsViewModel,
        libraryViewModel: TranscriptionLibraryViewModel,
        meetingsViewModel: TranscriptionLibraryViewModel,
        llmSettingsViewModel: LLMSettingsViewModel,
        chatViewModel: TranscriptChatViewModel,
        promptResultsViewModel: PromptResultsViewModel,
        promptsViewModel: PromptsViewModel,
        mainWindowState: MainWindowState
    ) {
        self.transcriptionViewModel = transcriptionViewModel
        self.historyViewModel = historyViewModel
        self.settingsViewModel = settingsViewModel
        self.customWordsViewModel = customWordsViewModel
        self.textSnippetsViewModel = textSnippetsViewModel
        self.libraryViewModel = libraryViewModel
        self.meetingsViewModel = meetingsViewModel
        self.llmSettingsViewModel = llmSettingsViewModel
        self.chatViewModel = chatViewModel
        self.promptResultsViewModel = promptResultsViewModel
        self.promptsViewModel = promptsViewModel
        self.mainWindowState = mainWindowState
    }

    func configure(environment env: AppEnvironment, callbacks: Callbacks) -> Runtime {
        Task {
            // Only bootstrap trial if onboarding is already completed (returning user).
            // For new users, trial starts at onboarding completion, not during setup.
            let onboardingDone = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
            if onboardingDone {
                await env.entitlementsService.bootstrapTrialIfNeeded()
            }
            await env.entitlementsService.refreshValidationIfNeeded()
        }

        let hasLLMConfig = (try? env.llmConfigStore.loadConfig()) != nil

        transcriptionViewModel.configure(
            transcriptionService: env.transcriptionService,
            transcriptionRepo: env.transcriptionRepo,
            llmService: hasLLMConfig ? env.llmService : nil,
            promptResultRepo: env.promptResultRepo,
            promptResultsViewModel: promptResultsViewModel
        )
        historyViewModel.configure(dictationRepo: env.dictationRepo)
        libraryViewModel.configure(transcriptionRepo: env.transcriptionRepo)
        meetingsViewModel.configure(transcriptionRepo: env.transcriptionRepo)
        settingsViewModel.configure(
            permissionService: env.permissionService,
            dictationRepo: env.dictationRepo,
            transcriptionRepo: env.transcriptionRepo,
            entitlementsService: env.entitlementsService,
            launchAtLoginService: env.launchAtLoginService,
            checkoutURL: env.checkoutURL,
            customWordRepo: env.customWordRepo,
            snippetRepo: env.snippetRepo,
            sttClient: env.sttScheduler
        )
        customWordsViewModel.configure(repo: env.customWordRepo)
        textSnippetsViewModel.configure(repo: env.snippetRepo)
        promptsViewModel.configure(repo: env.promptRepo)
        llmSettingsViewModel.configure(
            configStore: env.llmConfigStore,
            llmClient: env.llmClient
        )

        settingsViewModel.onDictationStateChanged = { [weak self] in
            self?.historyViewModel.loadDictations()
        }

        llmSettingsViewModel.onConfigurationChanged = { [weak self] in
            self?.refreshLLMAvailability(in: env)
        }

        chatViewModel.configure(
            llmService: hasLLMConfig ? env.llmService : nil,
            transcriptText: "",
            transcriptionRepo: env.transcriptionRepo,
            configStore: env.llmConfigStore,
            conversationRepo: env.chatConversationRepo
        )

        promptResultsViewModel.configure(
            llmService: hasLLMConfig ? env.llmService : nil,
            promptRepo: env.promptRepo,
            promptResultRepo: env.promptResultRepo,
            transcriptionRepo: env.transcriptionRepo,
            configStore: env.llmConfigStore
        )

        chatViewModel.onConversationsChanged = { [weak self] transcriptionID, hasConversations in
            self?.transcriptionViewModel.updateConversationStatus(
                id: transcriptionID,
                hasConversations: hasConversations
            )
        }

        chatViewModel.onModelChanged = { [weak self] in
            self?.promptResultsViewModel.refreshModelInfo()
        }

        promptResultsViewModel.onModelChanged = { [weak self] in
            self?.chatViewModel.refreshModelInfo()
        }

        promptResultsViewModel.onPromptResultsChanged = { [weak self] transcriptionID, hasPromptResults in
            guard self?.transcriptionViewModel.currentTranscription?.id == transcriptionID else { return }
            self?.transcriptionViewModel.hasPromptResultTabs = hasPromptResults
        }

        promptResultsViewModel.onLegacySummaryChanged = { [weak self] transcriptionID, summary in
            self?.transcriptionViewModel.updateLegacySummary(id: transcriptionID, summary: summary)
        }

        promptResultsViewModel.onGenerationCompleted = { [weak self] generationID, promptResultID in
            self?.transcriptionViewModel.handleGenerationCompleted(generationID, promptResultID: promptResultID)
        }

        promptResultsViewModel.onDeletedPromptResult = { [weak self] promptResultID in
            self?.transcriptionViewModel.handlePromptResultDeleted(promptResultID)
        }

        promptResultsViewModel.shouldMarkPromptResultUnread = { [weak self] promptResultID in
            guard let self else { return true }
            if case .result(let id) = self.transcriptionViewModel.selectedTab,
               id == promptResultID {
                return false
            }
            return true
        }

        transcriptionViewModel.onTranscribingChanged = { _ in
            callbacks.onMenuBarIconUpdate()
        }

        let coordinatorRefs = CoordinatorRefs()

        let dictationCoordinator = DictationFlowCoordinator(
            dictationService: env.dictationService,
            clipboardService: env.clipboardService,
            entitlementsService: env.entitlementsService,
            dictationRepo: env.dictationRepo,
            settingsViewModel: settingsViewModel,
            shouldSuppressIdlePill: {
                coordinatorRefs.meeting?.isMeetingRecordingActive == true
            },
            onMenuBarIconUpdate: { _ in callbacks.onMenuBarIconUpdate() },
            onHistoryReload: { [weak self] in self?.historyViewModel.loadDictations() },
            onPresentEntitlementsAlert: callbacks.onPresentEntitlementsAlert
        )
        coordinatorRefs.dictation = dictationCoordinator

        let meetingCoordinator = MeetingRecordingFlowCoordinator(
            meetingRecordingService: env.meetingRecordingService,
            transcriptionService: env.transcriptionService,
            permissionService: env.permissionService,
            transcriptionRepo: env.transcriptionRepo,
            conversationRepo: env.chatConversationRepo,
            configStore: env.llmConfigStore,
            llmService: hasLLMConfig ? env.llmService : nil,
            onMenuBarIconUpdate: { _ in callbacks.onMenuBarIconUpdate() },
            onTranscriptionReady: { [weak self] transcription in
                guard let self else { return }
                self.transcriptionViewModel.presentCompletedTranscription(transcription, autoSave: true)
                self.libraryViewModel.loadTranscriptions()
                self.meetingsViewModel.loadTranscriptions()
                self.mainWindowState.navigateToTranscription(from: .meetings)
                callbacks.onOpenMainWindow()
            },
            onRecordingBegan: {
                coordinatorRefs.dictation?.hideIdlePill()
            },
            onFlowReturnedToIdle: {
                callbacks.onMenuBarIconUpdate()
                guard coordinatorRefs.dictation?.isDictationActive != true else { return }
                coordinatorRefs.dictation?.showIdlePill()
            }
        )
        coordinatorRefs.meeting = meetingCoordinator
        liveMeetingCoordinator = meetingCoordinator

        let hotkeyCoordinator = AppHotkeyCoordinator(
            settingsViewModel: settingsViewModel,
            onStartDictation: { mode in
                coordinatorRefs.dictation?.startDictation(mode: mode, trigger: .hotkey)
            },
            onStopDictation: {
                coordinatorRefs.dictation?.stopDictation()
            },
            onCancelDictation: {
                coordinatorRefs.dictation?.cancelDictation(reason: .escape)
            },
            onDiscardRecording: { showReadyPill in
                coordinatorRefs.dictation?.discardProvisionalRecording(showReadyPill: showReadyPill)
            },
            onReadyForSecondTap: {
                coordinatorRefs.dictation?.showReadyPill()
            },
            onEscapeWhileIdle: {
                coordinatorRefs.dictation?.dismissOverlayIfError()
            },
            onToggleMeetingRecording: callbacks.onToggleMeetingRecordingFromHotkey,
            onTriggerFileTranscription: callbacks.onTriggerFileTranscriptionFromHotkey,
            onTriggerYouTubeTranscription: callbacks.onTriggerYouTubeTranscriptionFromHotkey,
            onPrimaryHotkeyManagerChanged: { manager in
                coordinatorRefs.dictation?.hotkeyManager = manager
            },
            onAnyHotkeyEnabled: callbacks.onHotkeyBecameAvailable,
            onHotkeyUnavailable: callbacks.onHotkeyUnavailable
        )

        hotkeyCoordinator.setupPrimaryHotkey()
        hotkeyCoordinator.setupMeetingHotkey()
        hotkeyCoordinator.setupFileTranscriptionHotkey()
        hotkeyCoordinator.setupYouTubeTranscriptionHotkey()
        dictationCoordinator.showIdlePill()

        // Calendar auto-start (ADR-017 Phases 1 + 2 — reminders +
        // countdown toast + auto-stop). The coordinator is a no-op when
        // `calendarAutoStartMode == .off` so it's safe to start
        // unconditionally; we still gate creation on the meeting-recording
        // feature flag because calendar integration only makes sense when
        // the user can actually record meetings.
        let calendarCoordinator: MeetingAutoStartCoordinator?
        if AppFeatures.meetingRecordingEnabled {
            let coordinator = MeetingAutoStartCoordinator(
                calendarService: CalendarService.shared,
                settingsViewModel: settingsViewModel,
                isRecordingActive: { [weak meetingCoordinator] in
                    meetingCoordinator?.isMeetingRecordingActive ?? false
                },
                onAutoStartConfirmed: { [weak meetingCoordinator] title in
                    meetingCoordinator?.startFromCalendar(title: title)
                },
                onAutoStopConfirmed: { [weak meetingCoordinator] in
                    meetingCoordinator?.toggleRecording()
                }
            )
            // The recording flow tells the calendar coordinator when an
            // auto-start attempt actually failed (state was non-idle, or
            // the underlying start threw) so the optimistic binding gets
            // dropped — otherwise the next meeting's auto-stop would be
            // suppressed by a stale `autoStartedEventId`.
            meetingCoordinator.onAutoStartFailed = { [weak coordinator] in
                coordinator?.clearAutoStartBinding()
            }
            coordinator.start()
            calendarCoordinator = coordinator
        } else {
            calendarCoordinator = nil
        }

        return Runtime(
            dictationFlowCoordinator: dictationCoordinator,
            meetingRecordingFlowCoordinator: meetingCoordinator,
            hotkeyCoordinator: hotkeyCoordinator,
            meetingAutoStartCoordinator: calendarCoordinator
        )
    }

    func refreshLLMAvailability(in env: AppEnvironment) {
        let hasConfig = (try? env.llmConfigStore.loadConfig()) != nil
        let service: LLMService? = hasConfig ? env.llmService : nil
        transcriptionViewModel.updateLLMAvailability(hasConfig, llmService: service)
        chatViewModel.updateLLMService(service)
        promptResultsViewModel.updateLLMService(service)
        liveMeetingCoordinator?.updateLLMService(service)
    }
}
