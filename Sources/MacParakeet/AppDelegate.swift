import AppKit
import Sparkle
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Auto-Update

    /// Sparkle update gating: refuses checks during active meeting recordings
    /// (so a relaunch can't kill an in-flight recording) and during local
    /// dev/sentinel builds (so a `0.0.0` / `dev` binary doesn't auto-update
    /// itself to the shipped release). See `SparkleUpdateGuard`.
    private lazy var sparkleUpdateGuard: SparkleUpdateGuard = SparkleUpdateGuard(
        isMeetingRecordingActive: { [weak self] in
            self?.meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true
        }
    )

    #if DEBUG
    private lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: sparkleUpdateGuard,
        userDriverDelegate: nil
    )
    #else
    private lazy var updaterController: SPUStandardUpdaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: sparkleUpdateGuard,
        userDriverDelegate: nil
    )
    #endif

    // MARK: - Runtime Services

    private var appEnvironment: AppEnvironment?
    private var hotkeyCoordinator: AppHotkeyCoordinator?
    private var dictationFlowCoordinator: DictationFlowCoordinator?
    private var meetingRecordingFlowCoordinator: MeetingRecordingFlowCoordinator?
    private var meetingAutoStartCoordinator: MeetingAutoStartCoordinator?
    /// Productized Transforms coordinator (ADR-022). Owns the process-wide
    /// `TransformsHotkeyRegistry` + dispatch from registered hotkeys to the
    /// `TransformExecutor` pipeline. Gated on `AppFeatures.transformsEnabled`.
    private var transformsCoordinator: TransformsCoordinator?
    private var hasPresentedHotkeyUnavailableAlert = false
    private var hasPresentedHotkeyConflictAlert = false
    private var environmentSetupTask: Task<Void, Never>?
    private var meetingQuitTask: Task<Void, Never>?
    private var speechPreWarmTask: Task<Void, Never>?
    private var instantDictationPreferenceTask: Task<Void, Never>?
    private var instantDictationPreferenceGeneration = 0
    private var isHotkeyRecorderActive = false
    // Let first paint and onboarding routing settle before starting CoreML cache work.
    private let preWarmDeferralMs: Int = 1500

    // MARK: - View Models

    private let transcriptionViewModel = TranscriptionViewModel()
    private let historyViewModel = DictationHistoryViewModel()
    private let settingsViewModel = SettingsViewModel()
    private let customWordsViewModel = CustomWordsViewModel()
    private let textSnippetsViewModel = TextSnippetsViewModel()
    private let vocabularyBackupViewModel = VocabularyBackupViewModel()
    private let feedbackViewModel = FeedbackViewModel()
    private let discoverViewModel = DiscoverViewModel()
    private let libraryViewModel = TranscriptionLibraryViewModel()
    private let meetingsLibraryViewModel = TranscriptionLibraryViewModel(scope: .meetings)
    private let llmSettingsViewModel = LLMSettingsViewModel()
    private let chatViewModel = TranscriptChatViewModel()
    private let promptResultsViewModel = PromptResultsViewModel()
    private let promptsViewModel = PromptsViewModel()
    private let transformsViewModel = TransformsViewModel()
    private let mainWindowState = MainWindowState()
    /// Long-lived companion for the meeting recording pill + Transcribe-tab tile.
    /// `MeetingRecordingFlowCoordinator` writes state into it; both the floating
    /// pill and the tile bind to the same instance.
    private let meetingPillViewModel = MeetingRecordingPillViewModel()
    private lazy var meetingsWorkspaceViewModel = MeetingsWorkspaceViewModel(
        recentMeetingsViewModel: meetingsLibraryViewModel,
        meetingPillViewModel: meetingPillViewModel,
        settingsViewModel: settingsViewModel,
        llmSettingsViewModel: llmSettingsViewModel
    )
    private let onboardingWindowController = OnboardingWindowController()

    private lazy var youtubeInputController = YouTubeInputPanelController(
        transcriptionViewModel: transcriptionViewModel
    )

    // MARK: - Coordinators

    private let startupBootstrapper = AppStartupBootstrapper()

    private lazy var environmentConfigurer = AppEnvironmentConfigurer(
        transcriptionViewModel: transcriptionViewModel,
        historyViewModel: historyViewModel,
        settingsViewModel: settingsViewModel,
        customWordsViewModel: customWordsViewModel,
        textSnippetsViewModel: textSnippetsViewModel,
        vocabularyBackupViewModel: vocabularyBackupViewModel,
        libraryViewModel: libraryViewModel,
        meetingsWorkspaceViewModel: meetingsWorkspaceViewModel,
        llmSettingsViewModel: llmSettingsViewModel,
        chatViewModel: chatViewModel,
        promptResultsViewModel: promptResultsViewModel,
        promptsViewModel: promptsViewModel,
        transformsViewModel: transformsViewModel,
        mainWindowState: mainWindowState,
        meetingPillViewModel: meetingPillViewModel
    )

    /// Drives the live, no-STT hotkey rehearsal on the onboarding "Learn the
    /// Hotkey" step. Reads the user's configured triggers + shared mic at arm
    /// time via providers, since the environment is set asynchronously after
    /// launch.
    private lazy var onboardingHotkeyPreviewController = OnboardingHotkeyPreviewController(
        planProvider: { [weak self] in
            guard let self else { return .init(specs: [], conflict: nil) }
            return AppHotkeyCoordinator.dictationHotkeyPlan(
                handsFree: self.settingsViewModel.hotkeyTrigger,
                pushToTalk: self.settingsViewModel.pushToTalkHotkeyTrigger
            )
        },
        micLevelingProvider: { [weak self] in
            guard let stream = self?.appEnvironment?.sharedMicStream else { return nil }
            return SharedMicLeveling(stream: stream)
        },
        suspendProductionHotkeys: { [weak self] in self?.hotkeyCoordinator?.suspend() },
        resumeProductionHotkeys: { [weak self] in self?.hotkeyCoordinator?.resume() }
    )

    private lazy var onboardingCoordinator = OnboardingCoordinator(
        onboardingWindowController: onboardingWindowController,
        onRefreshHotkeys: { [weak self] in
            self?.hotkeyCoordinator?.refreshAllHotkeys()
            self?.menuBarCoordinator.refreshHotkeyTitle()
            self?.menuBarCoordinator.refreshMeetingHotkeyShortcut()
            self?.menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
            self?.transformsCoordinator?.reloadBindings()
        },
        onOpenMainWindow: { [weak self] in
            self?.windowCoordinator.openMainWindow()
        },
        onOpenSettings: { [weak self] in
            self?.windowCoordinator.openMainWindowToSettings()
        },
        onCompleted: { [weak self] in
            guard let self, let env = self.appEnvironment else { return }
            self.scheduleDeferredSpeechPreWarm(environment: env)
        },
        onHotkeyPreviewArm: { [weak self] in
            self?.onboardingHotkeyPreviewController.arm()
        },
        onHotkeyPreviewDisarm: { [weak self] in
            self?.onboardingHotkeyPreviewController.disarm()
        }
    )

    private lazy var meetingRecoveryCoordinator = MeetingRecoveryCoordinator(
        environmentProvider: { [weak self] in
            self?.appEnvironment
        },
        settingsViewModel: settingsViewModel,
        libraryViewModel: libraryViewModel,
        onRecoveredTranscriptionsChanged: { [weak self] in
            self?.meetingsWorkspaceViewModel.refreshRecentMeetings()
        },
        onPresentRecoveredTranscription: { [weak self] transcription in
            guard let self else { return }
            self.transcriptionViewModel.presentCompletedTranscription(transcription, autoSave: true)
            self.mainWindowState.navigateToTranscription(from: .library)
            self.windowCoordinator.openMainWindow()
        }
    )

    private lazy var windowCoordinator = AppWindowCoordinator(
        mainWindowState: mainWindowState,
        transcriptionViewModel: transcriptionViewModel,
        historyViewModel: historyViewModel,
        settingsViewModel: settingsViewModel,
        llmSettingsViewModel: llmSettingsViewModel,
        chatViewModel: chatViewModel,
        promptResultsViewModel: promptResultsViewModel,
        promptsViewModel: promptsViewModel,
        transformsViewModel: transformsViewModel,
        customWordsViewModel: customWordsViewModel,
        textSnippetsViewModel: textSnippetsViewModel,
        vocabularyBackupViewModel: vocabularyBackupViewModel,
        feedbackViewModel: feedbackViewModel,
        discoverViewModel: discoverViewModel,
        libraryViewModel: libraryViewModel,
        meetingsWorkspaceViewModel: meetingsWorkspaceViewModel,
        meetingPillViewModel: meetingPillViewModel,
        updaterController: updaterController,
        onRecordMeeting: { [weak self] in
            self?.toggleMeetingRecording(originatesFromWindow: true)
        },
        onRecordMeetingFromWorkspace: { [weak self] in
            self?.startMeetingRecordingFromWorkspace()
        },
        onPauseToggleMeeting: { [weak self] in
            self?.meetingRecordingFlowCoordinator?.togglePause()
        },
        onHotkeyRecordingStateChanged: { [weak self] isRecording in
            self?.isHotkeyRecorderActive = isRecording
            // While Settings is recording a new hotkey, stand the global
            // CGEvent taps down so they can't swallow the user's keyDown
            // and silently fire their own actions (e.g. start a meeting
            // recording from inside Settings).
            if isRecording {
                self?.hotkeyCoordinator?.suspend()
                self?.transformsCoordinator?.suspendHotkeys()
            } else {
                self?.hotkeyCoordinator?.resume()
                self?.transformsCoordinator?.resumeHotkeys()
            }
        },
        onQuit: { [weak self] in
            self?.quitApp()
        },
        isOnboardingVisible: { [weak self] in
            self?.onboardingWindowController.isVisible ?? false
        }
    )

    private lazy var menuBarCoordinator = MenuBarCoordinator(
        updaterController: updaterController,
        transcriptionViewModel: transcriptionViewModel,
        youtubeInputController: youtubeInputController,
        environmentProvider: { [weak self] in
            self?.appEnvironment
        },
        hotkeyMenuTitleProvider: { [weak self] in
            self?.hotkeyMenuTitle ?? AppHotkeyCoordinator.menuTitle(handsFree: .defaultDictation, pushToTalk: .defaultPushToTalk)
        },
        meetingHotkeyTriggerProvider: { [weak self] in
            self?.settingsViewModel.meetingHotkeyTrigger ?? .defaultMeetingRecording
        },
        fileTranscriptionHotkeyTriggerProvider: { [weak self] in
            self?.settingsViewModel.fileTranscriptionHotkeyTrigger ?? .disabled
        },
        youtubeTranscriptionHotkeyTriggerProvider: { [weak self] in
            self?.settingsViewModel.youtubeTranscriptionHotkeyTrigger ?? .disabled
        },
        meetingRecordingActiveProvider: { [weak self] in
            self?.meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true
        },
        dictationCaptureActiveProvider: { [weak self] in
            self?.dictationFlowCoordinator?.isCapturingAudio == true
        },
        onOpenMainWindow: { [weak self] in
            self?.windowCoordinator.openMainWindow()
        },
        onOpenSettings: { [weak self] in
            self?.windowCoordinator.openMainWindowToSettings()
        },
        onNavigate: { [weak self] item in
            self?.mainWindowState.navigate(to: item)
        },
        onNewTranscription: { [weak self] in
            self?.transcriptionViewModel.showInputPortal()
            self?.mainWindowState.startNewTranscription()
        },
        onStartDictation: { [weak self] in
            self?.dictationFlowCoordinator?.startDictation(mode: .persistent, trigger: .menuBar)
        },
        onToggleMeetingRecording: { [weak self] in
            self?.toggleMeetingRecording(originatesFromWindow: false)
        },
        onCreateTransform: { [weak self] in
            self?.mainWindowState.beginCreatingTransform()
        },
        onQuit: { [weak self] in
            self?.quitApp()
        },
        onShowAboutPanel: { [weak self] in
            self?.showAboutPanel()
        }
    )

    private lazy var settingsObserverCoordinator = AppSettingsObserverCoordinator(
        onOpenOnboarding: { [weak self] in
            guard let self else { return }
            self.onboardingCoordinator.show(environment: self.appEnvironment)
        },
        onOpenSettings: { [weak self] tab in
            self?.windowCoordinator.openMainWindowToSettings(tab: tab)
        },
        onHotkeyTriggerChanged: { [weak self] in
            self?.handleHotkeyTriggerChange()
        },
        onPushToTalkHotkeyTriggerChanged: { [weak self] in
            self?.handleHotkeyTriggerChange()
        },
        onMeetingHotkeyTriggerChanged: { [weak self] in
            self?.handleMeetingHotkeyTriggerChange()
        },
        onFileTranscriptionHotkeyTriggerChanged: { [weak self] in
            self?.handleFileTranscriptionHotkeyTriggerChange()
        },
        onYouTubeTranscriptionHotkeyTriggerChanged: { [weak self] in
            self?.handleYouTubeTranscriptionHotkeyTriggerChange()
        },
        onAppearanceModeChanged: { [weak self] in
            self?.applyAppAppearance()
        },
        onMenuBarOnlyModeChanged: { [weak self] in
            self?.windowCoordinator.applyActivationPolicyFromSettings()
        },
        onShowIdlePillChanged: { [weak self] in
            self?.handleShowIdlePillChange()
        },
        onInstantDictationChanged: { [weak self] in
            self?.applyInstantDictationPreference(refreshWarmCapture: false)
        },
        onMicrophoneSelectionChanged: { [weak self] in
            self?.applyInstantDictationPreference(refreshWarmCapture: true)
        }
    )

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Process boot marker for the audio diagnostics log. The dev app and
        // `swift test` write into the same on-disk file
        // (`~/Library/Logs/MacParakeet/dictation-audio.log`); without this
        // marker, splitting transitions across processes/relaunches has to be
        // inferred. See journal/2026-05-03-dictation-silent-stall.md.
        let identity = BuildIdentity.current
        AudioCaptureDiagnostics.append(
            "dictation_diagnostics_session_start pid=\(getpid()) version=\(identity.version) build=\(identity.buildNumber) source=\(identity.buildSource) commit=\(identity.gitCommit)"
        )

        if isRunningFromDiskImage() {
            showMoveToApplicationsAlert()
            return
        }

        applyAppAppearance()
        startEnvironmentSetup()
        menuBarCoordinator.setupMainMenu()
        menuBarCoordinator.setupMenuBar()
        settingsObserverCoordinator.startObserving()
        windowCoordinator.applyActivationPolicyFromSettings()
        setupDiscoverContent()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Telemetry.flushForTermination() is handled by TelemetryService's own
        // NSApplicationWillTerminateNotification observer — calling it here too
        // would send duplicate appQuit events and double the termination delay.
        dictationFlowCoordinator?.releaseMediaPauseForTermination()
        dictationFlowCoordinator?.hideIdlePill()
        hotkeyCoordinator?.stopAll()
        meetingAutoStartCoordinator?.stop()
        transformsCoordinator?.stop()
        settingsObserverCoordinator.stopObserving()
        environmentSetupTask?.cancel()
        speechPreWarmTask?.cancel()

        // Bound the wait so termination does not hang, while still giving shutdown
        // a brief window to release resources cleanly.
        if let sttScheduler = appEnvironment?.sttScheduler {
            let done = DispatchSemaphore(value: 0)
            Task.detached(priority: .utility) {
                await sttScheduler.shutdown()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 0.35)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window closes — dictation/menu bar features stay available.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard meetingRecordingFlowCoordinator?.quitState != nil else {
            return .terminateNow
        }

        guard meetingQuitTask == nil else {
            return .terminateCancel
        }

        return presentActiveMeetingQuitAlert()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        windowCoordinator.handleAppReopen()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        windowCoordinator.makeDockMenu()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        onboardingCoordinator.handleApplicationDidBecomeActive(environment: appEnvironment)
    }

    // MARK: - Startup

    private func startEnvironmentSetup() {
        environmentSetupTask?.cancel()
        environmentSetupTask = Task { [weak self] in
            guard let self else { return }
            do {
                let env = try await startupBootstrapper.bootstrapEnvironment()
                guard !Task.isCancelled else { return }
                setupEnvironment(env)
            } catch is CancellationError {
                return
            } catch {
                presentEnvironmentSetupError(error)
            }
        }
    }

    private func setupEnvironment(_ env: AppEnvironment) {
        appEnvironment = env

        let runtime = environmentConfigurer.configure(
            environment: env,
            callbacks: .init(
                onMenuBarIconUpdate: { [weak self] in
                    self?.resolveAndUpdateMenuBarIcon()
                },
                onPresentEntitlementsAlert: { [weak self] error in
                    self?.presentEntitlementsAlert(error)
                },
                onOpenMainWindow: { [weak self] in
                    self?.windowCoordinator.openMainWindow()
                },
                onToggleMeetingRecordingFromHotkey: { [weak self] in
                    guard let self, !self.onboardingWindowController.isVisible else { return }
                    self.toggleMeetingRecording(originatesFromWindow: false, trigger: .hotkey)
                },
                onTriggerFileTranscriptionFromHotkey: { [weak self] in
                    guard let self, !self.onboardingWindowController.isVisible else { return }
                    self.triggerFileTranscriptionFromHotkey()
                },
                onTriggerYouTubeTranscriptionFromHotkey: { [weak self] in
                    guard let self, !self.onboardingWindowController.isVisible else { return }
                    self.triggerYouTubeTranscriptionFromHotkey()
                },
                onHotkeyBecameAvailable: { [weak self] in
                    self?.hasPresentedHotkeyUnavailableAlert = false
                    self?.hasPresentedHotkeyConflictAlert = false
                },
                onHotkeyUnavailable: { [weak self] in
                    self?.presentHotkeyUnavailableAlertIfNeeded()
                },
                onHotkeyConflict: { [weak self] trigger, conflicts in
                    self?.presentHotkeyConflictAlertIfNeeded(trigger: trigger, conflicts: conflicts)
                },
                onRecoverPendingMeetingRecordings: { [weak self] in
                    self?.meetingRecoveryCoordinator.presentPendingMeetingRecoveryDialog()
                },
                isHotkeyRecordingActive: { [weak self] in
                    self?.isHotkeyRecorderActive == true
                },
                isOnboardingVisible: { [weak self] in
                    self?.onboardingWindowController.isVisible ?? false
                }
            )
        )

        dictationFlowCoordinator = runtime.dictationFlowCoordinator
        meetingRecordingFlowCoordinator = runtime.meetingRecordingFlowCoordinator
        hotkeyCoordinator = runtime.hotkeyCoordinator
        meetingAutoStartCoordinator = runtime.meetingAutoStartCoordinator
        applyInstantDictationPreference(refreshWarmCapture: false)

        // Shared resolver for the user's LLM provider — returns the live
        // service when a provider is configured, nil otherwise. Consumed by
        // the Transforms coordinator below.
        let configStore = env.llmConfigStore
        let llmService = env.llmService
        let llmServiceProvider: () -> LLMServiceProtocol? = { [weak configStore, llmService] in
            guard let configStore else { return nil }
            return (try? configStore.loadConfig()) != nil ? llmService : nil
        }

        // Productized Transforms coordinator (ADR-022). Reads `.transform`
        // prompts from the shared `PromptRepository` and dispatches their
        // bound hotkeys through `TransformsHotkeyRegistry`. No-op when the
        // feature flag is off.
        let transforms = TransformsCoordinator(
            llmServiceProvider: llmServiceProvider,
            promptRepository: env.promptRepo,
            historyRepository: env.transformHistoryRepo,
            reservedHotkeysProvider: { [weak self] in
                self?.transformReservedHotkeysForTransforms() ?? []
            },
            onLLMProviderRequired: { [weak self] in
                self?.windowCoordinator.openMainWindowToSettings(tab: .ai)
            }
        )
        transforms.start()
        transformsCoordinator = transforms

        menuBarCoordinator.refreshHotkeyTitle()
        menuBarCoordinator.refreshMeetingHotkeyShortcut()
        menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
        onboardingCoordinator.maybeShow(environment: env)
        scheduleDeferredSpeechPreWarm(environment: env)
        meetingRecoveryCoordinator.scheduleLaunchRecoveryScanIfReady(environment: env)
    }

    private func scheduleDeferredSpeechPreWarm(environment env: AppEnvironment) {
        guard speechPreWarmTask == nil else { return }
        let sttRuntime = env.sttRuntime
        let vadModelPreparer = env.meetingVADModelPreparer
        let deferralMs = preWarmDeferralMs
        let onboardingCompletedKey = OnboardingViewModel.onboardingCompletedKey

        speechPreWarmTask = Task(priority: .utility) { @MainActor [weak self, sttRuntime, vadModelPreparer] in
            defer {
                self?.speechPreWarmTask = nil
            }

            try? await Task.sleep(for: .milliseconds(deferralMs))
            guard !Task.isCancelled else { return }
            let onboardingDone = UserDefaults.standard.string(forKey: onboardingCompletedKey) != nil
            guard onboardingDone else { return }
            await sttRuntime.backgroundWarmUp()

            // Universal VAD model availability (Phase 4.5,
            // plans/active/2026-05-meeting-vad-guided-live-chunking.md §6).
            // Runs every launch for every user so flipping the live-chunking
            // flag reaches the installed base, not just fresh installs. Kept
            // independent of the speech warm-up above: idempotent, silent-fail,
            // and the meeting path falls back to fixed chunking if it never
            // succeeds. No-op when the flag is off.
            guard !Task.isCancelled else { return }
            let prepOutcome = await MeetingVADLaunchPrep.run(
                featureEnabled: AppFeatures.meetingVadLiveChunkingEnabled,
                preparer: vadModelPreparer
            )
            // Only surface the transitions worth seeing. `alreadyCached`
            // (steady state) and `disabled` are silent to avoid per-launch
            // telemetry spam; `cancelled` (app quit mid-download) is dropped
            // because `run` already treats cancellation as non-failure. No
            // post-call `Task.isCancelled` guard here: once `run` has returned
            // a terminal outcome the work genuinely completed, so a late
            // cancellation shouldn't drop the one event we care about
            // (`prepared` — proof the installed base acquired the model).
            switch prepOutcome {
            case .prepared:
                Telemetry.send(.vadModelPrep(outcome: .prepared))
            case .failed:
                Telemetry.send(.vadModelPrep(outcome: .failed))
            case .alreadyCached, .disabled, .cancelled:
                break
            }
        }
    }

    private func presentEnvironmentSetupError(_ error: Error) {
        // Don't silently fail. Without a valid environment, the app can't function.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "MacParakeet Failed to Start"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Quit")
        _ = alert.runModal()

        NSApp.terminate(nil)
    }

    private func setupDiscoverContent() {
        guard let fallbackURL = Bundle.module.url(forResource: "discover-fallback", withExtension: "json"),
              let data = try? Data(contentsOf: fallbackURL) else { return }

        let service = DiscoverService(fallbackData: data)
        discoverViewModel.configure(service: service)
        discoverViewModel.loadCached()
        discoverViewModel.refreshInBackground()
    }

    // MARK: - Disk Image Guard

    private func isRunningFromDiskImage() -> Bool {
        Bundle.main.bundlePath.hasPrefix("/Volumes/")
    }

    private func showMoveToApplicationsAlert() {
        let alert = NSAlert()
        alert.messageText = "Move to Applications"
        alert.informativeText = "MacParakeet must be in your Applications folder to work correctly. " +
            "Running from a disk image prevents macOS from granting microphone and accessibility permissions.\n\n" +
            "Drag MacParakeet to the Applications folder in the DMG window, then launch it from there."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.runModal()

        NSApp.terminate(nil)
    }

    // MARK: - Event Handlers

    private func handleHotkeyTriggerChange() {
        hotkeyCoordinator?.refreshAllHotkeys()
        menuBarCoordinator.refreshHotkeyTitle()
        menuBarCoordinator.refreshMeetingHotkeyShortcut()
        transformsCoordinator?.reloadBindings()
    }

    /// Any auxiliary hotkey change refreshes all three auxiliary hotkeys so a
    /// newly-claimed trigger can disable a now-colliding peer without waiting
    /// for the user to visit Settings again.
    private func handleMeetingHotkeyTriggerChange() {
        refreshAuxiliaryHotkeys()
    }

    private func handleFileTranscriptionHotkeyTriggerChange() {
        refreshAuxiliaryHotkeys()
    }

    private func handleYouTubeTranscriptionHotkeyTriggerChange() {
        refreshAuxiliaryHotkeys()
    }

    private func applyAppAppearance() {
        AppAppearanceController.apply(settingsViewModel.appAppearanceMode)
    }

    private func refreshAuxiliaryHotkeys() {
        hotkeyCoordinator?.refreshMeetingHotkey()
        hotkeyCoordinator?.refreshFileTranscriptionHotkey()
        hotkeyCoordinator?.refreshYouTubeTranscriptionHotkey()
        menuBarCoordinator.refreshMeetingHotkeyShortcut()
        menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
        transformsCoordinator?.reloadBindings()
    }

    private func transformReservedHotkeysForTransforms() -> [TransformShortcutReservedHotkey] {
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

    private func triggerFileTranscriptionFromHotkey() {
        guard appEnvironment != nil else { return }
        menuBarCoordinator.invokeTranscribeFileFlow()
    }

    private func triggerYouTubeTranscriptionFromHotkey() {
        guard appEnvironment != nil else { return }
        menuBarCoordinator.invokeTranscribeYouTubeFlow()
    }

    private func handleShowIdlePillChange() {
        if settingsViewModel.showIdlePill {
            dictationFlowCoordinator?.showIdlePill()
        } else {
            dictationFlowCoordinator?.hideIdlePill()
        }
    }

    private func applyInstantDictationPreference(refreshWarmCapture: Bool) {
        guard let env = appEnvironment else { return }
        instantDictationPreferenceGeneration += 1
        let generation = instantDictationPreferenceGeneration
        instantDictationPreferenceTask?.cancel()
        instantDictationPreferenceTask = Task { [weak self, env] in
            guard !Task.isCancelled else { return }
            let enabled = env.runtimePreferences.instantDictationEnabled
            let isCurrent = await MainActor.run {
                self?.instantDictationPreferenceGeneration == generation
            }
            guard isCurrent, !Task.isCancelled else { return }
            await env.audioProcessor.setInstantDictationEnabled(enabled)
            let shouldRefresh = await MainActor.run {
                self?.instantDictationPreferenceGeneration == generation
            }
            guard shouldRefresh, !Task.isCancelled else { return }
            if refreshWarmCapture, enabled {
                await env.audioProcessor.refreshInstantDictationWarmCapture()
            }
        }
    }

    private var hotkeyMenuTitle: String {
        hotkeyCoordinator?.hotkeyMenuTitle
            ?? AppHotkeyCoordinator.menuTitle(
                handsFree: settingsViewModel.hotkeyTrigger,
                pushToTalk: settingsViewModel.pushToTalkHotkeyTrigger
            )
    }

    // MARK: - Menu Bar Icon State

    /// Priority-based menu bar icon resolver (ADR-015).
    /// Meeting recording > dictation menu-bar preference > file transcription > idle.
    ///
    /// Uses `menuBarPreference` from the dictation flow (state-machine-aware) so
    /// `.processing` can render correctly and terminal states do not linger red.
    private func resolveAndUpdateMenuBarIcon() {
        let state = Self.resolveMenuBarState(
            isMeetingRecordingActive: meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true,
            dictationMenuBarPreference: dictationFlowCoordinator?.menuBarPreference,
            isTranscribing: transcriptionViewModel.isTranscribing
        )
        menuBarCoordinator.updateIcon(state: state)
    }

    static func resolveMenuBarState(
        isMeetingRecordingActive: Bool,
        dictationMenuBarPreference: BreathWaveIcon.MenuBarState?,
        isTranscribing: Bool
    ) -> BreathWaveIcon.MenuBarState {
        if isMeetingRecordingActive {
            return .recording
        }
        if let dictationMenuBarPreference, dictationMenuBarPreference != .idle {
            return dictationMenuBarPreference
        }
        if isTranscribing {
            return .processing
        }
        return .idle
    }

    // MARK: - Meeting Recording

    private func toggleMeetingRecording(
        originatesFromWindow: Bool,
        trigger: TelemetryMeetingRecordingTrigger = .manual
    ) {
        guard appEnvironment != nil else { return }

        if meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true {
            meetingRecordingFlowCoordinator?.toggleRecording()
            return
        }

        if originatesFromWindow {
            // The Transcribe tab hosts the Meeting Recording tile, which
            // reflects live recording state. Show the user that surface so
            // they see the start/recording transition.
            mainWindowState.selectedItem = .transcribe
            windowCoordinator.openMainWindow()
        }

        meetingRecordingFlowCoordinator?.toggleRecording(trigger: trigger)
    }

    private func startMeetingRecordingFromWorkspace() {
        guard appEnvironment != nil else { return }

        if meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true {
            meetingRecordingFlowCoordinator?.toggleRecording()
            return
        }

        meetingRecordingFlowCoordinator?.startRecording(trigger: .manual)
    }

    private func presentActiveMeetingQuitAlert() -> NSApplication.TerminateReply {
        guard let quitState = meetingRecordingFlowCoordinator?.quitState else {
            return .terminateNow
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning

        switch quitState {
        case .starting:
            alert.messageText = "Meeting Recording Is Starting"
            alert.informativeText = "Cancel the pending recording before quitting, or keep MacParakeet open."
            alert.addButton(withTitle: "Cancel Recording & Quit")
            alert.addButton(withTitle: "Cancel Quit")
            if alert.buttons.indices.contains(0) {
                alert.buttons[0].hasDestructiveAction = true
            }
            if alert.runModal() == .alertFirstButtonReturn {
                finishMeetingThenQuit(discard: true)
            }

        case .recording:
            alert.messageText = "Meeting Recording in Progress"
            alert.informativeText = "End and transcribe the meeting before quitting, discard the recording, or keep MacParakeet open."
            alert.addButton(withTitle: "End & Transcribe")
            alert.addButton(withTitle: "Discard Recording")
            alert.addButton(withTitle: "Cancel Quit")
            if alert.buttons.indices.contains(1) {
                alert.buttons[1].hasDestructiveAction = true
            }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                finishMeetingThenQuit(discard: false)
            case .alertSecondButtonReturn:
                finishMeetingThenQuit(discard: true)
            default:
                break
            }

        case .finishing:
            alert.messageText = "Meeting Transcription in Progress"
            alert.informativeText = "MacParakeet is saving the meeting. Finish transcription before quitting, or keep the app open."
            alert.addButton(withTitle: "Finish & Quit")
            alert.addButton(withTitle: "Cancel Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                finishMeetingThenQuit(discard: false)
            }
        }

        return .terminateCancel
    }

    private func finishMeetingThenQuit(discard: Bool) {
        guard let coordinator = meetingRecordingFlowCoordinator else { return }

        meetingQuitTask?.cancel()
        meetingQuitTask = Task { @MainActor [weak self, coordinator] in
            if discard {
                await coordinator.discardRecordingAndWaitForCompletion()
            } else {
                await coordinator.stopRecordingAndWaitForCompletion()
            }
            guard !Task.isCancelled else { return }
            self?.meetingQuitTask = nil
            NSApp.terminate(nil)
        }
    }

    // MARK: - Alerts

    private func presentEntitlementsAlert(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Unlock Required"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            windowCoordinator.openMainWindowToSettings()
        }
    }

    private func presentHotkeyUnavailableAlertIfNeeded() {
        #if !DEBUG
        guard !hasPresentedHotkeyUnavailableAlert else { return }
        guard settingsViewModel.accessibilityGranted == false else { return }

        hasPresentedHotkeyUnavailableAlert = true
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Global Hotkey Unavailable"
        alert.informativeText =
            "MacParakeet couldn’t enable the system-wide hotkey because Accessibility access is missing. " +
            "You can still open the app manually, but dictation shortcuts won’t work until this is enabled."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            windowCoordinator.openMainWindowToSettings()
        }
        #endif
    }

    private func presentHotkeyConflictAlertIfNeeded(trigger: HotkeyTrigger, conflicts: [HotkeyTrigger]) {
        #if !DEBUG
        guard !hasPresentedHotkeyConflictAlert else { return }
        hasPresentedHotkeyConflictAlert = true
        NSApp.activate(ignoringOtherApps: true)

        let conflictNames = conflicts.map(\.displayName).joined(separator: ", ")
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hotkey Conflict"
        alert.informativeText =
            "\(trigger.displayName) overlaps with \(conflictNames), so one of these shortcuts was not enabled. " +
            "Open Settings to choose distinct shortcuts."
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Not Now")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            windowCoordinator.openMainWindowToSettings()
        }
        #endif
    }

    private func showAboutPanel() {
        let repoLink = "https://github.com/moona3k/macparakeet"
        guard let repoURL = URL(string: repoLink) else { return }
        let credits = NSMutableAttributedString()

        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let normalAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: style,
        ]
        let linkAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .link: repoURL,
            .paragraphStyle: style,
        ]

        credits.append(NSAttributedString(string: "Free and open source (GPL-3.0)\n", attributes: normalAttributes))
        credits.append(NSAttributedString(string: repoLink, attributes: linkAttributes))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private func quitApp() {
        NSApp.terminate(nil)
    }
}
