import AppKit
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
    private var idlePillController: IdlePillController?
    private var idlePillViewModel: IdlePillViewModel?

    // MARK: - ViewModels

    private let transcriptionViewModel = TranscriptionViewModel()
    private let historyViewModel = DictationHistoryViewModel()
    private let settingsViewModel = SettingsViewModel()
    private let customWordsViewModel = CustomWordsViewModel()
    private let textSnippetsViewModel = TextSnippetsViewModel()
    private let mainWindowState = MainWindowState()
    private let onboardingWindowController = OnboardingWindowController()
    private var onboardingObserver: Any?
    private var hotkeyTriggerObserver: Any?
    private var hotkeyMenuItem: NSMenuItem?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMainMenu()
        setupMenuBar()
        setupEnvironment()
        setupHotkey()
        observeOpenOnboarding()
        observeHotkeyTriggerChange()
        showIdlePill()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hideIdlePill()
        hotkeyManager?.stop()
        if let onboardingObserver { NotificationCenter.default.removeObserver(onboardingObserver) }
        if let hotkeyTriggerObserver { NotificationCenter.default.removeObserver(hotkeyTriggerObserver) }
        Task {
            await appEnvironment?.sttClient.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window closes — we're a menu bar app
        return false
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
                await env.entitlementsService.bootstrapTrialIfNeeded()
                await env.entitlementsService.refreshValidationIfNeeded()
            }

            // Configure view models
            transcriptionViewModel.configure(
                transcriptionService: env.transcriptionService,
                transcriptionRepo: env.transcriptionRepo
            )
            historyViewModel.configure(dictationRepo: env.dictationRepo)
            settingsViewModel.configure(
                permissionService: env.permissionService,
                dictationRepo: env.dictationRepo,
                transcriptionRepo: env.transcriptionRepo,
                entitlementsService: env.entitlementsService,
                checkoutURL: env.checkoutURL,
                customWordRepo: env.customWordRepo,
                snippetRepo: env.snippetRepo
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

    private var hotkeyMenuTitle: String {
        "Hotkey: \(TriggerKey.current.displayName) (double-tap / hold)"
    }

    private func maybeShowOnboarding() {
        guard let env = appEnvironment else { return }
        let completed = UserDefaults.standard.string(forKey: OnboardingViewModel.onboardingCompletedKey) != nil
        if !completed {
            showOnboarding(permissionService: env.permissionService, sttClient: env.sttClient)
        }
    }

    private func showOnboarding() {
        guard let env = appEnvironment else { return }
        showOnboarding(permissionService: env.permissionService, sttClient: env.sttClient)
    }

    private func showOnboarding(permissionService: PermissionServiceProtocol, sttClient: STTClientProtocol) {
        onboardingWindowController.show(
            permissionService: permissionService,
            sttClient: sttClient,
            onFinish: { [weak self] in
                self?.refreshHotkeyAfterPermissions()
            },
            onOpenMainApp: { [weak self] in
                self?.openMainWindow()
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

    // MARK: - Ready Pill

    private func showReadyPill() {
        readyDismissTimer?.cancel()

        hideIdlePill()

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

        // Auto-dismiss after 800ms if no second tap or hold
        let timer = DispatchWorkItem { [weak self] in
            self?.dismissReadyPill()
        }
        readyDismissTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800), execute: timer)
    }

    private func dismissReadyPill() {
        readyDismissTimer?.cancel()
        readyDismissTimer = nil

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

        hideIdlePill()

        recordingTask?.cancel()
        recordingTask = Task {
            do {
                // Avoid showing the overlay if the user isn't entitled (trial expired).
                try await env.entitlementsService.assertCanTranscribe(now: Date())
            } catch {
                await MainActor.run {
                    self.dismissReadyPill()
                    self.showIdlePill()
                    self.presentEntitlementsAlert(error)
                }
                return
            }

            // Bail if stop/cancel was called while awaiting entitlements
            guard !Task.isCancelled else { return }

            // Reuse existing overlay if it's in ready state (seamless transition)
            let vm: DictationOverlayViewModel
            if let existingVM = overlayViewModel, case .ready = existingVM.state {
                vm = existingVM
            } else {
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

            vm.recordingMode = mode
            vm.state = .recording
            vm.startTimer()

            do {
                try await env.dictationService.startRecording()
                guard !Task.isCancelled else { return }

                // Snapshot settings at start of recording (keeps behavior stable during a recording).
                let (autoStopEnabled, silenceDelay) = await MainActor.run {
                    (self.settingsViewModel.silenceAutoStop, self.settingsViewModel.silenceDelay)
                }
                let silenceThreshold: Float = 0.03
                var lastNonSilenceAt = Date()
                var didAutoStop = false

                // Update audio level periodically
                while !Task.isCancelled, case .recording = await env.dictationService.state {
                    let level = await env.dictationService.audioLevel
                    await MainActor.run { vm.audioLevel = level }

                    if autoStopEnabled {
                        let now = Date()
                        if level >= silenceThreshold {
                            lastNonSilenceAt = now
                        } else if !didAutoStop, now.timeIntervalSince(lastNonSilenceAt) >= silenceDelay {
                            didAutoStop = true
                            await MainActor.run { self.stopDictation() }
                            break
                        }
                    }

                    try? await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.state = .error(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.dismissOverlay()
                }
            }
        }
    }

    private func stopDictation() {
        recordingTask?.cancel()
        recordingTask = nil
        guard let env = appEnvironment, let vm = overlayViewModel else { return }

        // Capture the controller now — if the user starts a new dictation before
        // our Task finishes, self.overlayController will point to a new overlay
        // and we'd orphan this one on screen.
        let controller = overlayController

        Task {
            await MainActor.run {
                vm.stopTimer()
                vm.state = .processing
            }

            do {
                var dictation = try await env.dictationService.stopRecording()
                await MainActor.run { vm.state = .success }
                // Brief pause so user sees the checkmark before paste
                try? await Task.sleep(for: .milliseconds(200))
                let pastedToApp = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
                try? await env.clipboardService.pasteText(dictation.cleanTranscript ?? dictation.rawTranscript)
                if let pastedToApp {
                    dictation.pastedToApp = pastedToApp
                    dictation.updatedAt = Date()
                    try? env.dictationRepo.save(dictation)
                }
                try? await Task.sleep(for: .milliseconds(800))
            } catch {
                await MainActor.run {
                    vm.state = .error(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(5))
            }

            await MainActor.run {
                controller?.hide()
                // Only nil out self.overlayController if it hasn't been replaced
                if self.overlayController === controller {
                    self.overlayController = nil
                }
                self.historyViewModel.loadDictations()
                if self.overlayController == nil {
                    self.showIdlePill()
                }
            }
        }
    }

    private var cancelTask: Task<Void, Never>?

    private func cancelDictation() {
        recordingTask?.cancel()
        recordingTask = nil
        guard let env = appEnvironment, let vm = overlayViewModel else { return }

        // If already in cancel countdown, confirm immediately (Esc pressed again)
        if case .cancelled = vm.state {
            cancelTask?.cancel()
            cancelTask = nil
            Task {
                await env.dictationService.confirmCancel()
                await MainActor.run {
                    self.hotkeyManager?.resetToIdle()
                    self.overlayController?.hide()
                    self.overlayController = nil
                    self.showIdlePill()
                }
            }
            return
        }

        cancelTask?.cancel()
        cancelTask = Task {
            // Soft cancel immediately: stop capture but keep audio briefly so Undo can proceed.
            await env.dictationService.cancelRecording()

            // Sync state machine — may have been triggered via UI button, not Esc
            // (Esc path already transitions the state machine to cancelWindow.)
            self.hotkeyManager?.notifyCancelledByUI()

            await MainActor.run {
                vm.stopTimer()
                vm.cancelTimeRemaining = 5.0
                vm.state = .cancelled(timeRemaining: 5.0)
            }

            // Simple 5-second countdown. Only update cancelTimeRemaining (not state
            // enum) to avoid SwiftUI view reconstruction that fights the ring animation.
            for i in stride(from: 4.0, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run { vm.cancelTimeRemaining = i }
            }

            // Countdown expired — discard and return to idle UI.
            guard !Task.isCancelled else { return }
            await env.dictationService.confirmCancel()
            await MainActor.run {
                self.hotkeyManager?.resetToIdle()
                self.overlayController?.hide()
                self.overlayController = nil
                self.showIdlePill()
            }
        }
    }

    private func undoCancelDictation() {
        guard let env = appEnvironment, let vm = overlayViewModel else { return }

        // Cancel the countdown so it doesn't expire and discard audio.
        cancelTask?.cancel()
        cancelTask = nil

        // Capture the controller now (same race-condition guard as stopDictation).
        let controller = overlayController

        Task {
            await MainActor.run {
                vm.stopTimer()
                vm.state = .processing
            }

            do {
                var dictation = try await env.dictationService.undoCancel()
                await MainActor.run { vm.state = .success }
                // Brief pause so user sees the checkmark before paste
                try? await Task.sleep(for: .milliseconds(200))
                let pastedToApp = await MainActor.run { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
                try? await env.clipboardService.pasteText(dictation.cleanTranscript ?? dictation.rawTranscript)
                if let pastedToApp {
                    dictation.pastedToApp = pastedToApp
                    dictation.updatedAt = Date()
                    try? env.dictationRepo.save(dictation)
                }
                try? await Task.sleep(for: .milliseconds(800))
            } catch {
                await MainActor.run {
                    vm.state = .error(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(5))
            }

            await MainActor.run {
                self.hotkeyManager?.resetToIdle()
                controller?.hide()
                if self.overlayController === controller {
                    self.overlayController = nil
                }
                self.historyViewModel.loadDictations()
                if self.overlayController == nil {
                    self.showIdlePill()
                }
            }
        }
    }

    private func dismissOverlay() {
        recordingTask?.cancel()
        recordingTask = nil
        hotkeyManager?.resetToIdle()
        overlayController?.hide()
        overlayController = nil
        overlayViewModel = nil
        showIdlePill()
    }

    // MARK: - Window Management

    @objc private func openMainWindow() {
        if mainWindow == nil {
            createMainWindow()
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openMainWindowToSettings() {
        mainWindowState.selectedItem = .settings
        openMainWindow()
    }

    // NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window === mainWindow else { return }

        // Main window closing — hide dock icon, stay in menu bar
        NSApp.setActivationPolicy(.accessory)
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
        NSApp.setActivationPolicy(.regular)
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
