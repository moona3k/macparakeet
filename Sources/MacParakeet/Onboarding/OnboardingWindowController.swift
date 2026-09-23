import AppKit
import SwiftUI
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let windowSize = NSSize(width: 760, height: 600)

    private var window: NSWindow?
    private var viewModel: OnboardingViewModel?
    private var allowCloseWithoutCompletion = false
    var isVisible: Bool {
        window?.isVisible == true
    }

    /// The run on screen, for rehearsal and practice-dictation feedback.
    var currentViewModel: OnboardingViewModel? {
        viewModel
    }

    /// True while onboarding is up and its practice box is not the dictation
    /// target. The app gates real dictation starts on this.
    var isBlockingDictation: Bool {
        guard isVisible else { return false }
        return viewModel?.isPracticeListening != true
    }

    /// Forward the real dictation flow's state to the practice box.
    func handleDictationFlowState(_ state: DictationFlowState) {
        guard let viewModel, isVisible else { return }
        let activity: OnboardingViewModel.PracticeDictationActivity
        switch state {
        case .checkingEntitlements(let mode), .startingService(let mode), .recording(let mode),
            .pendingStop(let mode):
            activity = .recording(OnboardingViewModel.PracticeKey(recordingMode: mode))
        case .processing:
            activity = .processing
        case .idle, .ready, .cancelCountdown, .finishing:
            activity = .idle
        }
        viewModel.practiceDictationActivityChanged(activity)
    }

    /// Forward a delivered dictation transcript to the practice box.
    func handleDictationDelivered(_ text: String) {
        guard isVisible else { return }
        viewModel?.practiceDictationDelivered(text)
    }

    func show(
        permissionService: PermissionServiceProtocol,
        sttClient: STTClientProtocol,
        diarizationService: DiarizationServiceProtocol? = nil,
        settingsViewModel: SettingsViewModel? = nil,
        onFinish: @escaping () -> Void,
        restartExistingRun: Bool = false,
        onHotkeyPreviewArm: @escaping () -> Void = {},
        onHotkeyPreviewDisarm: @escaping () -> Void = {},
        onShortcutRecordingChanged: @escaping (Bool) -> Void = { _ in },
        onShortcutBindingsChanged: @escaping () -> Void = {},
        onOpenSettings: @escaping () -> Void,
        onIncompleteDismiss: @escaping () -> Void
    ) {
        if let window {
            if restartExistingRun {
                viewModel?.startNewCurrentRun()
                viewModel?.markOnboardingShown()
            }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let vm = OnboardingViewModel(
            permissionService: permissionService,
            sttClient: sttClient,
            diarizationService: diarizationService
        )
        viewModel = vm
        // Retained so the rehearsal taps are torn down if the window closes
        // while the user is on the Try It step (SwiftUI `onDisappear` can lag
        // window teardown). `disarm()` is idempotent.
        onHotkeyPreviewDisarmHandler = onHotkeyPreviewDisarm

        let view = OnboardingFlowView(
            viewModel: vm,
            settingsViewModel: settingsViewModel,
            onFinish: { [weak self] in
                self?.allowCloseWithoutCompletion = true
                self?.close()
                onFinish()
            },
            onOpenSettings: onOpenSettings,
            onHotkeyPreviewArm: onHotkeyPreviewArm,
            onHotkeyPreviewDisarm: onHotkeyPreviewDisarm,
            onShortcutRecordingChanged: onShortcutRecordingChanged,
            onShortcutBindingsChanged: onShortcutBindingsChanged
        )

        let hosting = NSHostingView(rootView: view)
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false)
        w.title = "Welcome to MacParakeet"
        w.isReleasedWhenClosed = false
        w.center()
        w.contentView = hosting
        w.standardWindowButton(.zoomButton)?.isHidden = true
        w.delegate = self

        self.window = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        func confirmDismissOnboarding() {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Setup is not finished"
            alert.informativeText =
                "MacParakeet needs its permissions and the local speech model before dictation is reliable."
            alert.addButton(withTitle: "Continue Setup")
            alert.addButton(withTitle: "Exit Setup")

            let response = alert.runModal()
            if response == .alertSecondButtonReturn {
                vm.markOnboardingDismissed()
                onIncompleteDismiss()
                allowCloseWithoutCompletion = true
                close()
            }
        }

        self.onIncompleteDismiss = confirmDismissOnboarding
    }

    func close() {
        window?.close()
    }

    private var onIncompleteDismiss: (() -> Void)?
    private var onHotkeyPreviewDisarmHandler: (() -> Void)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowCloseWithoutCompletion {
            return true
        }

        if viewModel?.hasCompletedOnboarding == true {
            return true
        }

        onIncompleteDismiss?()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        allowCloseWithoutCompletion = false
        onIncompleteDismiss = nil
        onHotkeyPreviewDisarmHandler?()
        onHotkeyPreviewDisarmHandler = nil
        viewModel?.stopObservingWarmUp()
        viewModel = nil
        // Defer teardown to the next run-loop tick so we don't destroy the
        // SwiftUI hosting view (and its window animations) while the button
        // callback that triggered close() is still on the call stack.
        let w = window
        window = nil
        DispatchQueue.main.async {
            w?.contentView = nil
        }
    }
}
