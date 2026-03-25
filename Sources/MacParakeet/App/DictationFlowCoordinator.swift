import AppKit
import OSLog
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class DictationFlowCoordinator {
    // MARK: - Public Interface

    /// Read by AppDelegate for menu bar icon guard
    var isDictationActive: Bool { overlayController != nil }

    /// Set after init; updated when hotkey manager is recreated
    var hotkeyManager: HotkeyManager?

    // MARK: - Dependencies

    private let dictationService: DictationService
    private let clipboardService: ClipboardServiceProtocol
    private let entitlementsService: EntitlementsService
    private let dictationRepo: DictationRepository
    private let settingsViewModel: SettingsViewModel
    private let onMenuBarIconUpdate: (BreathWaveIcon.MenuBarState) -> Void
    private let onHistoryReload: () -> Void
    private let onPresentEntitlementsAlert: (Error) -> Void

    // MARK: - Dictation Flow State

    private var overlayController: DictationOverlayController?
    private var overlayViewModel: DictationOverlayViewModel?
    private var readyDismissTimer: DispatchWorkItem?
    private var recordingTask: Task<Void, Never>?
    /// Serializes non-recording overlay actions (stop/undo/confirm-cancel) and allows safe cancellation.
    private var overlayActionTask: Task<Void, Never>?
    private var overlayActionGeneration: Int = 0
    /// True only while `DictationService.startRecording()` is in-flight.
    private var isStartRecordingInFlight = false
    /// Stop requested while startup is in-flight; fulfilled once service reaches recording.
    private var pendingStopGeneration: Int?
    private var idlePillController: IdlePillController?
    /// Monotonic generation id for the dictation UI flow. Any async work must guard this value before
    /// mutating shared UI state or calling into `DictationService` (which is global/shared).
    private var overlayGeneration: Int = 0
    private var cancelTask: Task<Void, Never>?
    private let dictationLog = Logger(subsystem: "com.macparakeet.app", category: "DictationFlow")

    // MARK: - Init

    init(
        dictationService: DictationService,
        clipboardService: ClipboardServiceProtocol,
        entitlementsService: EntitlementsService,
        dictationRepo: DictationRepository,
        settingsViewModel: SettingsViewModel,
        onMenuBarIconUpdate: @escaping (BreathWaveIcon.MenuBarState) -> Void,
        onHistoryReload: @escaping () -> Void,
        onPresentEntitlementsAlert: @escaping (Error) -> Void
    ) {
        self.dictationService = dictationService
        self.clipboardService = clipboardService
        self.entitlementsService = entitlementsService
        self.dictationRepo = dictationRepo
        self.settingsViewModel = settingsViewModel
        self.onMenuBarIconUpdate = onMenuBarIconUpdate
        self.onHistoryReload = onHistoryReload
        self.onPresentEntitlementsAlert = onPresentEntitlementsAlert
    }

    // MARK: - Idle Pill

    func showIdlePill() {
        guard settingsViewModel.showIdlePill else { return }
        guard idlePillController == nil else { return }
        guard overlayController == nil else { return }
        let vm = IdlePillViewModel()
        vm.onStartDictation = { [weak self] in
            self?.startDictation(mode: .persistent, trigger: .pillClick)
        }

        let controller = IdlePillController(viewModel: vm)
        controller.show()
        idlePillController = controller
    }

    func hideIdlePill() {
        idlePillController?.hide()
        idlePillController = nil
    }

    // MARK: - Generation

    @discardableResult
    private func bumpOverlayGeneration() -> Int {
        overlayGeneration += 1
        return overlayGeneration
    }

    // MARK: - Ready Pill

    func showReadyPill() {
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

    func startDictation(
        mode: FnKeyStateMachine.RecordingMode,
        trigger: TelemetryDictationTrigger = .hotkey
    ) {
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
        pendingStopGeneration = nil
        dictationLog.notice("dictation_start generation=\(gen) mode=\(String(describing: mode), privacy: .public) trigger=\(String(describing: trigger), privacy: .public)")

        // Cancel old recording task and immediately clean up any overlay it created.
        // Without this, a rapid double-call to startDictation (before the first task
        // reaches its isCancelled guard) leaves an orphaned panel on screen.
        if recordingTask != nil {
            recordingTask?.cancel()
            recordingTask = nil
            isStartRecordingInFlight = false
            overlayController?.hide()
            overlayController = nil
            overlayViewModel = nil
        }

        recordingTask = Task { @MainActor in
            do {
                // Avoid showing the overlay if the user isn't entitled (trial expired).
                try await self.entitlementsService.assertCanTranscribe(now: Date())
            } catch {
                guard self.overlayGeneration == gen else { return }
                self.dictationLog.notice("dictation_completed generation=\(gen) outcome=entitlements_blocked error=\(error.localizedDescription, privacy: .public)")
                self.hotkeyManager?.resetToIdle()
                self.dismissReadyPill(expectedGeneration: gen)
                self.showIdlePill()
                self.onPresentEntitlementsAlert(error)
                return
            }

            // Bail if stop/cancel was called while awaiting entitlements
            guard !Task.isCancelled, self.overlayGeneration == gen else { return }

            // Reuse existing overlay if it's in ready state (seamless transition)
            let vm: DictationOverlayViewModel
            if let existingVM = self.overlayViewModel, case .ready = existingVM.state {
                vm = existingVM
            } else {
                guard self.overlayGeneration == gen else { return }
                vm = DictationOverlayViewModel()
                vm.onCancel = { [weak self] in self?.cancelDictation() }
                vm.onStop = { [weak self] in self?.stopDictation() }
                vm.onUndo = { [weak self] in self?.undoCancelDictation() }
                vm.onDismiss = { [weak self] in self?.dismissOverlay() }
                self.overlayViewModel = vm

                let controller = DictationOverlayController(viewModel: vm)
                controller.show()
                self.overlayController = controller
            }

            guard self.overlayGeneration == gen else { return }
            vm.recordingMode = mode
            vm.state = .recording
            vm.startTimer()
            self.onMenuBarIconUpdate(.recording)

            do {
                self.isStartRecordingInFlight = true
                let telemetryMode: TelemetryDictationMode = switch mode {
                case .persistent: .persistent
                case .holdToTalk: .hold
                }
                try await self.dictationService.startRecording(
                    context: DictationTelemetryContext(trigger: trigger, mode: telemetryMode)
                )
                self.isStartRecordingInFlight = false
                guard !Task.isCancelled, self.overlayGeneration == gen else { return }

                if self.pendingStopGeneration == gen {
                    self.pendingStopGeneration = nil
                    self.stopDictation()
                    return
                }

                // Snapshot settings at start of recording (keeps behavior stable during a recording).
                let (autoStopEnabled, silenceDelay) = (self.settingsViewModel.silenceAutoStop, self.settingsViewModel.silenceDelay)
                let silenceThreshold: Float = 0.03
                var lastNonSilenceAt = Date()
                var didAutoStop = false

                // Update audio level periodically
                while !Task.isCancelled,
                      self.overlayGeneration == gen,
                      case .recording = await self.dictationService.state {
                    let level = await self.dictationService.audioLevel
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
                self.dictationLog.error("dictation_completed generation=\(gen) outcome=start_failed error=\(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled, self.overlayGeneration == gen else { return }
                self.isStartRecordingInFlight = false
                vm.state = .error(error.localizedDescription)
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, self.overlayGeneration == gen else { return }
                self.dismissOverlay()
            }
        }
    }

    func stopDictation() {
        // Stop should cancel any pending cancel countdown.
        cancelTask?.cancel()
        cancelTask = nil

        // Edge case: stop during entitlements check (no overlay created yet).
        guard let vm = overlayViewModel else {
            recordingTask?.cancel()
            recordingTask = nil
            hotkeyManager?.resetToIdle()
            showIdlePill()
            return
        }

        // A stop was already requested while startup is still in-flight.
        if pendingStopGeneration == overlayGeneration { return }

        // Idempotency: ignore duplicate stop requests while a stop/undo/confirm action is running.
        if overlayActionTask != nil { return }

        // Capture the controller now — if the user starts a new dictation before
        // our Task finishes, self.overlayController will point to a new overlay
        // and we'd orphan this one on screen.
        let controller = overlayController
        let gen = overlayGeneration
        let taskToCancelAfterStop = recordingTask

        overlayActionGeneration += 1
        let actionGen = overlayActionGeneration
        overlayActionTask = Task { @MainActor in
            defer {
                if self.overlayActionGeneration == actionGen {
                    self.overlayActionTask = nil
                }
            }

            let stateBeforeStop = await self.dictationService.state
            switch DictationStopDecider.decide(
            serviceState: stateBeforeStop,
            isStartRecordingInFlight: self.isStartRecordingInFlight
            ) {
            case .deferUntilRecording:
                self.pendingStopGeneration = gen
                return
            case .rejectNotRecording:
                self.dictationLog.error("dictation_completed generation=\(gen) outcome=stop_rejected serviceState=\(self.describeDictationState(stateBeforeStop), privacy: .public)")
                vm.stopTimer()
                vm.state = .error("Recording was not active. Please start dictation again.")
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                controller?.hide()
                if self.overlayController === controller {
                    self.overlayController = nil
                }
                if self.overlayViewModel === vm {
                    self.overlayViewModel = nil
                }
                if self.overlayGeneration == gen {
                    self.onMenuBarIconUpdate(.idle)
                    self.hotkeyManager?.resetToIdle()
                    self.showIdlePill()
                }
                return
            case .proceed:
                break
            }

            self.pendingStopGeneration = nil
            taskToCancelAfterStop?.cancel()
            if self.overlayGeneration == gen {
                self.recordingTask = nil
                self.isStartRecordingInFlight = false
            }

            vm.stopTimer()
            vm.state = .processing
            self.onMenuBarIconUpdate(.processing)

            do {
                var dictation = try await self.dictationService.stopRecording()
                guard self.overlayGeneration == gen else { return }
                await self.handleSuccessfulDictation(
                    &dictation, generation: gen, controller: controller,
                    viewModel: vm, outcomePrefix: "success"
                )
            } catch where self.isNoSpeechError(error) {
                // Brief "no speech" pill — view's onAppear triggers the bar animation
                vm.noSpeechProgress = 1.0
                vm.state = .noSpeech
                try? await Task.sleep(for: .seconds(3))
                self.dictationLog.notice("dictation_completed generation=\(gen) outcome=no_speech")
            } catch {
                self.dictationLog.error("dictation_completed generation=\(gen) outcome=stop_failed error=\(error.localizedDescription, privacy: .public)")
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
            self.onHistoryReload()
            if self.overlayGeneration == gen, self.overlayController == nil {
                self.hotkeyManager?.resetToIdle()
                self.onMenuBarIconUpdate(.idle)
                self.showIdlePill()
            }
        }
    }

    func cancelDictation(reason: TelemetryDictationCancelReason = .ui) {
        recordingTask?.cancel()
        recordingTask = nil
        isStartRecordingInFlight = false
        pendingStopGeneration = nil

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
            overlayActionGeneration += 1
            let actionGen = overlayActionGeneration
            overlayActionTask = Task { @MainActor in
                defer {
                    if self.overlayActionGeneration == actionGen {
                        self.overlayActionTask = nil
                    }
                }
                guard self.overlayGeneration == gen else { return }
                await self.dictationService.confirmCancel()
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
                self.onMenuBarIconUpdate(.idle)
                self.showIdlePill()
                self.dictationLog.notice("dictation_completed generation=\(gen) outcome=cancelled reason=\(String(describing: reason), privacy: .public) confirm=immediate")
            }
            return
        }

        cancelTask?.cancel()
        let controller = overlayController
        let gen = overlayGeneration
        cancelTask = Task { @MainActor in
            guard self.overlayGeneration == gen else { return }

            // Soft cancel immediately: stop capture but keep audio briefly so Undo can proceed.
            await self.dictationService.cancelRecording(reason: reason)

            // Sync state machine — may have been triggered via UI button, not Esc
            // (Esc path already transitions the state machine to cancelWindow.)
            self.hotkeyManager?.notifyCancelledByUI()

            guard self.overlayGeneration == gen else { return }
            vm.stopTimer()
            vm.cancelTimeRemaining = 5.0
            vm.state = .cancelled(timeRemaining: 5.0)
            self.onMenuBarIconUpdate(.idle)

            // Simple 5-second countdown. Only update cancelTimeRemaining (not state
            // enum) to avoid SwiftUI view reconstruction that fights the ring animation.
            for i in stride(from: 4.0, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                guard self.overlayGeneration == gen else { return }
                vm.cancelTimeRemaining = i
            }

            // Countdown expired — discard and return to idle UI.
            guard self.overlayGeneration == gen else { return }
            await self.dictationService.confirmCancel()
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
            self.onMenuBarIconUpdate(.idle)
            self.showIdlePill()
            self.dictationLog.notice("dictation_completed generation=\(gen) outcome=cancelled reason=\(String(describing: reason), privacy: .public) confirm=countdown_expired")
        }
    }

    func dismissOverlayIfError() {
        if let vm = overlayViewModel {
            if case .error = vm.state {
                dismissOverlay()
                return
            } else if case .noSpeech = vm.state {
                dismissOverlay()
                return
            }
        }
    }

    // MARK: - Private Helpers

    private func undoCancelDictation() {
        guard let vm = overlayViewModel else { return }

        // Cancel the countdown so it doesn't expire and discard audio.
        cancelTask?.cancel()
        cancelTask = nil

        // Capture the controller now (same race-condition guard as stopDictation).
        let controller = overlayController
        let gen = overlayGeneration

        overlayActionTask?.cancel()
        overlayActionGeneration += 1
        let actionGen = overlayActionGeneration
        overlayActionTask = Task { @MainActor in
            defer {
                if self.overlayActionGeneration == actionGen {
                    self.overlayActionTask = nil
                }
            }
            vm.stopTimer()
            vm.state = .processing
            self.onMenuBarIconUpdate(.processing)

            do {
                var dictation = try await self.dictationService.undoCancel()
                guard self.overlayGeneration == gen else { return }
                await self.handleSuccessfulDictation(
                    &dictation, generation: gen, controller: controller,
                    viewModel: vm, outcomePrefix: "undo_success"
                )
            } catch where self.isNoSpeechError(error) {
                // Brief "no speech" pill — view's onAppear triggers the bar animation
                vm.noSpeechProgress = 1.0
                vm.state = .noSpeech
                try? await Task.sleep(for: .seconds(3))
                self.dictationLog.notice("dictation_completed generation=\(gen) outcome=undo_no_speech")
            } catch {
                self.dictationLog.error("dictation_completed generation=\(gen) outcome=undo_failed error=\(error.localizedDescription, privacy: .public)")
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
            self.onHistoryReload()
            if self.overlayGeneration == gen, self.overlayController == nil {
                self.onMenuBarIconUpdate(.idle)
                self.showIdlePill()
            }
        }
    }

    private func handleSuccessfulDictation(
        _ dictation: inout Dictation,
        generation: Int,
        controller: DictationOverlayController?,
        viewModel: DictationOverlayViewModel,
        outcomePrefix: String
    ) async {
        viewModel.state = .success
        // Resign key window so CGEvent paste targets the user's app
        controller?.resignKeyWindow()
        // Brief pause so user sees the checkmark before paste
        try? await Task.sleep(for: .milliseconds(200))
        let transcriptToPaste = dictation.cleanTranscript ?? dictation.rawTranscript
        let didAutoPaste = await pasteTranscriptWithFallback(
            generation: generation,
            transcript: transcriptToPaste,
            viewModel: viewModel
        )
        if didAutoPaste {
            if let pastedToApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                dictation.pastedToApp = pastedToApp
                dictation.updatedAt = Date()
                do {
                    try dictationRepo.save(dictation)
                } catch {
                    dictationLog.error("Failed to save pastedToApp metadata error=\(error.localizedDescription, privacy: .public)")
                }
            }
            try? await Task.sleep(for: .milliseconds(800))
        } else {
            try? await Task.sleep(for: .seconds(5))
        }
        let rawChars = dictation.rawTranscript.count
        let cleanChars = dictation.cleanTranscript?.count ?? 0
        let app = dictation.pastedToApp ?? "none"
        dictationLog.notice(
            "dictation_completed generation=\(generation) outcome=\(outcomePrefix, privacy: .public) rawChars=\(rawChars) cleanChars=\(cleanChars) autoPasted=\(didAutoPaste) pastedToApp=\(app, privacy: .public)"
        )
    }

    private func dismissOverlay() {
        recordingTask?.cancel()
        recordingTask = nil
        isStartRecordingInFlight = false
        pendingStopGeneration = nil
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
        onMenuBarIconUpdate(.idle)
        showIdlePill()
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
    private func pasteTranscriptWithFallback(
        generation: Int,
        transcript: String,
        viewModel: DictationOverlayViewModel
    ) async -> Bool {
        do {
            try await clipboardService.pasteText(transcript + " ")
            return true
        } catch {
            let bucket = commandFailureBucket(for: error)
            dictationLog.error(
                "dictation_paste_failed generation=\(generation) bucket=\(bucket, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            await clipboardService.copyToClipboard(transcript)
            viewModel.state = .error("Copied to clipboard. Press Cmd+V.")
            return false
        }
    }

    private func commandFailureBucket(for error: Error) -> String {
        if let accessibilityError = error as? AccessibilityServiceError {
            switch accessibilityError {
            case .notAuthorized:
                return "accessibility_not_authorized"
            case .noFocusedElement:
                return "no_focused_element"
            case .noSelectedText:
                return "no_selected_text"
            case .textTooLong:
                return "selection_too_long"
            case .unsupportedElement:
                return "unsupported_element"
            }
        }

        if error is ClipboardServiceError {
            return "paste_failed"
        }

        return "unknown"
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

}
