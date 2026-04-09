import AppKit
import OSLog
import MacParakeetCore
import MacParakeetViewModels

@MainActor
final class DictationFlowCoordinator {
    private static let silenceAutoStopThreshold: Float = 0.03

    // MARK: - Public Interface

    /// True whenever the dictation overlay is showing. Used by presentation-conflict
    /// guards (e.g. the idle-pill suppressor when a meeting recording ends) to prevent
    /// surfaces from colliding with the overlay.
    ///
    /// NOTE: this returns true during terminal display states (success checkmark,
    /// no-speech leaf, error card). For the menu bar icon, use `isCapturingAudio`
    /// instead — see the note on that property.
    var isDictationActive: Bool { overlayController != nil }

    /// True only while audio is actively being captured or in-flight transcription
    /// is running. Used by `AppDelegate.resolveAndUpdateMenuBarIcon()` so the red
    /// recording dot does NOT linger through terminal display states (success
    /// checkmark / no-speech leaf animation / error card) or through the cancel
    /// countdown undo window.
    ///
    /// Returns false for:
    ///   - `.idle`, `.ready`, `.checkingEntitlements` — no overlay or audio yet
    ///   - `.cancelCountdown` — capture already stopped via `.cancelRecording(reason:)`;
    ///     state machine explicitly emits `.updateMenuBar(.idle)` at this transition
    ///     (see `DictationFlowStateMachine.swift:299`)
    ///   - `.finishing(...)` — terminal display states, audio already stopped
    ///
    /// ---
    /// KNOWN LIMITATION — not fixable with a boolean:
    ///
    /// `.processing` returns `true` → the resolver shows the RED "recording"
    /// dot, but the state machine emits `.updateMenuBar(.processing)` (orange)
    /// on entry (see `DictationFlowStateMachine.swift:279, 333`). The resolver
    /// has no way to express "orange for dictation processing" because it uses
    /// boolean flags (`isCapturingAudio`, `isTranscribing`) instead of a
    /// preference enum. This is a pre-existing inconsistency, not introduced
    /// by this property.
    ///
    /// The cleaner architectural fix is to replace the boolean with a
    /// `MenuBarState?` preference getter on each flow coordinator, and have
    /// `resolveAndUpdateMenuBarIcon()` pick the highest-priority preference:
    ///
    /// ```swift
    /// // On DictationFlowCoordinator:
    /// var menuBarPreference: BreathWaveIcon.MenuBarState? {
    ///     switch stateMachine.state {
    ///     case .startingService, .recording, .pendingStop: return .recording
    ///     case .processing: return .processing
    ///     default: return nil   // no preference — fall through
    ///     }
    /// }
    ///
    /// // In AppDelegate.resolveAndUpdateMenuBarIcon:
    /// if meetingCoordinator?.isMeetingRecordingActive == true { ... }
    /// else if let pref = dictationCoordinator?.menuBarPreference { ... }
    /// else if transcriptionViewModel.isTranscribing { ... }
    /// else { .idle }
    /// ```
    ///
    /// This would respect each flow's state-machine intent exactly and eliminate
    /// the dual-purpose `isDictationActive` / `isCapturingAudio` split above.
    var isCapturingAudio: Bool {
        Self.isCapturingAudio(for: stateMachine.state)
    }

    static func isCapturingAudio(for state: DictationFlowState) -> Bool {
        switch state {
        case .startingService, .recording, .pendingStop, .processing:
            return true
        case .idle, .ready, .checkingEntitlements, .cancelCountdown, .finishing:
            return false
        }
    }

    /// Set after init; updated when hotkey manager is recreated
    var hotkeyManager: HotkeyManager?

    // MARK: - Dependencies

    private let serviceSession: DictationServiceSession
    private let clipboardService: ClipboardServiceProtocol
    private let entitlementsService: EntitlementsService
    private let dictationRepo: DictationRepository
    private let settingsViewModel: SettingsViewModel
    private let shouldSuppressIdlePill: () -> Bool
    private let onMenuBarIconUpdate: (BreathWaveIcon.MenuBarState) -> Void
    private let onHistoryReload: () -> Void
    private let onPresentEntitlementsAlert: (Error) -> Void

    // MARK: - State Machine

    private var stateMachine = DictationFlowStateMachine()
    private let dictationLog = Logger(subsystem: "com.macparakeet.app", category: "DictationFlow")

    // MARK: - UI Resources (managed by effect executor)

    private var overlayController: DictationOverlayController?
    private var overlayViewModel: DictationOverlayViewModel?
    private var idlePillController: IdlePillController?
    private var readyDismissTimer: DispatchWorkItem?
    private var recordingTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var cancelCountdownTask: Task<Void, Never>?
    private var displayDismissTask: Task<Void, Never>?

    // MARK: - Flow Context (not state machine concerns)

    /// Telemetry trigger for the current dictation flow.
    private var currentTrigger: TelemetryDictationTrigger = .hotkey
    /// The Dictation object from the most recent transcription, used for paste + DB save.
    private var currentDictation: Dictation?
    /// Ephemeral post-paste action from the text processing pipeline (e.g., simulate Return key).
    private var pendingPostPasteAction: KeyAction?
    /// Error from the most recent entitlements check failure, consumed by presentEntitlementsAlert effect.
    private var lastEntitlementsError: Error?
    private var readyPillDismissDelayMs: Int {
        (hotkeyManager?.tapThresholdMs ?? FnKeyStateMachine.defaultTapThresholdMs) * 2
    }

    // MARK: - Init

    init(
        dictationService: DictationService,
        clipboardService: ClipboardServiceProtocol,
        entitlementsService: EntitlementsService,
        dictationRepo: DictationRepository,
        settingsViewModel: SettingsViewModel,
        shouldSuppressIdlePill: @escaping () -> Bool = { false },
        onMenuBarIconUpdate: @escaping (BreathWaveIcon.MenuBarState) -> Void,
        onHistoryReload: @escaping () -> Void,
        onPresentEntitlementsAlert: @escaping (Error) -> Void
    ) {
        self.serviceSession = DictationServiceSession(service: dictationService)
        self.clipboardService = clipboardService
        self.entitlementsService = entitlementsService
        self.dictationRepo = dictationRepo
        self.settingsViewModel = settingsViewModel
        self.shouldSuppressIdlePill = shouldSuppressIdlePill
        self.onMenuBarIconUpdate = onMenuBarIconUpdate
        self.onHistoryReload = onHistoryReload
        self.onPresentEntitlementsAlert = onPresentEntitlementsAlert
    }

    // MARK: - Public Methods (translate to state machine events)

    func showIdlePill() {
        guard settingsViewModel.showIdlePill else { return }
        guard idlePillController == nil else { return }
        guard overlayController == nil else { return }
        guard !shouldSuppressIdlePill() else { return }
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

    func showReadyPill() {
        sendEvent(.readyPillRequested)
    }

    func startDictation(
        mode: FnKeyStateMachine.RecordingMode,
        trigger: TelemetryDictationTrigger = .hotkey
    ) {
        currentTrigger = trigger
        sendEvent(.startRequested(mode: mode))
    }

    func stopDictation() {
        sendEvent(.stopRequested)
    }

    func cancelDictation(reason: TelemetryDictationCancelReason = .ui) {
        // Map telemetry reason to state machine cancel reason
        let flowReason: DictationFlowCancelReason = reason == .ui ? .ui : .escape
        sendEvent(.cancelRequested(reason: flowReason))
    }

    func discardProvisionalRecording(showReadyPill: Bool) {
        sendEvent(.discardRequested(showReadyPill: showReadyPill))
    }

    func dismissOverlayIfError() {
        switch stateMachine.state {
        case .finishing(let outcome):
            switch outcome {
            case .error, .noSpeech, .pasteFailedCopied:
                sendEvent(.dismissRequested)
            case .success:
                break
            }
        default:
            break
        }
    }

    // MARK: - State Machine Core

    private func sendEvent(_ event: DictationFlowEvent) {
        let oldState = stateMachine.state
        let effects = stateMachine.handle(event)

        if !effects.isEmpty {
            dictationLog.notice(
                "flow_transition gen=\(self.stateMachine.generation) \(self.describeState(oldState), privacy: .public) → \(self.describeState(self.stateMachine.state), privacy: .public) on \(String(describing: event), privacy: .public)"
            )
        }

        executeEffects(effects)
    }

    // MARK: - Effect Executor

    private func executeEffects(_ effects: [DictationFlowEffect]) {
        for effect in effects {
            executeEffect(effect)
        }
    }

    private func executeEffect(_ effect: DictationFlowEffect) {
        switch effect {

        // MARK: Overlay lifecycle

        case .showReadyPill:
            // Defensive: hide any existing overlay before showing ready pill
            overlayController?.hide()
            overlayController = nil
            overlayViewModel = nil

            let vm = DictationOverlayViewModel()
            vm.onCancel = { [weak self] in self?.cancelDictation() }
            vm.onStop = { [weak self] in self?.stopDictation() }
            vm.onUndo = { [weak self] in self?.sendEvent(.undoRequested) }
            vm.onDismiss = { [weak self] in self?.sendEvent(.dismissRequested) }
            vm.state = .ready
            overlayViewModel = vm

            let controller = DictationOverlayController(viewModel: vm)
            controller.show()
            overlayController = controller

        case .rescheduleReadyDismissTimer:
            readyDismissTimer?.cancel()
            let gen = stateMachine.generation
            let timer = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.sendEvent(.readyPillTimedOut(generation: gen))
                }
            }
            readyDismissTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(readyPillDismissDelayMs), execute: timer)

        case .showRecordingOverlay(let mode):
            // Reuse existing overlay if it's in ready state (seamless transition)
            let vm: DictationOverlayViewModel
            if let existingVM = overlayViewModel, case .ready = existingVM.state {
                vm = existingVM
            } else {
                vm = DictationOverlayViewModel()
                vm.onCancel = { [weak self] in self?.cancelDictation() }
                vm.onStop = { [weak self] in self?.stopDictation() }
                vm.onUndo = { [weak self] in self?.sendEvent(.undoRequested) }
                vm.onDismiss = { [weak self] in self?.sendEvent(.dismissRequested) }
                overlayViewModel = vm

                let controller = DictationOverlayController(viewModel: vm)
                controller.show()
                overlayController = controller
            }
            vm.recordingMode = mode
            vm.state = .recording
            vm.startTimer()

        case .showProcessingState:
            overlayViewModel?.stopTimer()
            overlayViewModel?.state = .processing

        case .showCancelCountdown:
            overlayViewModel?.stopTimer()
            overlayViewModel?.cancelTimeRemaining = 5.0
            overlayViewModel?.state = .cancelled(timeRemaining: 5.0)

        case .showSuccess:
            overlayViewModel?.state = .success

        case .showNoSpeech:
            overlayViewModel?.state = .noSpeech

        case .showError(let message):
            overlayViewModel?.state = .error(message)

        case .hideOverlay:
            overlayController?.hide()
            overlayController = nil
            overlayViewModel = nil

        case .dismissReadyPill:
            overlayController?.hide()
            overlayController = nil
            overlayViewModel = nil

        // MARK: Idle pill

        case .showIdlePill:
            showIdlePill()

        case .hideIdlePill:
            hideIdlePill()

        // MARK: Audio/service (async — launch tasks that feed events back)

        case .checkEntitlements:
            let gen = stateMachine.generation
            recordingTask = Task { @MainActor in
                do {
                    try await self.entitlementsService.assertCanTranscribe(now: Date())
                    guard !Task.isCancelled else { return }
                    self.sendEvent(.entitlementsGranted(generation: gen))
                } catch {
                    guard !Task.isCancelled else { return }
                    self.lastEntitlementsError = error
                    self.sendEvent(.entitlementsDenied(generation: gen))
                }
            }

        case .startRecording(let mode):
            let sessionID = serviceSession.reserveNextSessionID()
            startRecordingTask(mode: mode, generation: stateMachine.generation, sessionID: sessionID)

        case .stopRecordingAndTranscribe:
            let sessionID = serviceSession.currentSessionID
            stopRecordingTask(generation: stateMachine.generation, sessionID: sessionID)

        case .cancelRecording(let reason):
            let sessionID = serviceSession.currentSessionID
            Task { @MainActor in
                await self.serviceSession.cancelRecording(
                    reason: self.telemetryCancelReason(for: reason),
                    sessionID: sessionID
                )
            }

        case .confirmCancel:
            let sessionID = serviceSession.currentSessionID
            Task { @MainActor in
                await self.serviceSession.confirmCancel(sessionID: sessionID)
            }

        case .discardRecording:
            let sessionID = serviceSession.currentSessionID
            Task { @MainActor in
                await self.serviceSession.confirmCancel(sessionID: sessionID)
            }

        case .undoCancelAndTranscribe:
            undoCancelTask(generation: stateMachine.generation)

        // MARK: Paste

        case .resignKeyWindow:
            overlayController?.resignKeyWindow()

        case .pasteTranscript:
            let gen = stateMachine.generation
            guard let dictation = currentDictation else {
                sendEvent(.pasteFailed(generation: gen, message: "No transcription available."))
                return
            }
            let transcript = dictation.cleanTranscript ?? dictation.rawTranscript
            actionTask = Task { @MainActor in
                // Brief pause so user sees the checkmark before paste
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }

                let action = self.pendingPostPasteAction
                self.pendingPostPasteAction = nil

                do {
                    if let action {
                        // Action mode: no trailing space, action replaces the space role
                        let keystrokeFired = try await self.clipboardService.pasteTextWithAction(
                            transcript,
                            postPasteAction: action
                        )
                        if keystrokeFired {
                            Telemetry.send(.keystrokeSnippetFired(action: action.rawValue))
                        }
                    } else {
                        // Normal mode: trailing space as before
                        try await self.clipboardService.pasteText(transcript + " ")
                    }
                    guard !Task.isCancelled else { return }

                    // Save pastedToApp metadata
                    if let pastedToApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
                        self.currentDictation?.pastedToApp = pastedToApp
                        self.currentDictation?.updatedAt = Date()
                        if let d = self.currentDictation {
                            do {
                                try self.dictationRepo.save(d)
                            } catch {
                                self.dictationLog.error("Failed to save pastedToApp metadata error=\(error.localizedDescription, privacy: .public)")
                            }
                        }
                    }

                    let rawChars = dictation.rawTranscript.count
                    let cleanChars = dictation.cleanTranscript?.count ?? 0
                    let app = self.currentDictation?.pastedToApp ?? "none"
                    self.dictationLog.notice("dictation_completed gen=\(gen) outcome=success rawChars=\(rawChars) cleanChars=\(cleanChars) autoPasted=true pastedToApp=\(app, privacy: .public)")

                    self.sendEvent(.pasteSucceeded(generation: gen))
                } catch {
                    guard !Task.isCancelled else { return }
                    let bucket = self.commandFailureBucket(for: error)
                    self.dictationLog.error("dictation_paste_failed gen=\(gen) bucket=\(bucket, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Pure action-only dictation (e.g., "press return") — nothing to paste
                        self.sendEvent(.pasteFailed(generation: gen, message: "Keystroke failed. Check Accessibility permissions."))
                    } else {
                        await self.clipboardService.copyToClipboard(transcript)
                        self.sendEvent(.pasteFailed(generation: gen, message: "Copied to clipboard. Press Cmd+V."))
                    }
                }
            }

        // MARK: History

        case .reloadHistory:
            onHistoryReload()
            currentDictation = nil
            pendingPostPasteAction = nil

        // MARK: App integration

        case .updateMenuBar(let menuBarState):
            let iconState: BreathWaveIcon.MenuBarState = switch menuBarState {
            case .idle: .idle
            case .recording: .recording
            case .processing: .processing
            }
            onMenuBarIconUpdate(iconState)

        case .resetHotkeyStateMachine:
            hotkeyManager?.resetToIdle()

        case .notifyHotkeyCancelledByUI:
            hotkeyManager?.notifyCancelledByUI()

        case .presentEntitlementsAlert:
            if let error = lastEntitlementsError {
                onPresentEntitlementsAlert(error)
                lastEntitlementsError = nil
            }

        // MARK: Timer management

        case .startReadyDismissTimer:
            readyDismissTimer?.cancel()
            let gen = stateMachine.generation
            let timer = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.sendEvent(.readyPillTimedOut(generation: gen))
                }
            }
            readyDismissTimer = timer
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(readyPillDismissDelayMs), execute: timer)

        case .cancelReadyDismissTimer:
            readyDismissTimer?.cancel()
            readyDismissTimer = nil

        case .startCancelCountdown:
            let gen = stateMachine.generation
            cancelCountdownTask = Task { @MainActor in
                // 5-second countdown, updating UI each second
                for i in stride(from: 4.0, through: 0, by: -1) {
                    try? await Task.sleep(for: .seconds(1))
                    if Task.isCancelled { return }
                    self.overlayViewModel?.cancelTimeRemaining = i
                }
                guard !Task.isCancelled else { return }
                self.sendEvent(.cancelCountdownExpired(generation: gen))
            }

        case .cancelCancelCountdown:
            cancelCountdownTask?.cancel()
            cancelCountdownTask = nil

        case .startDisplayDismissTimer(let seconds):
            displayDismissTask?.cancel()
            let gen = stateMachine.generation
            displayDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                guard !Task.isCancelled else { return }
                self.sendEvent(.displayDismissExpired(generation: gen))
            }

        case .cancelAllTimers:
            readyDismissTimer?.cancel()
            readyDismissTimer = nil
            cancelCountdownTask?.cancel()
            cancelCountdownTask = nil
            displayDismissTask?.cancel()
            displayDismissTask = nil

        // MARK: Task management

        case .cancelRecordingTask:
            recordingTask?.cancel()
            recordingTask = nil

        case .cancelActionTask:
            actionTask?.cancel()
            actionTask = nil
            pendingPostPasteAction = nil
        }
    }

    // MARK: - Private Helpers

    /// Whether the error represents "no speech" (empty transcript or recording too short).
    private func isNoSpeechError(_ error: Error) -> Bool {
        if let e = error as? DictationServiceError, e == .emptyTranscript { return true }
        if let e = error as? AudioProcessorError, case .insufficientSamples = e { return true }
        return false
    }

    private func telemetryMode(for mode: FnKeyStateMachine.RecordingMode) -> TelemetryDictationMode {
        switch mode {
        case .persistent: return .persistent
        case .holdToTalk: return .hold
        }
    }

    private func telemetryCancelReason(for reason: DictationFlowCancelReason) -> TelemetryDictationCancelReason {
        switch reason {
        case .escape: return .escape
        case .ui: return .ui
        }
    }

    private func startRecordingTask(
        mode: FnKeyStateMachine.RecordingMode,
        generation: Int,
        sessionID: Int
    ) {
        let trigger = currentTrigger
        recordingTask = Task { @MainActor in
            do {
                try await self.serviceSession.startRecording(
                    sessionID: sessionID,
                    context: DictationTelemetryContext(trigger: trigger, mode: self.telemetryMode(for: mode))
                )
                let serviceState = await self.serviceSession.state
                guard case .recording = serviceState else {
                    self.dictationLog.notice(
                        "start_recording_aborted gen=\(generation) session=\(sessionID) flowState=\(self.describeState(self.stateMachine.state), privacy: .public) serviceState=\(self.describeServiceState(serviceState), privacy: .public)"
                    )
                    // Send startFailed so the flow state machine exits startingService.
                    // Without this, the flow gets stuck with no recovery event.
                    self.sendEvent(.startFailed(generation: generation, message: "Recording could not start — please try again"))
                    return
                }
                guard !Task.isCancelled else { return }
                self.sendEvent(.recordingStarted(generation: generation))
                await self.runRecordingLevelLoop()
            } catch {
                guard !Task.isCancelled else { return }
                self.dictationLog.error(
                    "start_recording_failed gen=\(generation) session=\(sessionID) error=\(error.localizedDescription, privacy: .public)"
                )
                self.sendEvent(.startFailed(generation: generation, message: error.localizedDescription))
            }
        }
    }

    private func stopRecordingTask(generation: Int, sessionID: Int) {
        actionTask = Task { @MainActor in
            do {
                let serviceState = await self.serviceSession.state
                self.dictationLog.notice(
                    "stop_recording_requested gen=\(generation) session=\(sessionID) flowState=\(self.describeState(self.stateMachine.state), privacy: .public) serviceState=\(self.describeServiceState(serviceState), privacy: .public)"
                )
                let result = try await self.serviceSession.stopRecording(sessionID: sessionID)
                guard !Task.isCancelled else { return }
                self.consumeDictationResult(result)
                self.sendEvent(.transcriptionCompleted(generation: generation))
            } catch {
                self.handleTranscriptionFailure(error, generation: generation, phase: "stop")
            }
        }
    }

    private func undoCancelTask(generation: Int) {
        actionTask = Task { @MainActor in
            do {
                let result = try await self.serviceSession.undoCancel()
                guard !Task.isCancelled else { return }
                self.consumeDictationResult(result)
                Telemetry.send(.dictationUndoUsed)
                self.sendEvent(.transcriptionCompleted(generation: generation))
            } catch {
                self.handleTranscriptionFailure(error, generation: generation, phase: "undo")
            }
        }
    }

    private func consumeDictationResult(_ result: DictationResult) {
        currentDictation = result.dictation
        pendingPostPasteAction = result.postPasteAction
    }

    private func handleTranscriptionFailure(_ error: Error, generation: Int, phase: String) {
        guard !Task.isCancelled else { return }
        if isNoSpeechError(error) {
            dictationLog.notice("dictation_completed gen=\(generation) outcome=\(phase, privacy: .public)_no_speech")
            sendEvent(.transcriptionFailedNoSpeech(generation: generation))
        } else {
            dictationLog.error("dictation_completed gen=\(generation) outcome=\(phase, privacy: .public)_failed error=\(error.localizedDescription, privacy: .public)")
            sendEvent(.transcriptionFailed(generation: generation, message: error.localizedDescription))
        }
    }

    private func runRecordingLevelLoop() async {
        let (autoStopEnabled, silenceDelay) = (settingsViewModel.silenceAutoStop, settingsViewModel.silenceDelay)
        var lastNonSilenceAt = Date()
        var didAutoStop = false

        while !Task.isCancelled {
            let snapshot = await serviceSession.recordingSnapshot()
            guard case .recording = snapshot.state else { break }

            let level = snapshot.audioLevel
            overlayViewModel?.audioLevel = level

            if autoStopEnabled {
                let now = Date()
                if level >= Self.silenceAutoStopThreshold {
                    lastNonSilenceAt = now
                } else if !didAutoStop, now.timeIntervalSince(lastNonSilenceAt) >= silenceDelay {
                    didAutoStop = true
                    stopDictation()
                    break
                }
            }

            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func commandFailureBucket(for error: Error) -> String {
        if let accessibilityError = error as? AccessibilityServiceError {
            switch accessibilityError {
            case .notAuthorized: return "accessibility_not_authorized"
            case .noFocusedElement: return "no_focused_element"
            case .noSelectedText: return "no_selected_text"
            case .textTooLong: return "selection_too_long"
            case .unsupportedElement: return "unsupported_element"
            }
        }
        if error is ClipboardServiceError { return "paste_failed" }
        return "unknown"
    }

    private func describeState(_ state: DictationFlowState) -> String {
        switch state {
        case .idle: return "idle"
        case .ready: return "ready"
        case .checkingEntitlements: return "checkingEntitlements"
        case .startingService: return "startingService"
        case .recording: return "recording"
        case .pendingStop: return "pendingStop"
        case .processing: return "processing"
        case .cancelCountdown: return "cancelCountdown"
        case .finishing(let outcome):
            switch outcome {
            case .success: return "finishing.success"
            case .pasteFailedCopied: return "finishing.pasteFailed"
            case .noSpeech: return "finishing.noSpeech"
            case .error: return "finishing.error"
            }
        }
    }

    private func describeServiceState(_ state: DictationState) -> String {
        switch state {
        case .idle: return "idle"
        case .recording: return "recording"
        case .processing: return "processing"
        case .cancelled: return "cancelled"
        case .success: return "success"
        case .error: return "error"
        }
    }
}
