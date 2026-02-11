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
    private var idlePillController: IdlePillController?
    private var idlePillViewModel: IdlePillViewModel?

    // MARK: - ViewModels

    private let transcriptionViewModel = TranscriptionViewModel()
    private let historyViewModel = DictationHistoryViewModel()
    private let settingsViewModel = SettingsViewModel()
    private let mainWindowState = MainWindowState()
    private let onboardingWindowController = OnboardingWindowController()
    private var onboardingObserver: Any?

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupEnvironment()
        setupHotkey()
        observeOpenOnboarding()
        showIdlePill()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hideIdlePill()
        hotkeyManager?.stop()
        if let onboardingObserver { NotificationCenter.default.removeObserver(onboardingObserver) }
        Task {
            await appEnvironment?.sttClient.shutdown()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Don't quit when window closes — we're a menu bar app
        return false
    }

    // MARK: - Menu Bar Setup

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MacParakeet")?
            .withSymbolConfiguration(config) {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = "MP"
        }

        let menu = NSMenu()

        menu.addItem(NSMenuItem(
            title: "Open MacParakeet",
            action: #selector(openMainWindow),
            keyEquivalent: "o"
        ))

        menu.addItem(NSMenuItem.separator())

        let hotkeyItem = NSMenuItem(
            title: "Hotkey: Fn (double-tap / hold)",
            action: nil,
            keyEquivalent: ""
        )
        hotkeyItem.isEnabled = false
        menu.addItem(hotkeyItem)

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
                entitlementsService: env.entitlementsService,
                checkoutURL: env.checkoutURL
            )

            maybeShowOnboarding()
        } catch {
            print("Failed to initialize app: \(error)")
        }
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        let manager = HotkeyManager()

        manager.onStartRecording = { [weak self] mode in
            self?.startDictation(mode: mode)
        }

        manager.onStopRecording = { [weak self] in
            self?.stopDictation()
        }

        manager.onCancelRecording = { [weak self] in
            self?.cancelDictation()
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

    // MARK: - Dictation Flow

    private func startDictation(mode: FnKeyStateMachine.RecordingMode) {
        guard let env = appEnvironment else { return }

        hideIdlePill()

        Task {
            do {
                // Avoid showing the overlay if the user isn't entitled (trial expired).
                try await env.entitlementsService.assertCanTranscribe(now: Date())
            } catch {
                await MainActor.run {
                    self.showIdlePill()
                    self.presentEntitlementsAlert(error)
                }
                return
            }

            let vm = DictationOverlayViewModel()
            vm.onCancel = { [weak self] in self?.cancelDictation() }
            vm.onStop = { [weak self] in self?.stopDictation() }
            vm.onUndo = { [weak self] in self?.undoCancelDictation() }
            vm.onDismiss = { [weak self] in self?.dismissOverlay() }
            vm.state = .recording
            vm.startTimer()
            overlayViewModel = vm

            let controller = DictationOverlayController(viewModel: vm)
            controller.show()
            overlayController = controller

            do {
                try await env.dictationService.startRecording()

                // Snapshot settings at start of recording (keeps behavior stable during a recording).
                let (autoStopEnabled, silenceDelay) = await MainActor.run {
                    (self.settingsViewModel.silenceAutoStop, self.settingsViewModel.silenceDelay)
                }
                let silenceThreshold: Float = 0.03
                var lastNonSilenceAt = Date()
                var didAutoStop = false

                // Update audio level periodically
                while case .recording = await env.dictationService.state {
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
                await MainActor.run {
                    vm.state = .error(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(5))
                await MainActor.run {
                    self.dismissOverlay()
                }
            }
        }
    }

    private func stopDictation() {
        guard let env = appEnvironment, let vm = overlayViewModel else { return }

        Task {
            await MainActor.run {
                vm.stopTimer()
                vm.state = .processing
            }

            do {
                let dictation = try await env.dictationService.stopRecording()
                await MainActor.run { vm.state = .success }
                // Brief pause so user sees the checkmark before paste
                try? await Task.sleep(for: .milliseconds(200))
                try? await env.clipboardService.pasteText(dictation.rawTranscript)
                try? await Task.sleep(for: .milliseconds(800))
            } catch {
                await MainActor.run {
                    vm.state = .error(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(5))
            }

            await MainActor.run {
                self.overlayController?.hide()
                self.overlayController = nil
                self.historyViewModel.loadDictations()
                self.showIdlePill()
            }
        }
    }

    private var cancelTask: Task<Void, Never>?

    private func cancelDictation() {
        guard let env = appEnvironment, let vm = overlayViewModel else { return }

        // Sync state machine — may have been triggered via UI button, not Esc
        hotkeyManager?.notifyCancelledByUI()

        cancelTask?.cancel()
        cancelTask = Task {
            // Don't cancel the service yet — audio keeps recording during undo window
            await MainActor.run {
                vm.stopTimer()
                vm.state = .cancelled(timeRemaining: 5.0)
            }

            // Countdown
            for i in stride(from: 4.0, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    vm.state = .cancelled(timeRemaining: i)
                }
            }

            // Countdown expired — NOW actually discard the recording
            guard !Task.isCancelled else { return }
            await env.dictationService.cancelRecording()
            await MainActor.run {
                self.hotkeyManager?.resetToIdle()
                self.overlayController?.hide()
                self.overlayController = nil
                self.showIdlePill()
            }
        }
    }

    private func undoCancelDictation() {
        // Cancel the countdown so it doesn't expire and discard audio
        cancelTask?.cancel()
        cancelTask = nil

        // Sync state machine back to recording mode
        hotkeyManager?.resumeRecording(mode: .persistent)

        // Resume recording — audio was never interrupted, just switch overlay back
        overlayViewModel?.state = .recording
        overlayViewModel?.resumeTimer()
    }

    private func dismissOverlay() {
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
            settingsViewModel: settingsViewModel
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
