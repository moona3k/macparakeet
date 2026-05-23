import AppKit
import OSLog
import MacParakeetCore
import MacParakeetViewModels

struct DictationProcessingLoadCaptionTiming: Sendable {
    static let production = DictationProcessingLoadCaptionTiming(
        graceMs: 600,
        escalationMs: 4000,
        failureDisplayMs: 2000
    )

    let graceMs: Int
    let escalationMs: Int
    let failureDisplayMs: Int
}

protocol DictationSTTReadinessChecking: Sendable {
    func isReady() async -> Bool
}

extension STTRuntime: DictationSTTReadinessChecking {}

private enum ProcessingLoadCaptionOutcome {
    case success
    case noSpeech
    case failure
    case cancelled

    var telemetryValue: String {
        switch self {
        case .success: return "success"
        case .noSpeech: return "no_speech"
        case .failure: return "failure"
        case .cancelled: return "cancelled"
        }
    }
}

@MainActor
final class DictationFlowCoordinator {
    private static let silenceAutoStopThreshold: Float = 0.03

    // MARK: - Public Interface

    /// True whenever the dictation overlay is showing. Used by presentation-conflict
    /// guards (e.g. the idle-pill suppressor when a meeting recording ends) to prevent
    /// surfaces from colliding with the overlay.
    ///
    /// NOTE: this returns true during terminal display states (success checkmark,
    /// no-speech leaf, error card). For menu bar icon decisions, use
    /// `menuBarPreference` (or `isCapturingAudio` for capture-only semantics)
    /// instead.
    var isDictationActive: Bool { overlayController != nil }

    /// Preferred menu bar icon state for dictation, derived from flow state.
    /// Returns nil when dictation has no visual preference and global resolver
    /// should fall through to other subsystems (e.g. file transcription).
    var menuBarPreference: BreathWaveIcon.MenuBarState? {
        Self.menuBarPreference(for: stateMachine.state)
    }

    /// True only while audio is actively being captured or in-flight transcription
    /// is running.
    ///
    /// Returns false for:
    ///   - `.idle`, `.ready`, `.checkingEntitlements` — no overlay or audio yet
    ///   - `.cancelCountdown` — capture already stopped via `.cancelRecording(reason:)`;
    ///     state machine explicitly emits `.updateMenuBar(.idle)` at this transition
    ///     (see `DictationFlowStateMachine.swift:299`)
    ///   - `.finishing(...)` — terminal display states, audio already stopped
    ///
    var isCapturingAudio: Bool {
        Self.isCapturingAudio(for: stateMachine.state)
    }

    /// Mode that an active dictation hotkey manager must preserve if global
    /// taps are rebuilt while dictation is starting or recording.
    var hotkeyRecordingMode: FnKeyStateMachine.RecordingMode? {
        switch stateMachine.state {
        case .checkingEntitlements(let mode), .startingService(let mode), .recording(let mode):
            return mode
        case .idle, .ready, .pendingStop, .processing, .cancelCountdown, .finishing:
            return nil
        }
    }

    static func menuBarPreference(for state: DictationFlowState) -> BreathWaveIcon.MenuBarState? {
        switch state {
        case .startingService, .recording, .pendingStop:
            return .recording
        case .processing:
            return .processing
        case .idle, .ready, .checkingEntitlements, .cancelCountdown, .finishing:
            return nil
        }
    }

    static func isCapturingAudio(for state: DictationFlowState) -> Bool {
        switch state {
        case .startingService, .recording, .pendingStop, .processing:
            return true
        case .idle, .ready, .checkingEntitlements, .cancelCountdown, .finishing:
            return false
        }
    }

    static func pasteFailureMessage(for error: Error, copiedToClipboard copied: Bool) -> String {
        let clipboardError = error as? ClipboardServiceError

        if copied {
            if case .accessibilityPermissionRequired? = clipboardError {
                return "Accessibility permission is required for auto-paste. Copied to clipboard. Press Cmd+V."
            }
            return "Copied to clipboard. Press Cmd+V."
        }

        if case .accessibilityPermissionRequired? = clipboardError {
            return "Accessibility permission is required for auto-paste, but the clipboard could not be updated."
        }

        return "Paste failed and the clipboard could not be updated."
    }

    /// Set after init; updated when dictation hotkey managers are recreated.
    var hotkeyManagers: [HotkeyManager] = []

    // MARK: - Dependencies

    private let serviceSession: DictationServiceSession
    private let clipboardService: ClipboardServiceProtocol
    private let entitlementsService: EntitlementsService
    private let dictationRepo: DictationRepository
    private let settingsViewModel: SettingsViewModel
    private let sttRuntime: any DictationSTTReadinessChecking
    private let runtimePreferences: AppRuntimePreferencesProtocol
    private let captionTiming: DictationProcessingLoadCaptionTiming
    private let overlayControllerFactory: @MainActor (DictationOverlayViewModel) -> any DictationOverlayControlling
    private let shouldSuppressIdlePill: () -> Bool
    /// When true, `startDictation` is a no-op. Used to gate real dictation while
    /// onboarding is visible (the model isn't ready yet and the hotkey step runs
    /// its own no-STT rehearsal). Covers both the hotkey and idle-pill paths.
    private let isStartSuppressed: () -> Bool
    private let onMenuBarIconUpdate: (BreathWaveIcon.MenuBarState) -> Void
    private let onHistoryReload: () -> Void
    private let onPresentEntitlementsAlert: (Error) -> Void

    // MARK: - State Machine

    private var stateMachine = DictationFlowStateMachine()
    private let dictationLog = Logger(subsystem: "com.macparakeet.app", category: "DictationFlow")

    // MARK: - UI Resources (managed by effect executor)

    private var overlayController: (any DictationOverlayControlling)?
    private var overlayViewModel: DictationOverlayViewModel?
    private var idlePillController: IdlePillController?
    private var readyDismissTimer: DispatchWorkItem?
    private var recordingTask: Task<Void, Never>?
    private var actionTask: Task<Void, Never>?
    private var cancelCountdownTask: Task<Void, Never>?
    private var displayDismissTask: Task<Void, Never>?
    private var captionGraceTimer: DispatchWorkItem?
    private var captionEscalationTimer: DispatchWorkItem?
    private var captionFailureDismissTask: Task<Void, Never>?
    private var captionShownAt: Date?
    private var captionGeneration = 0

    // MARK: - Flow Context (not state machine concerns)

    /// Telemetry trigger for the current dictation flow.
    private var currentTrigger: TelemetryDictationTrigger = .hotkey
    /// The Dictation object from the most recent transcription, used for paste + DB save.
    private var currentDictation: Dictation?
    /// Ephemeral post-paste action from the text processing pipeline (e.g., simulate Return key).
    private var pendingPostPasteAction: KeyAction?
    /// Error from the most recent entitlements check failure, consumed by presentEntitlementsAlert effect.
    private var lastEntitlementsError: Error?
    /// Suppresses repeat mic-permission alerts within a session once the user has been shown the recovery prompt.
    private var micPermissionAlertShown = false
    private var readyPillDismissDelayMs: Int {
        (hotkeyManagers.first?.tapThresholdMs ?? FnKeyStateMachine.defaultTapThresholdMs) * 2
    }

    // MARK: - Init

    init(
        dictationService: DictationService,
        clipboardService: ClipboardServiceProtocol,
        entitlementsService: EntitlementsService,
        dictationRepo: DictationRepository,
        settingsViewModel: SettingsViewModel,
        sttRuntime: any DictationSTTReadinessChecking,
        runtimePreferences: AppRuntimePreferencesProtocol,
        captionTiming: DictationProcessingLoadCaptionTiming = .production,
        overlayControllerFactory: @escaping @MainActor (DictationOverlayViewModel) -> any DictationOverlayControlling = {
            DictationOverlayController(viewModel: $0)
        },
        shouldSuppressIdlePill: @escaping () -> Bool = { false },
        isStartSuppressed: @escaping () -> Bool = { false },
        onMenuBarIconUpdate: @escaping (BreathWaveIcon.MenuBarState) -> Void,
        onHistoryReload: @escaping () -> Void,
        onPresentEntitlementsAlert: @escaping (Error) -> Void
    ) {
        self.serviceSession = DictationServiceSession(service: dictationService)
        self.clipboardService = clipboardService
        self.entitlementsService = entitlementsService
        self.dictationRepo = dictationRepo
        self.settingsViewModel = settingsViewModel
        self.sttRuntime = sttRuntime
        self.runtimePreferences = runtimePreferences
        self.captionTiming = captionTiming
        self.overlayControllerFactory = overlayControllerFactory
        self.shouldSuppressIdlePill = shouldSuppressIdlePill
        self.isStartSuppressed = isStartSuppressed
        self.onMenuBarIconUpdate = onMenuBarIconUpdate
        self.onHistoryReload = onHistoryReload
        self.onPresentEntitlementsAlert = onPresentEntitlementsAlert
        observeFormatterNotifications()
    }

    // MARK: - AI Formatter pill transitions

    /// Observer token for `.macParakeetAIFormatterDidStart` — retained for the
    /// lifetime of the coordinator so the pill can promote itself from
    /// `.processing` to `.formatting` whenever the LLM formatter is about to
    /// run on a dictation transcript.
    private var formatterDidStartObserver: NSObjectProtocol?

    private func observeFormatterNotifications() {
        formatterDidStartObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterDidStart,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Only react to dictation-sourced formatter starts. The file
            // transcription flow posts the same notification but routes
            // through a different UI surface.
            guard (note.userInfo?["source"] as? String) == "dictation" else { return }
            // The observer is registered with `queue: .main`, so this block
            // runs on the main thread — but Swift 6 strict concurrency
            // requires explicit actor hopping before touching a
            // `@MainActor`-isolated method. A `Task { @MainActor in ... }`
            // hop is both correct and compile-safe across Swift 5/6.
            Task { @MainActor [weak self] in
                self?.promoteOverlayToFormatting()
            }
        }
    }

    /// Flip the overlay pill into `.formatting` if — and only if — it's
    /// currently in `.processing`. Any other state (cancelled, noSpeech,
    /// success, error, or already-formatting) is left untouched to avoid
    /// clobbering terminal transitions that may have raced ahead.
    private func promoteOverlayToFormatting() {
        guard let vm = overlayViewModel else { return }
        if case .processing = vm.state {
            dismissCaption(outcome: .success)
            vm.isHovered = false
            vm.hoverTooltip = nil
            vm.state = .formatting
        }
    }

    // NOTE: no `deinit` cleanup for `formatterDidStartObserver`. This
    // coordinator is effectively a singleton for the app's lifetime, the
    // observer block captures `[weak self]`, and Swift 6 forbids touching
    // `@MainActor`-isolated stored properties from a nonisolated deinit.
    // NotificationCenter cleans up automatically when the token drops.

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
        // Suppressed while onboarding is up — the speech model isn't ready and
        // the hotkey step runs its own no-STT rehearsal. Covers hotkey + pill.
        guard !isStartSuppressed() else { return }
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

            let controller = overlayControllerFactory(vm)
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

                let controller = overlayControllerFactory(vm)
                controller.show()
                overlayController = controller
            }
            vm.recordingMode = mode
            vm.processingMessage = nil
            vm.busyProcessingMessage = nil
            vm.processingLoadCaption = nil
            vm.state = .recording
            vm.startTimer()

        case .showProcessingState:
            overlayViewModel?.stopTimer()
            overlayViewModel?.processingMessage = nil
            overlayViewModel?.busyProcessingMessage = nil
            overlayViewModel?.processingLoadCaption = nil
            overlayViewModel?.state = .processing
            armProcessingLoadCaption()

        case .showBusyProcessingHint:
            overlayViewModel?.showBusyProcessingHint()

        case .showCancelCountdown:
            overlayViewModel?.stopTimer()
            overlayViewModel?.cancelTimeRemaining = 5.0
            overlayViewModel?.state = .cancelled(timeRemaining: 5.0)

        case .showSuccess:
            dismissCaption(outcome: .success)
            overlayViewModel?.state = .success

        case .showNoSpeech:
            dismissCaption(outcome: .noSpeech)
            overlayViewModel?.state = .noSpeech

        case .showError(let message):
            showErrorAfterCaptionFailureIfNeeded(message: message)

        case .hideOverlay:
            dismissCaption(outcome: .cancelled)
            overlayController?.hide()
            overlayController = nil
            overlayViewModel = nil

        case .dismissReadyPill:
            dismissCaption(outcome: .cancelled)
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
                let pastedToAppAtDispatch = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

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
                    if let pastedToApp = pastedToAppAtDispatch {
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
                    let bucket = Self.commandFailureBucket(for: error)
                    self.dictationLog.error("dictation_paste_failed gen=\(gen) bucket=\(bucket, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                    if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        // Pure action-only dictation (e.g., "press return") — nothing to paste
                        self.sendEvent(.pasteFailed(generation: gen, message: "Keystroke failed. Check Accessibility permissions."))
                    } else {
                        let copied = await self.clipboardService.copyToClipboard(transcript)
                        let message = Self.pasteFailureMessage(for: error, copiedToClipboard: copied)

                        self.sendEvent(
                            .pasteFailed(
                                generation: gen,
                                message: message
                            )
                        )
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
            hotkeyManagers.forEach { $0.resetToIdle() }

        case .notifyHotkeyCancelledByUI:
            hotkeyManagers.forEach { $0.notifyCancelledByUI() }

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
            dismissCaption(outcome: .cancelled)

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

    var processingLoadCaptionForTesting: DictationOverlayViewModel.ProcessingLoadCaption? {
        overlayViewModel?.processingLoadCaption
    }

    var overlayStateForTesting: DictationOverlayViewModel.OverlayState? {
        overlayViewModel?.state
    }

    private func armProcessingLoadCaption() {
        captionGeneration += 1
        let generation = captionGeneration
        captionGraceTimer?.cancel()
        captionEscalationTimer?.cancel()
        captionFailureDismissTask?.cancel()
        captionGraceTimer = nil
        captionEscalationTimer = nil
        captionFailureDismissTask = nil
        captionShownAt = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard await !self.sttRuntime.isReady() else { return }
            guard self.captionGeneration == generation else { return }
            guard let state = self.overlayViewModel?.state, case .processing = state else { return }

            let grace = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    await self?.fireCaption(generation: generation)
                }
            }
            self.captionGraceTimer = grace
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(self.captionTiming.graceMs),
                execute: grace
            )
        }
    }

    private func fireCaption(generation: Int) async {
        guard captionGeneration == generation else { return }
        guard overlayViewModel?.processingLoadCaption == nil else { return }
        guard let state = overlayViewModel?.state, case .processing = state else { return }
        guard await !sttRuntime.isReady() else { return }
        guard captionGeneration == generation else { return }
        guard overlayViewModel?.processingLoadCaption == nil else { return }
        guard let state = overlayViewModel?.state, case .processing = state else { return }

        let firstInstall = !runtimePreferences.hasCompletedFirstDictation
        overlayViewModel?.processingLoadCaption = .preparing
        captionShownAt = Date()
        Telemetry.send(.dictationFirstLoadCaptionShown(firstInstall: firstInstall))

        guard firstInstall else { return }
        let escalation = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard self?.captionGeneration == generation else { return }
                guard self?.overlayViewModel?.processingLoadCaption == .preparing else { return }
                self?.overlayViewModel?.processingLoadCaption = .preparingExtended
            }
        }
        captionEscalationTimer = escalation
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(captionTiming.escalationMs),
            execute: escalation
        )
    }

    private func dismissCaption(outcome: ProcessingLoadCaptionOutcome) {
        captionGeneration += 1
        captionGraceTimer?.cancel()
        captionEscalationTimer?.cancel()
        captionFailureDismissTask?.cancel()
        captionGraceTimer = nil
        captionEscalationTimer = nil
        captionFailureDismissTask = nil

        if let shownAt = captionShownAt {
            let durationMs = max(0, Int(Date().timeIntervalSince(shownAt) * 1000))
            Telemetry.send(.dictationFirstLoadCaptionDuration(
                durationMs: durationMs,
                outcome: outcome.telemetryValue
            ))
            captionShownAt = nil
        }
        overlayViewModel?.processingLoadCaption = nil
    }

    private func showErrorAfterCaptionFailureIfNeeded(message: String) {
        captionGraceTimer?.cancel()
        captionEscalationTimer?.cancel()
        captionGraceTimer = nil
        captionEscalationTimer = nil

        switch overlayViewModel?.processingLoadCaption {
        case .preparing, .preparingExtended:
            overlayViewModel?.processingLoadCaption = .failed
            captionFailureDismissTask?.cancel()
            captionFailureDismissTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(self.captionTiming.failureDisplayMs))
                guard !Task.isCancelled else { return }
                self.dismissCaption(outcome: .failure)
                self.overlayViewModel?.state = .error(message)
            }
        default:
            dismissCaption(outcome: .failure)
            overlayViewModel?.state = .error(message)
        }
    }

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
                    context: DictationTelemetryContext(
                        trigger: trigger,
                        mode: self.telemetryMode(for: mode)
                    )
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
                if Self.isMicrophonePermissionDenied(error) {
                    self.maybePresentMicPermissionAlert()
                    self.sendEvent(.startFailed(generation: generation, message: "Microphone access required"))
                } else {
                    self.sendEvent(.startFailed(generation: generation, message: error.localizedDescription))
                }
            }
        }
    }

    private static func isMicrophonePermissionDenied(_ error: Error) -> Bool {
        if let audioError = error as? AudioProcessorError,
           case .microphonePermissionDenied = audioError {
            return true
        }
        return false
    }

    /// Shows the macOS Privacy -> Microphone recovery prompt at most once per app launch.
    /// The alert is dispatched asynchronously so the flow state machine processes
    /// the `.startFailed` event before any no-window modal fallback is needed.
    private func maybePresentMicPermissionAlert() {
        guard !micPermissionAlertShown else { return }
        micPermissionAlertShown = true
        Task { @MainActor in
            await self.presentMicPermissionAlert()
        }
    }

    private func presentMicPermissionAlert() async {
        let alert = NSAlert()
        alert.messageText = "Microphone access required"
        alert.informativeText = "MacParakeet needs microphone access to record dictation. Open System Settings → Privacy & Security → Microphone to enable it, then try again."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        let response = await presentMicPermissionAlert(alert)
        if response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func presentMicPermissionAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)

        if let window = [NSApp.keyWindow, NSApp.mainWindow].compactMap({ $0 }).first(where: \.isVisible) {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response)
                }
            }
        }

        return alert.runModal()
    }

    private func stopRecordingTask(generation: Int, sessionID: Int) {
        actionTask = Task { @MainActor in
            do {
                let serviceState = await self.serviceSession.state
                self.dictationLog.notice(
                    "stop_recording_requested gen=\(generation) session=\(sessionID) flowState=\(self.describeState(self.stateMachine.state), privacy: .public) serviceState=\(self.describeServiceState(serviceState), privacy: .public)"
                )
                await self.serviceSession.updateTelemetryAppCategory(
                    TelemetryAppCategory(
                        bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    ),
                    sessionID: sessionID
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
                let sessionID = self.serviceSession.currentSessionID
                await self.serviceSession.updateTelemetryAppCategory(
                    TelemetryAppCategory(
                        bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                    ),
                    sessionID: sessionID
                )
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

    static func commandFailureBucket(for error: Error) -> String {
        if let accessibilityError = error as? AccessibilityServiceError {
            switch accessibilityError {
            case .notAuthorized: return "accessibility_not_authorized"
            case .noFocusedElement: return "no_focused_element"
            case .noSelectedText: return "no_selected_text"
            case .textTooLong: return "selection_too_long"
            case .unsupportedElement: return "unsupported_element"
            }
        }
        if let clipboardError = error as? ClipboardServiceError {
            switch clipboardError {
            case .accessibilityPermissionRequired: return "paste_accessibility_permission"
            case .eventSourceUnavailable: return "paste_event_source_unavailable"
            case .eventCreationFailed: return "paste_event_creation_failed"
            case .pasteboardWriteFailed: return "pasteboard_write_failed"
            }
        }
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
