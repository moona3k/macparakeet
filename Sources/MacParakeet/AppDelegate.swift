import AppKit
import OSLog
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    // MARK: - Menu Bar

    private var statusItem: NSStatusItem?

    // MARK: - Windows

    private var mainWindow: NSWindow?

    // MARK: - Services

    private var appEnvironment: AppEnvironment?
    private var hotkeyManager: HotkeyManager?
    private var overlayController: DictationOverlayController?
    private var overlayViewModel: DictationOverlayViewModel?
    private var readyDismissTimer: DispatchWorkItem?
    private var recordingTask: Task<Void, Never>?
    /// Serializes non-recording overlay actions (stop/undo/confirm-cancel) and allows safe cancellation.
    private var overlayActionTask: Task<Void, Never>?
    private var idlePillController: IdlePillController?
    private var idlePillViewModel: IdlePillViewModel?

    /// Monotonic generation id for the dictation UI flow. Any async work must guard this value before
    /// mutating shared UI state or calling into `DictationService` (which is global/shared).
    private var overlayGeneration: Int = 0

    // MARK: - ViewModels

    private let transcriptionViewModel = TranscriptionViewModel()
    private let historyViewModel = DictationHistoryViewModel()
    private let settingsViewModel = SettingsViewModel()
    private let customWordsViewModel = CustomWordsViewModel()
    private let textSnippetsViewModel = TextSnippetsViewModel()
    private let mainWindowState = MainWindowState()
    private let onboardingWindowController = OnboardingWindowController()
    private var onboardingObserver: Any?
    private var settingsObserver: Any?
    private var hotkeyTriggerObserver: Any?
    private var menuBarOnlyModeObserver: Any?
    private var hotkeyMenuItem: NSMenuItem?
    private var reopenOnboardingOnNextActivate = false
    private let dictationLog = Logger(subsystem: "com.macparakeet.app", category: "DictationFlow")

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()
        setupEnvironment()
        setupHotkey()
        observeOpenOnboarding()
        observeOpenSettings()
        observeHotkeyTriggerChange()
        observeMenuBarOnlyModeChange()
        applyActivationPolicyFromSettings()
        showIdlePill()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hideIdlePill()
        hotkeyManager?.stop()
        if let onboardingObserver { NotificationCenter.default.removeObserver(onboardingObserver) }
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        if let hotkeyTriggerObserver { NotificationCenter.default.removeObserver(hotkeyTriggerObserver) }
        if let menuBarOnlyModeObserver { NotificationCenter.default.removeObserver(menuBarOnlyModeObserver) }
        Task {
            await appEnvironment?.sttClient.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window closes — dictation/menu bar features stay available
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock click while no visible windows should reopen/create the main window.
        if !flag {
            openMainWindow()
        } else {
            NSApp.activate(ignoringOtherApps: true)
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

        guard let button = statusItem?.button else { return }

        button.image = BreathWaveIcon.menuBarIcon(pointSize: 18)

        let menu = NSMenu()

        menu.addItem(NSMenuItem(
            title: "Open MacParakeet",
            action: #selector(openMainWindow),
            keyEquivalent: "o"
        ))

        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(
            title: hotkeyMenuTitle,
            action: nil,
            keyEquivalent: ""
        )
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)
        hotkeyMenuItem = hotkeyItem

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Settings...",
            action: #selector(openMainWindowToSettings),
            keyEquivalent: ","
        ))

        menu.addItem(NSMenuItem(
            title: "Quit MacParakeet",
            action: #selector(quitApp),
            keyEquivalent: "q"
        ))

        statusItem?.menu = menu
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
            transcriptionViewModel.configure(
                transcriptionService: env.transcriptionService,
                transcriptionRepo: env.transcriptionRepo,
                llmService: env.llmService
            )
            historyViewModel.configure(dictationRepo: env.dictationRepo)
            settingsViewModel.configure(
                permissionService: env.permissionService,
                dictationRepo: env.dictationRepo,
                transcriptionRepo: env.transcriptionRepo,
                entitlementsService: env.entitlementsService,
                checkoutURL: env.checkoutURL,
                customWordRepo: env.customWordRepo,
                snippetRepo: env.snippetRepo,
                sttClient: env.sttClient,
                llmService: env.llmService
            )
            customWordsViewModel.configure(repo: env.customWordRepo)
            textSnippetsViewModel.configure(repo: env.snippetRepo)

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

    // MARK: - Hotkey

    private func setupHotkey() {
        let manager = HotkeyManager(triggerKey: TriggerKey.current)

        manager.onStartRecording = { [weak self] mode in
            self?.startDictation(mode: mode)
        }

        manager.onStopRecording = { [weak self] in
            self?.stopDictation()
        }

        manager.onCancelRecording = { [weak self] in
            self?.cancelDictation()
        }

        manager.onReadyForSecondTap = { [weak self] in
            self?.showReadyPill()
        }

        manager.onEscapeWhileIdle = { [weak self] in
            self?.dismissOverlayIfError()
        }

        if manager.start() {
            hotkeyManager = manager
        }
    }

    private func refreshHotkeyAfterPermissions() {
        hotkeyManager?.stop()
        hotkeyManager = nil
        setupHotkey()
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
                self?.setupHotkey()
                self?.hotkeyMenuItem?.title = self?.hotkeyMenuTitle ?? ""
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

    private func applyActivationPolicyFromSettings() {
        let mode = settingsViewModel.menuBarOnlyMode ? NSApplication.ActivationPolicy.accessory : .regular
        NSApp.setActivationPolicy(mode)
    }

    private var hotkeyMenuTitle: String {
        "Hotkey: \(TriggerKey.current.displayName) (double-tap / hold)"
    }

    private func maybeShowOnboarding() {
        guard let env = appEnvironment else { return }
        let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
        if !completed {
            showOnboarding(
                permissionService: env.permissionService,
                sttClient: env.sttClient,
                llmService: env.llmService
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
            sttClient: env.sttClient,
            llmService: env.llmService
        )
    }

    private func showOnboarding(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        llmService: any LLMServiceProtocol
    ) {
        onboardingWindowController.show(
            permissionService: permissionService,
            sttClient: sttClient,
            llmService: llmService,
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

    // MARK: - Idle Pill

    private func showIdlePill() {
        guard idlePillController == nil else { return }
        let vm = IdlePillViewModel()
        vm.onStartDictation = { [weak self] in
            self?.startDictation(mode: .persistent)
        }
        idlePillViewModel = vm

        let controller = IdlePillController(viewModel: vm)
        controller.show()
        idlePillController = controller
    }

    private func hideIdlePill() {
        idlePillController?.hide()
        idlePillController = nil
        idlePillViewModel = nil
    }

    @discardableResult
    private func bumpOverlayGeneration() -> Int {
        overlayGeneration += 1
        return overlayGeneration
    }

    // MARK: - Ready Pill

    private func showReadyPill() {
        readyDismissTimer?.cancel()

        hideIdlePill()

        // If the user repeatedly enters "waitingForSecondTap" (e.g., slow/multiple taps),
        // HotkeyManager may call onReadyForSecondTap multiple times. Reuse the same ready
        // overlay instead of creating new panels (which can orphan older ones on screen).
        if let existingVM = overlayViewModel,
           case .ready = existingVM.state,
           overlayController != nil {
            scheduleReadyDismiss(expectedGeneration: overlayGeneration)
            return
        }

        // Defensive: if there's an existing overlay controller, hide it before replacing.
        overlayController?.hide()
        overlayController = nil
        overlayViewModel = nil

        let gen = bumpOverlayGeneration()

        let vm = DictationOverlayViewModel()
        vm.onCancel = { [weak self] in self?.cancelDictation() }
        vm.onStop = { [weak self] in self?.stopDictation() }
        vm.onUndo = { [weak self] in self?.undoCancelDictation() }
        vm.onDismiss = { [weak self] in self?.dismissOverlay() }
        vm.state = .ready
        overlayViewModel = vm

        let controller = DictationOverlayController(viewModel: vm)
        controller.show()
        overlayController = controller

        scheduleReadyDismiss(expectedGeneration: gen)
    }

    private func scheduleReadyDismiss(expectedGeneration: Int) {
        // Auto-dismiss after 800ms if no second tap or hold.
        let timer = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.dismissReadyPill(expectedGeneration: expectedGeneration)
            }
        }
        readyDismissTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800), execute: timer)
    }

    private func dismissReadyPill(expectedGeneration: Int? = nil) {
        readyDismissTimer?.cancel()
        readyDismissTimer = nil

        if let expectedGeneration, expectedGeneration != overlayGeneration {
            return
        }

        // Only dismiss if still in ready state — don't dismiss a recording overlay
        guard let vm = overlayViewModel, case .ready = vm.state else { return }

        overlayController?.hide()
        overlayController = nil
        overlayViewModel = nil
        showIdlePill()
    }

    // MARK: - Dictation Flow

    private func startDictation(mode: FnKeyStateMachine.RecordingMode) {
        guard let env = appEnvironment else { return }

        // Cancel any pending ready dismiss timer
        readyDismissTimer?.cancel()
        readyDismissTimer = nil

        // Starting a new recording should cancel any pending cancel countdown.
        let hadCancelCountdown = cancelTask != nil
        cancelTask?.cancel()
        cancelTask = nil
        if hadCancelCountdown {
            // Prevent the hotkey state machine from being stuck in cancelWindow/blocked.
            hotkeyManager?.resetToIdle()
        }

        hideIdlePill()

        // If we already have a ready pill, keep the current generation so we can reuse it seamlessly.
        // Otherwise bump, which invalidates any prior async work.
        let gen: Int
        if let existingVM = overlayViewModel, case .ready = existingVM.state {
            gen = overlayGeneration
        } else {
            gen = bumpOverlayGeneration()
        }
        dictationLog.debug("startDictation requested mode=\(String(describing: mode), privacy: .public) generation=\(gen)")

        // Cancel old recording task and immediately clean up any overlay it created.
        // Without this, a rapid double-call to startDictation (before the first task
        // reaches its isCancelled guard) leaves an orphaned panel on screen.
        if recordingTask != nil {
            recordingTask?.cancel()
            recordingTask = nil
            overlayController?.hide()
            overlayController = nil
            overlayViewModel = nil
        }

        recordingTask = Task { @MainActor in
            do {
                // Avoid showing the overlay if the user isn't entitled (trial expired).
                try await env.entitlementsService.assertCanTranscribe(now: Date())
            } catch {
                guard self.overlayGeneration == gen else { return }
                self.dismissReadyPill(expectedGeneration: gen)
                self.showIdlePill()
                self.presentEntitlementsAlert(error)
                return
            }

            // Bail if stop/cancel was called while awaiting entitlements
            guard !Task.isCancelled, self.overlayGeneration == gen else { return }

            // Reuse existing overlay if it's in ready state (seamless transition)
            let vm: DictationOverlayViewModel
            if let existingVM = overlayViewModel, case .ready = existingVM.state {
                vm = existingVM
            } else {
                guard self.overlayGeneration == gen else { return }
                vm = DictationOverlayViewModel()
                vm.onCancel = { [weak self] in self?.cancelDictation() }
                vm.onStop = { [weak self] in self?.stopDictation() }
                vm.onUndo = { [weak self] in self?.undoCancelDictation() }
                vm.onDismiss = { [weak self] in self?.dismissOverlay() }
                overlayViewModel = vm

                let controller = DictationOverlayController(viewModel: vm)
                controller.show()
                overlayController = controller
            }

            guard self.overlayGeneration == gen else { return }
            vm.recordingMode = mode
            vm.state = .recording
            vm.startTimer()
            self.dictationLog.debug("recording UI entered generation=\(gen) mode=\(String(describing: mode), privacy: .public)")

            do {
                self.dictationLog.debug("dictationService.startRecording begin generation=\(gen)")
                try await env.dictationService.startRecording()
                let stateAfterStart = await env.dictationService.state
                self.dictationLog.debug(
                    "dictationService.startRecording success generation=\(gen) serviceState=\(self.describeDictationState(stateAfterStart), privacy: .public)"
                )
                guard !Task.isCancelled, self.overlayGeneration == gen else { return }

                // Snapshot settings at start of recording (keeps behavior stable during a recording).
                let (autoStopEnabled, silenceDelay) = (self.settingsViewModel.silenceAutoStop, self.settingsViewModel.silenceDelay)
                let silenceThreshold: Float = 0.03
                var lastNonSilenceAt = Date()
                var didAutoStop = false

                // Update audio level periodically
                while !Task.isCancelled,
                      self.overlayGeneration == gen,
                      case .recording = await env.dictationService.state {
                    let level = await env.dictationService.audioLevel
                    vm.audioLevel = level

                    if autoStopEnabled {
                        let now = Date()
                        if level >= silenceThreshold {
                            lastNonSilenceAt = now
                        } else if !didAutoStop, now.timeIntervalSince(lastNonSilenceAt) >= silenceDelay {
                            didAutoStop = true
                            self.stopDictation()
                            break
                        }
                    }

                    try? await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                self.dictationLog.error("startDictation failed generation=\(gen) error=\(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled, self.overlayGeneration == gen else { return }
                vm.state = .error(error.localizedDescription)
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.overlayGeneration == gen else { return }
                self.dismissOverlay()
            }
        }
    }

    private func stopDictation() {
        dictationLog.debug("stopDictation requested generation=\(self.overlayGeneration)")

        // Stop should cancel any pending cancel countdown.
        cancelTask?.cancel()
        cancelTask = nil

        guard let env = appEnvironment else { return }

        // Edge case: stop during entitlements check (no overlay created yet).
        guard let vm = overlayViewModel else {
            hotkeyManager?.resetToIdle()
            showIdlePill()
            return
        }

        // Capture the controller now — if the user starts a new dictation before
        // our Task finishes, self.overlayController will point to a new overlay
        // and we'd orphan this one on screen.
        let controller = overlayController
        let gen = overlayGeneration
        let taskToCancelAfterStop = recordingTask

        overlayActionTask?.cancel()
        overlayActionTask = Task { @MainActor in
            let stateBeforeStop = await env.dictationService.state
            let readyToStop: Bool
            if case .recording = stateBeforeStop {
                readyToStop = true
            } else {
                dictationLog.debug(
                    "stopDictation waiting for recording generation=\(gen) initialServiceState=\(self.describeDictationState(stateBeforeStop), privacy: .public)"
                )
                readyToStop = await self.waitForServiceRecordingStart(
                    dictationService: env.dictationService,
                    expectedGeneration: gen
                )
            }

            guard readyToStop else {
                self.dictationLog.warning("stopDictation aborted generation=\(gen) service never reached recording")
                taskToCancelAfterStop?.cancel()
                if self.overlayGeneration == gen {
                    self.recordingTask = nil
                    self.hotkeyManager?.resetToIdle()
                    self.showIdlePill()
                }
                controller?.hide()
                if self.overlayController === controller {
                    self.overlayController = nil
                }
                if self.overlayViewModel === vm {
                    self.overlayViewModel = nil
                }
                return
            }

            taskToCancelAfterStop?.cancel()
            if self.overlayGeneration == gen {
                self.recordingTask = nil
            }

            vm.stopTimer()
            vm.state = .processing
            let stateAfterWait = await env.dictationService.state
            self.dictationLog.debug(
                "stopDictation begin generation=\(gen) overlayState=\(self.describeOverlayState(vm.state), privacy: .public) serviceState=\(self.describeDictationState(stateAfterWait), privacy: .public)"
            )

            do {
                var dictation = try await env.dictationService.stopRecording()
                self.dictationLog.debug(
                    "stopDictation success generation=\(gen) rawChars=\(dictation.rawTranscript.count) cleanChars=\(dictation.cleanTranscript?.count ?? 0)"
                )
                vm.state = .success
                // Resign key window so CGEvent paste targets the user's app
                // (needed when stop was triggered by clicking the overlay button).
                controller?.resignKeyWindow()
                // Brief pause so user sees the checkmark before paste
                try? await Task.sleep(for: .milliseconds(200))
                let transcriptToPaste = dictation.cleanTranscript ?? dictation.rawTranscript
                let didAutoPaste = await self.pasteTranscriptWithFallback(
                    transcript: transcriptToPaste,
                    viewModel: vm,
                    clipboardService: env.clipboardService
                )
                if didAutoPaste {
                    if let pastedToApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                        dictation.pastedToApp = pastedToApp
                        dictation.updatedAt = Date()
                        try? env.dictationRepo.save(dictation)
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                } else {
                    try? await Task.sleep(for: .seconds(5))
                }
            } catch where self.isNoSpeechError(error) {
                self.dictationLog.warning("stopDictation no-speech generation=\(gen) error=\(error.localizedDescription, privacy: .public)")
                // Brief "no speech" pill — view's onAppear triggers the bar animation
                vm.noSpeechProgress = 1.0
                vm.state = .noSpeech
                try? await Task.sleep(for: .seconds(3))
            } catch {
                self.dictationLog.error("stopDictation failed generation=\(gen) error=\(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled else { return }
                vm.state = .error(error.localizedDescription)
                try? await Task.sleep(for: .seconds(5))
            }

            guard !Task.isCancelled else { return }

            controller?.hide()
            // Only clear references if they haven't been replaced.
            if self.overlayController === controller {
                self.overlayController = nil
            }
            if self.overlayViewModel === vm {
                self.overlayViewModel = nil
            }
            self.historyViewModel.loadDictations()
            if self.overlayGeneration == gen, self.overlayController == nil {
                self.hotkeyManager?.resetToIdle()
                self.showIdlePill()
            }
            self.dictationLog.debug("stopDictation complete generation=\(gen)")
        }
    }

    private var cancelTask: Task<Void, Never>?

    private func cancelDictation() {
        recordingTask?.cancel()
        recordingTask = nil

        guard let env = appEnvironment else { return }

        // Edge case: cancel during entitlements check (no overlay created yet).
        guard let vm = overlayViewModel else {
            hotkeyManager?.resetToIdle()
            showIdlePill()
            return
        }

        // Cancel in "ready" state should just dismiss back to idle (no audio to cancel).
        if case .ready = vm.state {
            dismissReadyPill()
            hotkeyManager?.resetToIdle()
            return
        }

        // If we're processing (stop/undo), treat cancel as a UI dismiss and let processing finish.
        switch vm.state {
        case .processing, .success, .noSpeech, .error:
            dismissOverlay()
            return
        default:
            break
        }

        // If already in cancel countdown, confirm immediately (Esc pressed again)
        if case .cancelled = vm.state {
            cancelTask?.cancel()
            cancelTask = nil

            let controller = overlayController
            let gen = overlayGeneration

            overlayActionTask?.cancel()
            overlayActionTask = Task { @MainActor in
                guard self.overlayGeneration == gen else { return }
                await env.dictationService.confirmCancel()
                guard self.overlayGeneration == gen else { return }

                self.hotkeyManager?.resetToIdle()
                controller?.hide()
                if self.overlayController === controller {
                    self.overlayController = nil
                }
                if self.overlayViewModel === vm {
                    self.overlayViewModel = nil
                }
                _ = self.bumpOverlayGeneration()
                self.showIdlePill()
            }
            return
        }

        cancelTask?.cancel()
        let controller = overlayController
        let gen = overlayGeneration
        cancelTask = Task { @MainActor in
            guard self.overlayGeneration == gen else { return }

            // Soft cancel immediately: stop capture but keep audio briefly so Undo can proceed.
            await env.dictationService.cancelRecording()

            // Sync state machine — may have been triggered via UI button, not Esc
            // (Esc path already transitions the state machine to cancelWindow.)
            self.hotkeyManager?.notifyCancelledByUI()

            guard self.overlayGeneration == gen else { return }
            vm.stopTimer()
            vm.cancelTimeRemaining = 5.0
            vm.state = .cancelled(timeRemaining: 5.0)

            // Simple 5-second countdown. Only update cancelTimeRemaining (not state
            // enum) to avoid SwiftUI view reconstruction that fights the ring animation.
            for i in stride(from: 4.0, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled {
                    // Callers (confirm/undo) handle their own cleanup, but guarantee
                    // the hotkey is never left stuck in cancelWindow.
                    self.hotkeyManager?.resetToIdle()
                    return
                }
                guard self.overlayGeneration == gen else { return }
                vm.cancelTimeRemaining = i
            }

            // Countdown expired — discard and return to idle UI.
            guard self.overlayGeneration == gen else { return }
            await env.dictationService.confirmCancel()
            guard self.overlayGeneration == gen else { return }
            self.hotkeyManager?.resetToIdle()
            controller?.hide()
            if self.overlayController === controller {
                self.overlayController = nil
            }
            if self.overlayViewModel === vm {
                self.overlayViewModel = nil
            }
            _ = self.bumpOverlayGeneration()
            self.showIdlePill()
        }
    }

    private func undoCancelDictation() {
        guard let env = appEnvironment, let vm = overlayViewModel else { return }

        // Cancel the countdown so it doesn't expire and discard audio.
        cancelTask?.cancel()
        cancelTask = nil

        // Capture the controller now (same race-condition guard as stopDictation).
        let controller = overlayController
        let gen = overlayGeneration

        overlayActionTask?.cancel()
        overlayActionTask = Task { @MainActor in
            vm.stopTimer()
            vm.state = .processing

            do {
                var dictation = try await env.dictationService.undoCancel()
                vm.state = .success
                // Resign key window so CGEvent paste targets the user's app,
                // not the overlay panel (which became key when Undo was clicked).
                controller?.resignKeyWindow()
                // Brief pause so user sees the checkmark before paste
                try? await Task.sleep(for: .milliseconds(200))
                let transcriptToPaste = dictation.cleanTranscript ?? dictation.rawTranscript
                let didAutoPaste = await self.pasteTranscriptWithFallback(
                    transcript: transcriptToPaste,
                    viewModel: vm,
                    clipboardService: env.clipboardService
                )
                if didAutoPaste {
                    if let pastedToApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                        dictation.pastedToApp = pastedToApp
                        dictation.updatedAt = Date()
                        try? env.dictationRepo.save(dictation)
                    }
                    try? await Task.sleep(for: .milliseconds(800))
                } else {
                    try? await Task.sleep(for: .seconds(5))
                }
            } catch where self.isNoSpeechError(error) {
                // Brief "no speech" pill — view's onAppear triggers the bar animation
                vm.noSpeechProgress = 1.0
                vm.state = .noSpeech
                try? await Task.sleep(for: .seconds(3))
            } catch {
                guard !Task.isCancelled else { return }
                vm.state = .error(error.localizedDescription)
                try? await Task.sleep(for: .seconds(5))
            }

            guard !Task.isCancelled else { return }

            if self.overlayGeneration == gen {
                self.hotkeyManager?.resetToIdle()
            }
            controller?.hide()
            if self.overlayController === controller {
                self.overlayController = nil
            }
            if self.overlayViewModel === vm {
                self.overlayViewModel = nil
            }
            self.historyViewModel.loadDictations()
            if self.overlayGeneration == gen, self.overlayController == nil {
                self.showIdlePill()
            }
        }
    }

    private func dismissOverlay() {
        recordingTask?.cancel()
        recordingTask = nil
        cancelTask?.cancel()
        cancelTask = nil
        overlayActionTask?.cancel()
        overlayActionTask = nil
        readyDismissTimer?.cancel()
        readyDismissTimer = nil
        hotkeyManager?.resetToIdle()
        overlayController?.hide()
        overlayController = nil
        overlayViewModel = nil
        _ = bumpOverlayGeneration()
        showIdlePill()
    }

    /// Dismiss the overlay if it's showing an error or no-speech feedback. Called when ESC is
    /// pressed while the state machine is idle (these overlays outlive the recording state).
    private func dismissOverlayIfError() {
        guard let vm = overlayViewModel else { return }
        if case .error = vm.state {
            dismissOverlay()
        } else if case .noSpeech = vm.state {
            dismissOverlay()
        }
    }

    /// Whether the error represents "no speech" (empty transcript or recording too short).
    /// These get the gentle noSpeech pill instead of the full error card.
    private func isNoSpeechError(_ error: Error) -> Bool {
        if let e = error as? DictationServiceError, e == .emptyTranscript { return true }
        if let e = error as? AudioProcessorError, case .insufficientSamples = e { return true }
        return false
    }

    /// Best-effort paste with explicit fallback.
    /// Returns true when auto-paste dispatch succeeded; false when we had to copy only.
    @MainActor
    private func pasteTranscriptWithFallback(
        transcript: String,
        viewModel: DictationOverlayViewModel,
        clipboardService: ClipboardServiceProtocol
    ) async -> Bool {
        do {
            try await clipboardService.pasteText(transcript)
            return true
        } catch {
            await clipboardService.copyToClipboard(transcript)
            viewModel.state = .error("Copied to clipboard. Press Cmd+V.")
            return false
        }
    }

    private func describeDictationState(_ state: DictationState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .recording:
            return "recording"
        case .processing:
            return "processing"
        case .success:
            return "success"
        case .cancelled:
            return "cancelled"
        case .error:
            return "error"
        }
    }

    private func describeOverlayState(_ state: DictationOverlayViewModel.OverlayState) -> String {
        switch state {
        case .ready:
            return "ready"
        case .recording:
            return "recording"
        case .cancelled:
            return "cancelled"
        case .processing:
            return "processing"
        case .success:
            return "success"
        case .noSpeech:
            return "noSpeech"
        case .error:
            return "error"
        }
    }

    private func waitForServiceRecordingStart(
        dictationService: DictationServiceProtocol,
        expectedGeneration: Int,
        timeoutMs: Int = 1200
    ) async -> Bool {
        let pollMs = 50
        let attempts = max(1, timeoutMs / pollMs)
        for _ in 0..<attempts {
            guard overlayGeneration == expectedGeneration else { return false }
            if case .recording = await dictationService.state {
                return true
            }
            try? await Task.sleep(for: .milliseconds(pollMs))
        }
        return false
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


    private func createMainWindow() {
        let contentView = MainWindowView(
            state: mainWindowState,
            transcriptionViewModel: transcriptionViewModel,
            historyViewModel: historyViewModel,
            settingsViewModel: settingsViewModel,
            customWordsViewModel: customWordsViewModel,
            textSnippetsViewModel: textSnippetsViewModel
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

    @objc private func quitApp() {
        NSApp.terminate(nil)
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
}
