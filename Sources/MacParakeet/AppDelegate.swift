import AppKit
import Sparkle
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Auto-Update

    #if DEBUG
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #else
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
    #endif

    // MARK: - Runtime Services

    private var appEnvironment: AppEnvironment?
    private var hotkeyCoordinator: AppHotkeyCoordinator?
    private var dictationFlowCoordinator: DictationFlowCoordinator?
    private var meetingRecordingFlowCoordinator: MeetingRecordingFlowCoordinator?
    private var meetingAutoStartCoordinator: MeetingAutoStartCoordinator?
    private var hasPresentedHotkeyUnavailableAlert = false
    private var environmentSetupTask: Task<Void, Never>?

    // MARK: - View Models

    private let transcriptionViewModel = TranscriptionViewModel()
    private let historyViewModel = DictationHistoryViewModel()
    private let settingsViewModel = SettingsViewModel()
    private let customWordsViewModel = CustomWordsViewModel()
    private let textSnippetsViewModel = TextSnippetsViewModel()
    private let feedbackViewModel = FeedbackViewModel()
    private let discoverViewModel = DiscoverViewModel()
    private let libraryViewModel = TranscriptionLibraryViewModel()
    private let meetingsViewModel = TranscriptionLibraryViewModel(scope: .meetings)
    private let llmSettingsViewModel = LLMSettingsViewModel()
    private let chatViewModel = TranscriptChatViewModel()
    private let promptResultsViewModel = PromptResultsViewModel()
    private let promptsViewModel = PromptsViewModel()
    private let mainWindowState = MainWindowState()
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
        libraryViewModel: libraryViewModel,
        meetingsViewModel: meetingsViewModel,
        llmSettingsViewModel: llmSettingsViewModel,
        chatViewModel: chatViewModel,
        promptResultsViewModel: promptResultsViewModel,
        promptsViewModel: promptsViewModel,
        mainWindowState: mainWindowState
    )

    private lazy var onboardingCoordinator = OnboardingCoordinator(
        onboardingWindowController: onboardingWindowController,
        onRefreshHotkeys: { [weak self] in
            self?.hotkeyCoordinator?.refreshAllHotkeys()
            self?.menuBarCoordinator.refreshHotkeyTitle()
            self?.menuBarCoordinator.refreshMeetingHotkeyShortcut()
            self?.menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
        },
        onOpenMainWindow: { [weak self] in
            self?.windowCoordinator.openMainWindow()
        },
        onOpenSettings: { [weak self] in
            self?.windowCoordinator.openMainWindowToSettings()
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
        customWordsViewModel: customWordsViewModel,
        textSnippetsViewModel: textSnippetsViewModel,
        feedbackViewModel: feedbackViewModel,
        discoverViewModel: discoverViewModel,
        libraryViewModel: libraryViewModel,
        meetingsViewModel: meetingsViewModel,
        updaterController: updaterController,
        onRecordMeeting: { [weak self] in
            self?.toggleMeetingRecording(originatesFromWindow: true)
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
            self?.hotkeyMenuTitle ?? AppHotkeyCoordinator.menuTitle(for: HotkeyTrigger.current)
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
        onOpenMainWindow: { [weak self] in
            self?.windowCoordinator.openMainWindow()
        },
        onOpenSettings: { [weak self] in
            self?.windowCoordinator.openMainWindowToSettings()
        },
        onToggleMeetingRecording: { [weak self] in
            self?.toggleMeetingRecording(originatesFromWindow: false)
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
        onOpenSettings: { [weak self] in
            self?.windowCoordinator.openMainWindowToSettings()
        },
        onHotkeyTriggerChanged: { [weak self] in
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
        onMenuBarOnlyModeChanged: { [weak self] in
            self?.windowCoordinator.applyActivationPolicyFromSettings()
        },
        onShowIdlePillChanged: { [weak self] in
            self?.handleShowIdlePillChange()
        }
    )

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningFromDiskImage() {
            showMoveToApplicationsAlert()
            return
        }

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
        dictationFlowCoordinator?.hideIdlePill()
        hotkeyCoordinator?.stopAll()
        meetingAutoStartCoordinator?.stop()
        settingsObserverCoordinator.stopObserving()
        environmentSetupTask?.cancel()

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
                    self?.toggleMeetingRecording(originatesFromWindow: false)
                },
                onTriggerFileTranscriptionFromHotkey: { [weak self] in
                    self?.triggerFileTranscriptionFromHotkey()
                },
                onTriggerYouTubeTranscriptionFromHotkey: { [weak self] in
                    self?.triggerYouTubeTranscriptionFromHotkey()
                },
                onHotkeyBecameAvailable: { [weak self] in
                    self?.hasPresentedHotkeyUnavailableAlert = false
                },
                onHotkeyUnavailable: { [weak self] in
                    self?.presentHotkeyUnavailableAlertIfNeeded()
                },
                onRecoverPendingMeetingRecordings: { [weak self] in
                    self?.presentPendingMeetingRecoveryDialog()
                }
            )
        )

        dictationFlowCoordinator = runtime.dictationFlowCoordinator
        meetingRecordingFlowCoordinator = runtime.meetingRecordingFlowCoordinator
        hotkeyCoordinator = runtime.hotkeyCoordinator
        meetingAutoStartCoordinator = runtime.meetingAutoStartCoordinator

        menuBarCoordinator.refreshHotkeyTitle()
        menuBarCoordinator.refreshMeetingHotkeyShortcut()
        menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
        onboardingCoordinator.maybeShow(environment: env)
        scheduleLaunchRecoveryScanIfReady(environment: env)
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

    private func refreshAuxiliaryHotkeys() {
        hotkeyCoordinator?.refreshMeetingHotkey()
        hotkeyCoordinator?.refreshFileTranscriptionHotkey()
        hotkeyCoordinator?.refreshYouTubeTranscriptionHotkey()
        menuBarCoordinator.refreshMeetingHotkeyShortcut()
        menuBarCoordinator.refreshTranscriptionHotkeyShortcuts()
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

    private var hotkeyMenuTitle: String {
        hotkeyCoordinator?.hotkeyMenuTitle
            ?? AppHotkeyCoordinator.menuTitle(for: HotkeyTrigger.current)
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

    private func toggleMeetingRecording(originatesFromWindow: Bool) {
        guard appEnvironment != nil else { return }

        if meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true {
            meetingRecordingFlowCoordinator?.toggleRecording()
            return
        }

        if originatesFromWindow {
            mainWindowState.selectedItem = .meetings
            windowCoordinator.openMainWindow()
        }

        meetingRecordingFlowCoordinator?.toggleRecording()
    }

    private func scheduleLaunchRecoveryScanIfReady(environment env: AppEnvironment) {
        let onboardingDone = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
        guard onboardingDone else { return }

        Task { [weak self] in
            guard let self else { return }
            do {
                let recoveries = try await env.meetingRecordingRecoveryService.discoverPendingRecoveries()
                self.settingsViewModel.refreshPendingMeetingRecoveries()
                guard !recoveries.isEmpty else { return }
                Telemetry.send(.meetingRecoveryDiscovered(count: recoveries.count, source: .launch))
                self.presentMeetingRecoveryDialog(recoveries, source: .launch)
            } catch {
                self.presentMeetingRecoveryError(error)
            }
        }
    }

    private func presentPendingMeetingRecoveryDialog() {
        guard let env = appEnvironment else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let recoveries = try await env.meetingRecordingRecoveryService.discoverPendingRecoveries()
                self.settingsViewModel.refreshPendingMeetingRecoveries()
                guard !recoveries.isEmpty else { return }
                Telemetry.send(.meetingRecoveryDiscovered(count: recoveries.count, source: .settings))
                self.presentMeetingRecoveryDialog(recoveries, source: .settings)
            } catch {
                self.presentMeetingRecoveryError(error)
            }
        }
    }

    private func presentMeetingRecoveryDialog(
        _ recoveries: [MeetingRecordingLockFile],
        source: TelemetryMeetingRecoverySource
    ) {
        guard let env = appEnvironment else { return }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "We found \(recoveries.count) interrupted recording\(recoveries.count == 1 ? "" : "s")"
        alert.informativeText = recoveryDialogMessage(for: recoveries)
        alert.addButton(withTitle: "Recover")
        alert.addButton(withTitle: "Recover Later")
        alert.addButton(withTitle: "Discard")

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            Task { [weak self] in
                guard let self else { return }
                await self.recoverMeetingRecordings(recoveries, environment: env, source: source)
            }
        case .alertThirdButtonReturn:
            Task { [weak self] in
                guard let self else { return }
                await self.discardMeetingRecoveries(recoveries, environment: env, source: source)
            }
        default:
            settingsViewModel.refreshPendingMeetingRecoveries()
        }
    }

    private func recoveryDialogMessage(for recoveries: [MeetingRecordingLockFile]) -> String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        let sessionLines = recoveries.prefix(5).map { recovery in
            "\(formatter.string(from: recovery.startedAt)) - \(recovery.displayName)"
        }
        let extraCount = max(0, recoveries.count - sessionLines.count)
        let extraLine = extraCount > 0 ? ["and \(extraCount) more"] : []
        return (sessionLines + extraLine).joined(separator: "\n")
            + "\n\nRecovery transcribes the saved audio again and marks the result as recovered."
    }

    private func recoverMeetingRecordings(
        _ recoveries: [MeetingRecordingLockFile],
        environment env: AppEnvironment,
        source: TelemetryMeetingRecoverySource
    ) async {
        let startedAt = Date()
        Telemetry.send(.meetingRecoveryStarted(count: recoveries.count, source: source))
        do {
            var recovered: [Transcription] = []
            for recovery in recoveries {
                recovered.append(try await env.meetingRecordingRecoveryService.recover(recovery))
            }
            Telemetry.send(.meetingRecoveryCompleted(
                count: recovered.count,
                durationSeconds: Date().timeIntervalSince(startedAt),
                source: source
            ))
            libraryViewModel.loadTranscriptions()
            meetingsViewModel.loadTranscriptions()
            settingsViewModel.refreshPendingMeetingRecoveries()
            if let first = recovered.first {
                transcriptionViewModel.presentCompletedTranscription(first, autoSave: true)
                mainWindowState.navigateToTranscription(from: .meetings)
                windowCoordinator.openMainWindow()
            }
        } catch {
            Telemetry.send(.meetingRecoveryFailed(
                count: recoveries.count,
                source: source,
                errorType: TelemetryErrorClassifier.classify(error),
                errorDetail: TelemetryErrorClassifier.errorDetail(error)
            ))
            settingsViewModel.refreshPendingMeetingRecoveries()
            presentMeetingRecoveryError(error, recoveries: recoveries, environment: env, source: source)
        }
    }

    private func discardMeetingRecoveries(
        _ recoveries: [MeetingRecordingLockFile],
        environment env: AppEnvironment,
        source: TelemetryMeetingRecoverySource
    ) async {
        do {
            for recovery in recoveries {
                try await env.meetingRecordingRecoveryService.discard(recovery)
            }
            Telemetry.send(.meetingRecoveryDiscarded(count: recoveries.count, source: source))
            settingsViewModel.refreshPendingMeetingRecoveries()
        } catch {
            Telemetry.send(.meetingRecoveryFailed(
                count: recoveries.count,
                source: source,
                errorType: TelemetryErrorClassifier.classify(error),
                errorDetail: TelemetryErrorClassifier.errorDetail(error)
            ))
            settingsViewModel.refreshPendingMeetingRecoveries()
            presentMeetingRecoveryError(error)
        }
    }

    // MARK: - Alerts

    private func presentMeetingRecoveryError(
        _ error: Error,
        recoveries: [MeetingRecordingLockFile] = [],
        environment env: AppEnvironment? = nil,
        source: TelemetryMeetingRecoverySource = .launch
    ) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Meeting Recovery Failed"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if !recoveries.isEmpty, env != nil {
            alert.addButton(withTitle: "Discard Pending")
        }
        let response = alert.runModal()
        guard response == .alertSecondButtonReturn, let env else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.discardMeetingRecoveries(recoveries, environment: env, source: source)
        }
    }

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
