import AppKit
import AVFoundation
import MacParakeetCore
import MacParakeetViewModels

/// Drives the interactive hotkey *rehearsal* on the onboarding "Learn the
/// Hotkey" step. Pressing the user's configured dictation trigger raises the
/// real dictation overlay with a live, mic-driven waveform — but **never**
/// touches STT, paste, history, or the dictation flow. It's a visual
/// first-success that lands before the speech model is even downloaded (the
/// next onboarding step).
///
/// Lifecycle: `arm()` when the hotkey step appears, `disarm()` when it
/// disappears or the onboarding window closes. Both are idempotent so the
/// SwiftUI `onDisappear` and the window's `windowWillClose` can both call
/// `disarm()` without desyncing the suspend/resume refcount.
///
/// While armed, the production hotkey taps are suspended so only the preview
/// taps own the key. The production dictation flow is *also* gated while
/// onboarding is visible (see `AppEnvironmentConfigurer`), so the rehearsal can
/// never collide with a real dictation.
@MainActor
final class OnboardingHotkeyPreviewController {

    /// Live mic-level feed, abstracted so the controller is unit-testable
    /// without real audio hardware. `onLevel` is delivered on the main actor.
    @MainActor
    protocol MicLeveling: AnyObject {
        func start(onLevel: @escaping @MainActor (Float) -> Void)
        func stop()
    }

    private let planProvider: () -> AppHotkeyCoordinator.DictationHotkeyPlan
    private let micLevelingProvider: () -> MicLeveling?
    private let overlayFactory: @MainActor (DictationOverlayViewModel) -> any DictationOverlayControlling
    private let suspendProductionHotkeys: () -> Void
    private let resumeProductionHotkeys: () -> Void

    private var managers: [HotkeyManager] = []
    private var overlayController: (any DictationOverlayControlling)?
    private var overlayViewModel: DictationOverlayViewModel?
    private var micLeveling: MicLeveling?

    private(set) var isArmed = false
    private(set) var isPreviewing = false

    init(
        planProvider: @escaping () -> AppHotkeyCoordinator.DictationHotkeyPlan,
        micLevelingProvider: @escaping () -> MicLeveling?,
        overlayFactory: @escaping @MainActor (DictationOverlayViewModel) -> any DictationOverlayControlling = {
            DictationOverlayController(viewModel: $0)
        },
        suspendProductionHotkeys: @escaping () -> Void,
        resumeProductionHotkeys: @escaping () -> Void
    ) {
        self.planProvider = planProvider
        self.micLevelingProvider = micLevelingProvider
        self.overlayFactory = overlayFactory
        self.suspendProductionHotkeys = suspendProductionHotkeys
        self.resumeProductionHotkeys = resumeProductionHotkeys
    }

    // MARK: - Arm / Disarm

    func arm() {
        guard !isArmed else { return }
        isArmed = true
        // Stand the production taps down so only the preview taps own the key
        // for the duration of the step. Balanced by `resume()` in `disarm()`.
        suspendProductionHotkeys()
        buildManagers()
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        endPreview()
        managers.forEach { $0.stop() }
        managers = []
        resumeProductionHotkeys()
    }

    // MARK: - Hotkey wiring

    private func buildManagers() {
        for spec in planProvider().specs {
            let manager = HotkeyManager(
                trigger: spec.trigger,
                gestureMode: spec.gestureMode,
                startupDebounceMs: spec.startupDebounceMs
            )
            manager.onStartRecording = { [weak self, weak manager] mode in
                guard let self, let manager else { return }
                self.suppressPeers(of: manager)
                self.beginPreview(mode: mode)
            }
            manager.onStopRecording = { [weak self] in self?.endPreviewAndResetGestures() }
            manager.onCancelRecording = { [weak self] in self?.endPreviewAndResetGestures() }
            if manager.start() {
                managers.append(manager)
            }
        }
    }

    /// Mirror the production app: once one trigger fires, suppress the peer
    /// trigger until reset so a held `fn` can't also fire an `fn+Space` toggle.
    private func suppressPeers(of active: HotkeyManager) {
        for manager in managers where manager !== active {
            manager.suppressUntilReset()
        }
    }

    // MARK: - Preview lifecycle (internal for tests)

    func beginPreview(mode: FnKeyStateMachine.RecordingMode) {
        guard isArmed, !isPreviewing else { return }
        isPreviewing = true

        let vm = DictationOverlayViewModel()
        vm.recordingMode = mode
        vm.state = .recording
        // The stop/cancel affordances on the persistent-mode pill end the
        // rehearsal (and reset gesture state) just like the second tap would.
        vm.onStop = { [weak self] in self?.endPreviewAndResetGestures() }
        vm.onCancel = { [weak self] in self?.endPreviewAndResetGestures() }
        vm.onDismiss = { [weak self] in self?.endPreviewAndResetGestures() }
        vm.startTimer()
        overlayViewModel = vm

        let controller = overlayFactory(vm)
        controller.show()
        overlayController = controller

        // If the mic is unavailable (permission skipped) the leveling provider
        // returns nil / its subscribe quietly fails — the overlay still appears,
        // the waveform just stays at rest. Onboarding never blocks on this.
        let leveling = micLevelingProvider()
        micLeveling = leveling
        leveling?.start { [weak self] level in
            self?.overlayViewModel?.audioLevel = level
        }
    }

    func endPreview() {
        guard isPreviewing else { return }
        isPreviewing = false
        micLeveling?.stop()
        micLeveling = nil
        overlayViewModel?.stopTimer()
        overlayController?.hide()
        overlayController = nil
        overlayViewModel = nil
    }

    private func endPreviewAndResetGestures() {
        endPreview()
        managers.forEach { $0.resetToIdle() }
    }
}

// MARK: - SharedMicrophoneStream-backed leveling

/// Concrete `MicLeveling` backed by the process-wide `SharedMicrophoneStream`.
/// Subscribes with `wantsVPIO: false` (raw mic — no echo cancellation needed
/// for a visual preview) and converts each buffer to an RMS level on the main
/// actor. A subscribe failure (e.g. mic permission skipped) is swallowed; the
/// overlay still appears, just without a moving waveform.
@MainActor
final class SharedMicLeveling: OnboardingHotkeyPreviewController.MicLeveling {
    private let stream: SharedMicrophoneStream
    private var token: SharedMicrophoneStream.SubscriberToken?
    private var subscribeTask: Task<Void, Never>?

    init(stream: SharedMicrophoneStream) {
        self.stream = stream
    }

    func start(onLevel: @escaping @MainActor (Float) -> Void) {
        subscribeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = try await self.stream.subscribe(wantsVPIO: false) { buffer, _ in
                    let level = buffer.rmsLevel
                    Task { @MainActor in onLevel(level) }
                }
                if Task.isCancelled {
                    await self.stream.unsubscribe(token)
                } else {
                    self.token = token
                }
            } catch {
                // Mic unavailable — leave the overlay on its fallback shimmer.
            }
        }
    }

    func stop() {
        subscribeTask?.cancel()
        subscribeTask = nil
        if let token {
            let stream = self.stream
            Task { await stream.unsubscribe(token) }
            self.token = nil
        }
    }
}
