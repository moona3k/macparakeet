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

    // MARK: - ViewModels

    private let transcriptionViewModel = TranscriptionViewModel()
    private let historyViewModel = DictationHistoryViewModel()
    private let settingsViewModel = SettingsViewModel()

    // MARK: - App Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        setupEnvironment()
        setupHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager?.stop()
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

        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "MacParakeet") {
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

            // Configure view models
            transcriptionViewModel.configure(
                transcriptionService: env.transcriptionService,
                transcriptionRepo: env.transcriptionRepo
            )
            historyViewModel.configure(dictationRepo: env.dictationRepo)
            settingsViewModel.configure(
                permissionService: env.permissionService,
                dictationRepo: env.dictationRepo
            )
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

    // MARK: - Dictation Flow

    private func startDictation(mode: FnKeyStateMachine.RecordingMode) {
        guard let env = appEnvironment else { return }

        let vm = DictationOverlayViewModel()
        vm.onCancel = { [weak self] in self?.cancelDictation() }
        vm.onStop = { [weak self] in self?.stopDictation() }
        vm.onUndo = { [weak self] in self?.undoCancelDictation() }
        vm.state = .recording
        vm.startTimer()
        overlayViewModel = vm

        let controller = DictationOverlayController(viewModel: vm)
        controller.show()
        overlayController = controller

        Task {
            do {
                try await env.dictationService.startRecording()

                // Update audio level periodically
                while case .recording = await env.dictationService.state {
                    let level = await env.dictationService.audioLevel
                    await MainActor.run { vm.audioLevel = level }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            } catch {
                await MainActor.run {
                    vm.state = .error(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(3))
                await MainActor.run {
                    self.overlayController?.hide()
                    self.overlayController = nil
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
                let _ = try await env.dictationService.stopRecording()
                await MainActor.run { vm.state = .success }
                try? await Task.sleep(for: .milliseconds(500))
            } catch {
                await MainActor.run {
                    vm.state = .error(error.localizedDescription)
                }
                try? await Task.sleep(for: .seconds(3))
            }

            await MainActor.run {
                self.overlayController?.hide()
                self.overlayController = nil
            }
        }
    }

    private var cancelTask: Task<Void, Never>?

    private func cancelDictation() {
        guard let env = appEnvironment, let vm = overlayViewModel else { return }

        cancelTask?.cancel()
        cancelTask = Task {
            await env.dictationService.cancelRecording()

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

            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.overlayController?.hide()
                self.overlayController = nil
            }
        }
    }

    private func undoCancelDictation() {
        // Cancel the countdown task so the overlay doesn't auto-dismiss
        cancelTask?.cancel()
        cancelTask = nil

        // Dismiss overlay and restart recording
        overlayController?.hide()
        overlayController = nil
        overlayViewModel = nil

        // Restart dictation in persistent mode
        startDictation(mode: .persistent)
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
        openMainWindow()
        // TODO: Switch sidebar to settings tab
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
}
