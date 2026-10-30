import AppKit
import MacParakeetCore
import MacParakeetViewModels

/// Drives the key rehearsal on the onboarding Try It card. Pressing the user's
/// configured dictation key lights the matching key cap inside the card. It
/// **never** records audio, touches STT, pastes, or starts the dictation flow,
/// so it works while the speech model is still downloading.
///
/// Lighting comes from the same `HotkeyManager` gesture machine production
/// uses, so a lit cap proves both the Accessibility grant and the binding:
/// hold-to-talk lights the push-to-talk cap until release, and the hands-free
/// gesture lights the hands-free cap until the next tap or Escape.
///
/// Lifecycle: `arm()` while the Try It card should rehearse, `disarm()` when it
/// stops (the practice box starts listening, the step disappears, or the
/// window closes). Both are idempotent so SwiftUI `onDisappear` and the
/// window's `windowWillClose` can both call `disarm()` without desyncing the
/// suspend/resume refcount.
///
/// While armed, the production hotkey taps are suspended so only the rehearsal
/// taps own the key. The production dictation flow is also gated while
/// onboarding is visible (see `AppEnvironmentConfigurer`), except while the
/// practice box is listening, and the box only listens after `disarm()`.
@MainActor
final class OnboardingHotkeyPreviewController {
    typealias PracticeKey = OnboardingViewModel.PracticeKey

    private let planProvider: () -> AppHotkeyCoordinator.DictationHotkeyPlan
    private let suspendProductionHotkeys: () -> Void
    private let resumeProductionHotkeys: () -> Void

    /// Called on the main actor whenever the lit key changes. `nil` means rest.
    var onKeyStateChanged: ((PracticeKey?) -> Void)?

    private var managers: [HotkeyManager] = []

    private(set) var isArmed = false
    /// True while a shortcut recorder owns the keyboard. Taps stay down, the
    /// armed state (and the production suspension) is kept.
    private(set) var isCapturePaused = false
    private(set) var litKey: PracticeKey?

    init(
        planProvider: @escaping () -> AppHotkeyCoordinator.DictationHotkeyPlan,
        suspendProductionHotkeys: @escaping () -> Void,
        resumeProductionHotkeys: @escaping () -> Void
    ) {
        self.planProvider = planProvider
        self.suspendProductionHotkeys = suspendProductionHotkeys
        self.resumeProductionHotkeys = resumeProductionHotkeys
    }

    // MARK: - Arm / Disarm

    func arm() {
        guard !isArmed else { return }
        isArmed = true
        // Stand the production taps down so only the rehearsal taps own the
        // key for the duration of the rehearsal. Balanced in `disarm()`.
        suspendProductionHotkeys()
        if !isCapturePaused {
            buildManagers()
        }
    }

    func disarm() {
        guard isArmed else { return }
        isArmed = false
        tearDownManagers()
        resumeProductionHotkeys()
    }

    /// Stop listening while a shortcut recorder captures a key, then rebuild
    /// from the current plan so a new binding lights immediately.
    func setCapturePaused(_ paused: Bool) {
        guard isCapturePaused != paused else { return }
        isCapturePaused = paused
        guard isArmed else { return }
        if paused {
            tearDownManagers()
        } else {
            buildManagers()
        }
    }

    /// Rebuild the rehearsal taps after a binding changed outside a recorder
    /// session (for example Reset to default).
    func refreshBindings() {
        guard isArmed, !isCapturePaused else { return }
        tearDownManagers()
        buildManagers()
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
                self.keyDidActivate(mode: mode)
            }
            manager.onStopRecording = { [weak self] in self?.keyDidRest() }
            manager.onCancelRecording = { [weak self] in self?.keyDidRest() }
            // A short first press can start provisionally, then be discarded
            // while the manager still waits for a second tap. Clear the cap
            // without resetting that gesture state.
            manager.onDiscardRecording = { [weak self, weak manager] _ in
                guard let self, let manager else { return }
                self.setLitKey(nil)
                self.resetPeers(of: manager)
            }
            if manager.start() {
                managers.append(manager)
            }
        }
    }

    private func tearDownManagers() {
        managers.forEach { $0.stop() }
        managers = []
        setLitKey(nil)
    }

    /// Mirror the production app: once one trigger fires, suppress the peer
    /// trigger until reset so overlapping custom triggers cannot double-fire.
    private func suppressPeers(of active: HotkeyManager) {
        for manager in managers where manager !== active {
            manager.suppressUntilReset()
        }
    }

    private func resetPeers(of active: HotkeyManager) {
        for manager in managers where manager !== active {
            manager.resetToIdle()
        }
    }

    // MARK: - Key state (internal for tests)

    func keyDidActivate(mode: FnKeyStateMachine.RecordingMode) {
        guard isArmed, !isCapturePaused else { return }
        setLitKey(PracticeKey(recordingMode: mode))
    }

    func keyDidRest() {
        setLitKey(nil)
        managers.forEach { $0.resetToIdle() }
    }

    private func setLitKey(_ key: PracticeKey?) {
        guard litKey != key else { return }
        litKey = key
        onKeyStateChanged?(key)
    }
}
