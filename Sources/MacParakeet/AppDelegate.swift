import AppKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // MARK: - Menu Bar

    private var statusItem: NSStatusItem?

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

    // MARK: - Windows

    private var mainWindow: NSWindow?

    // MARK: - Services

    private var appEnvironment: AppEnvironment?
    private var hotkeyManager: HotkeyManager?
    private var meetingHotkeyManager: GlobalShortcutManager?
    private var dictationFlowCoordinator: DictationFlowCoordinator?
    private var meetingRecordingFlowCoordinator: MeetingRecordingFlowCoordinator?

    // MARK: - ViewModels

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
    private var onboardingObserver: Any?
    private var settingsObserver: Any?
    private var hotkeyTriggerObserver: Any?
    private var meetingHotkeyTriggerObserver: Any?
    private var menuBarOnlyModeObserver: Any?
    private var showIdlePillObserver: Any?
    private var hotkeyMenuItem: NSMenuItem?
    private lazy var youtubeInputController = YouTubeInputPanelController(
        transcriptionViewModel: transcriptionViewModel
    )
    private var pasteLastMenuItem: NSMenuItem?
    private var recentDictationsMenuItem: NSMenuItem?
    private var recordMeetingMenuItem: NSMenuItem?
    private var reopenOnboardingOnNextActivate = false
    private var hasPresentedHotkeyUnavailableAlert = false

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isRunningFromDiskImage() {
            showMoveToApplicationsAlert()
            return
        }
        setupMainMenu()
        setupMenuBar()
        setupEnvironment()
        setupHotkey()
        setupMeetingHotkey()
        observeOpenOnboarding()
        observeOpenSettings()
        observeHotkeyTriggerChange()
        observeMeetingHotkeyTriggerChange()
        observeMenuBarOnlyModeChange()
        observeShowIdlePillChange()
        applyActivationPolicyFromSettings()
        dictationFlowCoordinator?.showIdlePill()
        setupDiscoverContent()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Telemetry.flushForTermination() is handled by TelemetryService's own
        // NSApplicationWillTerminateNotification observer — calling it here too
        // would send duplicate appQuit events and double the termination delay.
        dictationFlowCoordinator?.hideIdlePill()
        hotkeyManager?.stop()
        meetingHotkeyManager?.stop()
        if let onboardingObserver { NotificationCenter.default.removeObserver(onboardingObserver) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let hotkeyTriggerObserver { NotificationCenter.default.removeObserver(hotkeyTriggerObserver) }
        if let meetingHotkeyTriggerObserver { NotificationCenter.default.removeObserver(meetingHotkeyTriggerObserver) }
        if let menuBarOnlyModeObserver { NotificationCenter.default.removeObserver(menuBarOnlyModeObserver) }
        if let showIdlePillObserver { NotificationCenter.default.removeObserver(showIdlePillObserver) }
        // Block briefly for STT cleanup (ANE/CoreML resource release).
        // Must use Task.detached — a plain Task inherits @MainActor context and would
        // deadlock because the main thread is blocked by semaphore.wait below.
        let sttScheduler = appEnvironment?.sttScheduler
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await sttScheduler?.shutdown()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 2.0)
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window closes — dictation/menu bar features stay available
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        // Overlay panels (idle/recording pills) are NSWindows and make the `hasVisibleWindows`
        // flag unreliable for Dock reopen. Only treat primary app windows as visible here.
        if hasVisiblePrimaryWindow {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            openMainWindow()
        }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let openItem = NSMenuItem(
            title: "Open MacParakeet",
            action: #selector(openMainWindow),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(openMainWindowToSettings),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit MacParakeet",
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    // MARK: - Main Menu (enables Cmd+A/C/V/X in text fields)

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()

        let aboutItem = NSMenuItem(
            title: "About MacParakeet",
            action: #selector(showAboutPanel),
            keyEquivalent: ""
        )
        aboutItem.target = self
        appMenu.addItem(aboutItem)
        appMenu.addItem(NSMenuItem.separator())

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        appMenu.addItem(checkForUpdatesItem)
        appMenu.addItem(NSMenuItem.separator())

        appMenu.addItem(NSMenuItem(title: "Quit MacParakeet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Edit menu — required for text field keyboard shortcuts
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let statusItem = statusItem,
              let button = statusItem.button else { return }

        button.image = BreathWaveIcon.menuBarIcon(pointSize: 18)

        let dropView = MenuBarDropView(frame: button.bounds)
        dropView.onDrop = { [weak self] url in
            Task { @MainActor in
                self?.openMainWindow()
                self?.transcriptionViewModel.transcribeFile(url: url)
                SoundManager.shared.play(.fileDropped)
            }
        }
        button.addSubview(dropView)

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self

        menu.addItem(NSMenuItem(
            title: "Open MacParakeet",
            action: #selector(openMainWindow),
            keyEquivalent: "o"
        ))

        menu.addItem(NSMenuItem.separator())

        // Paste Last Dictation
        let pasteItem = NSMenuItem(
            title: "Paste Last Dictation",
            action: #selector(pasteLastDictation),
            keyEquivalent: ""
        )
        pasteItem.isEnabled = false
        menu.addItem(pasteItem)
        pasteLastMenuItem = pasteItem

        // Recent Dictations submenu
        let recentItem = NSMenuItem(
            title: "Recent Dictations",
            action: nil,
            keyEquivalent: ""
        )
        recentItem.submenu = NSMenu()
        recentItem.isHidden = true
        menu.addItem(recentItem)
        recentDictationsMenuItem = recentItem

        menu.addItem(NSMenuItem.separator())

        // Transcribe actions
        menu.addItem(NSMenuItem(
            title: "Transcribe File...",
            action: #selector(transcribeFileFromMenu),
            keyEquivalent: ""
        ))

        menu.addItem(NSMenuItem(
            title: "Transcribe from YouTube...",
            action: #selector(transcribeFromYouTubeMenu),
            keyEquivalent: ""
        ))

        let recordMeetingItem = NSMenuItem(
            title: "Record Meeting",
            action: #selector(toggleMeetingRecordingFromMenu),
            keyEquivalent: ""
        )
        recordMeetingItem.target = self
        menu.addItem(recordMeetingItem)
        recordMeetingMenuItem = recordMeetingItem

        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(
            title: hotkeyMenuTitle,
            action: nil,
            keyEquivalent: ""
        )
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)
        hotkeyMenuItem = hotkeyItem

        menu.addItem(NSMenuItem(
            title: "Settings...",
            action: #selector(openMainWindowToSettings),
            keyEquivalent: ","
        ))

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for Updates...",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = updaterController
        menu.addItem(checkForUpdatesItem)

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit MacParakeet",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
    }

    // MARK: - Environment Setup

    private func setupEnvironment() {
        do {
            let env = try AppEnvironment()
            appEnvironment = env

            Task {
                // Only bootstrap trial if onboarding is already completed (returning user).
                // For new users, trial starts at onboarding completion — not during setup.
                let onboardingDone = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
                if onboardingDone {
                    await env.entitlementsService.bootstrapTrialIfNeeded()
                }
                await env.entitlementsService.refreshValidationIfNeeded()
            }

            // Configure view models
            let hasLLMConfig = (try? env.llmConfigStore.loadConfig()) != nil
            transcriptionViewModel.configure(
                transcriptionService: env.transcriptionService,
                transcriptionRepo: env.transcriptionRepo,
                llmService: hasLLMConfig ? env.llmService : nil,
                configStore: env.llmConfigStore,
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
            settingsViewModel.onDictationsCleared = { [weak self] in
                self?.historyViewModel.loadDictations()
            }
            llmSettingsViewModel.onConfigurationChanged = { [weak self] in
                self?.refreshLLMAvailability()
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
            transcriptionViewModel.onTranscribingChanged = { [weak self] _ in
                self?.resolveAndUpdateMenuBarIcon()
            }

            let coordinator = DictationFlowCoordinator(
                dictationService: env.dictationService,
                clipboardService: env.clipboardService,
                entitlementsService: env.entitlementsService,
                dictationRepo: env.dictationRepo,
                settingsViewModel: settingsViewModel,
                shouldSuppressIdlePill: { [weak self] in
                    self?.meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true
                },
                onMenuBarIconUpdate: { [weak self] _ in self?.resolveAndUpdateMenuBarIcon() },
                onHistoryReload: { [weak self] in self?.historyViewModel.loadDictations() },
                onPresentEntitlementsAlert: { [weak self] error in self?.presentEntitlementsAlert(error) }
            )
            dictationFlowCoordinator = coordinator

            let meetingCoordinator = MeetingRecordingFlowCoordinator(
                meetingRecordingService: env.meetingRecordingService,
                transcriptionService: env.transcriptionService,
                permissionService: env.permissionService,
                onMenuBarIconUpdate: { [weak self] _ in self?.resolveAndUpdateMenuBarIcon() },
                onTranscriptionReady: { [weak self] transcription in
                    guard let self else { return }
                    self.transcriptionViewModel.presentCompletedTranscription(transcription, autoSave: true)
                    self.libraryViewModel.loadTranscriptions()
                    self.meetingsViewModel.loadTranscriptions()
                    self.mainWindowState.navigateToTranscription(from: .meetings)
                    self.openMainWindow()
                },
                onRecordingBegan: { [weak self] in
                    self?.dictationFlowCoordinator?.hideIdlePill()
                },
                onFlowReturnedToIdle: { [weak self] in
                    guard self?.dictationFlowCoordinator?.isDictationActive != true else { return }
                    self?.dictationFlowCoordinator?.showIdlePill()
                }
            )
            meetingRecordingFlowCoordinator = meetingCoordinator

            maybeShowOnboarding()
        } catch {
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
    }

    private func setupDiscoverContent() {
        guard let fallbackURL = Bundle.module.url(forResource: "discover-fallback", withExtension: "json"),
              let data = try? Data(contentsOf: fallbackURL) else { return }
        let service = DiscoverService(fallbackData: data)
        discoverViewModel.configure(service: service)
        discoverViewModel.loadCached()
        discoverViewModel.refreshInBackground()
    }

    private func refreshLLMAvailability() {
        guard let env = appEnvironment else { return }
        let hasConfig = (try? env.llmConfigStore.loadConfig()) != nil
        let service: LLMService? = hasConfig ? env.llmService : nil
        transcriptionViewModel.updateLLMAvailability(hasConfig, llmService: service)
        chatViewModel.updateLLMService(service)
        promptResultsViewModel.updateLLMService(service)
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        let manager = HotkeyManager(trigger: HotkeyTrigger.current)

        manager.onStartRecording = { [weak self] mode in
            self?.dictationFlowCoordinator?.startDictation(mode: mode, trigger: .hotkey)
        }

        manager.onStopRecording = { [weak self] in
            self?.dictationFlowCoordinator?.stopDictation()
        }

        manager.onCancelRecording = { [weak self] in
            self?.dictationFlowCoordinator?.cancelDictation(reason: .escape)
        }

        manager.onDiscardRecording = { [weak self] showReadyPill in
            self?.dictationFlowCoordinator?.discardProvisionalRecording(showReadyPill: showReadyPill)
        }

        manager.onReadyForSecondTap = { [weak self] in
            self?.dictationFlowCoordinator?.showReadyPill()
        }

        manager.onEscapeWhileIdle = { [weak self] in
            self?.dictationFlowCoordinator?.dismissOverlayIfError()
        }

        if manager.start() {
            hotkeyManager = manager
            dictationFlowCoordinator?.hotkeyManager = manager
            hasPresentedHotkeyUnavailableAlert = false
        } else {
            hotkeyManager = nil
            dictationFlowCoordinator?.hotkeyManager = nil
            presentHotkeyUnavailableAlertIfNeeded()
        }
    }

    private func setupMeetingHotkey() {
        guard settingsViewModel.meetingHotkeyTrigger != settingsViewModel.hotkeyTrigger else {
            meetingHotkeyManager = nil
            return
        }

        let manager = GlobalShortcutManager(trigger: settingsViewModel.meetingHotkeyTrigger)
        manager.onTrigger = { [weak self] in
            Task { @MainActor in
                self?.toggleMeetingRecording(originatesFromWindow: false)
            }
        }

        if manager.start() {
            meetingHotkeyManager = manager
            hasPresentedHotkeyUnavailableAlert = false
        } else {
            meetingHotkeyManager = nil
            presentHotkeyUnavailableAlertIfNeeded()
        }
    }

    private func refreshHotkeyAfterPermissions() {
        hotkeyManager?.stop()
        meetingHotkeyManager?.stop()
        hotkeyManager = nil
        meetingHotkeyManager = nil
        setupHotkey()
        setupMeetingHotkey()
    }

    private func observeOpenOnboarding() {
        onboardingObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetOpenOnboarding,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.showOnboarding()
            }
        }
    }

    private func observeHotkeyTriggerChange() {
        hotkeyTriggerObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetHotkeyTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.hotkeyManager?.stop()
                self?.hotkeyManager = nil
                self?.meetingHotkeyManager?.stop()
                self?.meetingHotkeyManager = nil
                self?.setupHotkey()
                self?.setupMeetingHotkey()
                self?.hotkeyMenuItem?.title = self?.hotkeyMenuTitle ?? ""
            }
        }
    }

    private func observeMeetingHotkeyTriggerChange() {
        meetingHotkeyTriggerObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetMeetingHotkeyTriggerDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.meetingHotkeyManager?.stop()
                self?.meetingHotkeyManager = nil
                self?.setupMeetingHotkey()
            }
        }
    }

    private func observeMenuBarOnlyModeChange() {
        menuBarOnlyModeObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetMenuBarOnlyModeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyActivationPolicyFromSettings()
            }
        }
    }

    private func observeShowIdlePillChange() {
        showIdlePillObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetShowIdlePillDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.settingsViewModel.showIdlePill {
                    self.dictationFlowCoordinator?.showIdlePill()
                } else {
                    self.dictationFlowCoordinator?.hideIdlePill()
                }
            }
        }
    }

    private func applyActivationPolicyFromSettings() {
        let menuBarOnly = settingsViewModel.menuBarOnlyMode
        let wasMainWindowVisible = mainWindow?.isVisible ?? false
        let mode: NSApplication.ActivationPolicy = menuBarOnly ? .accessory : .regular
        NSApp.setActivationPolicy(mode)

        // macOS hides all windows when switching to .accessory policy.
        // Re-show the main window so the user isn't surprised by it disappearing.
        if menuBarOnly && wasMainWindowVisible {
            mainWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private var hotkeyMenuTitle: String {
        "Hotkey: \(HotkeyTrigger.current.displayName) (double-tap / hold)"
    }

    private func maybeShowOnboarding() {
        guard let env = appEnvironment else { return }
        let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
        if !completed {
            showOnboarding(
                permissionService: env.permissionService,
                sttClient: env.sttScheduler,
                diarizationService: env.diarizationService
            )
        }
    }

    private func observeOpenSettings() {
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetOpenSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.openMainWindowToSettings()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard reopenOnboardingOnNextActivate else { return }
        maybeShowOnboarding()
    }

    private func showOnboarding() {
        guard let env = appEnvironment else { return }
        showOnboarding(
            permissionService: env.permissionService,
            sttClient: env.sttScheduler,
            diarizationService: env.diarizationService
        )
    }

    private func showOnboarding(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        diarizationService: DiarizationServiceProtocol? = nil
    ) {
        onboardingWindowController.show(
            permissionService: permissionService,
            sttClient: sttClient,
            diarizationService: diarizationService,
            onFinish: { [weak self] in
                self?.reopenOnboardingOnNextActivate = false
                self?.refreshHotkeyAfterPermissions()
                // Start the 7-day trial now that onboarding is complete —
                // user doesn't lose trial days to permission setup.
                if let env = self?.appEnvironment {
                    Task { await env.entitlementsService.bootstrapTrialIfNeeded() }
                }
            },
            onOpenMainApp: { [weak self] in
                self?.openMainWindow()
            },
            onOpenSettings: {
                NotificationCenter.default.post(name: .macParakeetOpenSettings, object: nil)
            },
            onIncompleteDismiss: { [weak self] in
                self?.reopenOnboardingOnNextActivate = true
            }
        )
    }

    // MARK: - Menu Bar Icon State

    /// Priority-based menu bar icon resolver (ADR-015).
    /// Recording (meeting or dictation) > file transcription > idle.
    private func resolveAndUpdateMenuBarIcon() {
        if meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true {
            updateMenuBarIcon(state: .recording)
        } else if dictationFlowCoordinator?.isDictationActive == true {
            updateMenuBarIcon(state: .recording)
        } else if transcriptionViewModel.isTranscribing {
            updateMenuBarIcon(state: .processing)
        } else {
            updateMenuBarIcon(state: .idle)
        }
    }

    private func updateMenuBarIcon(state: BreathWaveIcon.MenuBarState) {
        statusItem?.button?.image = BreathWaveIcon.menuBarIcon(pointSize: 18, state: state)
    }

    // MARK: - Dynamic Dock Icon (Menu Bar Only Mode)

    /// Show dock icon temporarily when the main window is open in menu-bar-only mode.
    private func showDockIconIfNeeded() {
        guard settingsViewModel.menuBarOnlyMode else { return }
        NSApp.setActivationPolicy(.regular)
    }

    /// Hide dock icon when the main window closes in menu-bar-only mode.
    private func hideDockIconIfNeeded() {
        guard settingsViewModel.menuBarOnlyMode else { return }
        // Only hide if no primary windows are visible
        guard !hasVisiblePrimaryWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    private var hasVisiblePrimaryWindow: Bool {
        (mainWindow?.isVisible ?? false) || onboardingWindowController.isVisible
    }

    // MARK: - Window Management

    @objc private func openMainWindow() {
        if mainWindow == nil {
            createMainWindow()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openMainWindowToSettings() {
        mainWindowState.selectedItem = .settings
        openMainWindow()
    }

    @objc private func pasteLastDictation() {
        guard let env = appEnvironment else { return }
        Task {
            guard let dictation = (try? env.dictationRepo.fetchAll(limit: 1))?.first else { return }
            let text = dictation.cleanTranscript ?? dictation.rawTranscript
            await pasteFromMenu(text: text, clipboardService: env.clipboardService)
        }
    }

    @objc private func pasteRecentDictation(_ sender: NSMenuItem) {
        guard let env = appEnvironment,
              let id = sender.representedObject as? UUID else { return }
        Task {
            guard let dictation = try? env.dictationRepo.fetch(id: id) else { return }
            let text = dictation.cleanTranscript ?? dictation.rawTranscript
            await pasteFromMenu(text: text, clipboardService: env.clipboardService)
        }
    }

    /// Resign menu-bar focus, wait for the target app to regain focus, then paste.
    private func pasteFromMenu(text: String, clipboardService: ClipboardServiceProtocol) async {
        NSApp.deactivate()
        try? await Task.sleep(for: .milliseconds(200))
        do {
            try await clipboardService.pasteText(text)
        } catch {
            await clipboardService.copyToClipboard(text)
        }
    }

    @objc private func transcribeFileFromMenu() {
        guard appEnvironment != nil else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AudioFileConverter.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        if panel.runModal() == .OK, let url = panel.url {
            openMainWindow()
            transcriptionViewModel.transcribeFile(url: url)
            SoundManager.shared.play(.fileDropped)
        }
    }

    @objc private func transcribeFromYouTubeMenu() {
        guard appEnvironment != nil else { return }
        youtubeInputController.show()
    }

    @objc private func toggleMeetingRecordingFromMenu() {
        toggleMeetingRecording(originatesFromWindow: false)
    }

    private func toggleMeetingRecording(originatesFromWindow: Bool) {
        guard appEnvironment != nil else { return }
        if meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true {
            meetingRecordingFlowCoordinator?.toggleRecording()
            return
        }

        if originatesFromWindow {
            openMainWindow()
            mainWindowState.selectedItem = .meetings
        }
        meetingRecordingFlowCoordinator?.toggleRecording()
    }

    private func rebuildRecentDictationsSubmenu(with dictations: [Dictation]) {
        guard let recentItem = recentDictationsMenuItem else { return }
        recentItem.isHidden = dictations.isEmpty

        let submenu = NSMenu()
        for dictation in dictations {
            let text = (dictation.cleanTranscript ?? dictation.rawTranscript)
                .replacingOccurrences(of: "\n", with: " ")
            let truncated = text.count > 40 ? String(text.prefix(40)) + "…" : text
            let item = NSMenuItem(
                title: truncated,
                action: #selector(pasteRecentDictation(_:)),
                keyEquivalent: ""
            )
            item.representedObject = dictation.id
            submenu.addItem(item)
        }
        recentItem.submenu = submenu
    }

    private func createMainWindow() {
        let contentView = MainWindowView(
            state: mainWindowState,
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
            updater: updaterController.updater,
            onRecordMeeting: { [weak self] in
                self?.toggleMeetingRecording(originatesFromWindow: true)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: DesignSystem.Layout.sidebarMinWidth + DesignSystem.Layout.contentMinWidth,
                height: DesignSystem.Layout.windowMinHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "MacParakeet"
        window.center()
        window.setFrameAutosaveName("MainWindow")
        window.minSize = NSSize(
            width: DesignSystem.Layout.sidebarMinWidth + DesignSystem.Layout.contentMinWidth,
            height: DesignSystem.Layout.windowMinHeight
        )
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: contentView)
        window.delegate = self
        window.isReleasedWhenClosed = false

        mainWindow = window
    }

    @objc private func showAboutPanel() {
        let repoLink = "https://github.com/moona3k/macparakeet"
        let credits = NSMutableAttributedString()

        let style = NSMutableParagraphStyle()
        style.alignment = .center

        let normalAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .paragraphStyle: style,
        ]
        let linkAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .link: URL(string: repoLink)!,
            .paragraphStyle: style,
        ]

        credits.append(NSAttributedString(string: "Free and open source (GPL-3.0)\n", attributes: normalAttrs))
        credits.append(NSAttributedString(string: repoLink, attributes: linkAttrs))

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
        ])
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        showDockIconIfNeeded()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        // Delay slightly so macOS finishes closing the window before we check visibility
        DispatchQueue.main.async { [weak self] in
            self?.hideDockIconIfNeeded()
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

        let resp = alert.runModal()
        if resp == .alertFirstButtonReturn {
            openMainWindowToSettings()
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
            openMainWindowToSettings()
        }
        #endif
    }

}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let env = appEnvironment else {
            pasteLastMenuItem?.isEnabled = false
            recentDictationsMenuItem?.isHidden = true
            return
        }
        let dictations = (try? env.dictationRepo.fetchAll(limit: 5)) ?? []
        pasteLastMenuItem?.isEnabled = !dictations.isEmpty
        rebuildRecentDictationsSubmenu(with: dictations)
        recordMeetingMenuItem?.title = meetingRecordingFlowCoordinator?.isMeetingRecordingActive == true
            ? "Stop Meeting Recording"
            : "Record Meeting"
    }
}
