import AppKit
import MacParakeetCore
import MacParakeetViewModels

/// Owns one explicit command session. Ordinary dictation never enters this path.
@MainActor
final class VoiceControlCoordinator {
    static let holdTrigger = HotkeyTrigger.chord(modifiers: ["control", "option"], keyCode: 49)
    static var configuredHoldTrigger: HotkeyTrigger {
        guard let data = UserDefaults.standard.data(forKey: "voiceControl.holdShortcut"),
            let trigger = try? JSONDecoder().decode(HotkeyTrigger.self, from: data)
        else { return holdTrigger }
        return trigger
    }
    let model = VoiceControlViewModel()
    private let speech: VoiceControlSpeechSession
    private let adapter: any VoiceControlAdapter
    private var literalMode = false
    private let submissions = VoiceControlSubmissionState()
    private let rewrite: VoiceControlCommandRouter.Rewrite?
    private let credentials = VoiceControlCredentialStore()
    private let consent = VoiceControlConsentStore()
    private let traces = VoiceControlTraceStore()
    private let isStartSuppressed: () -> Bool
    private let conflictingHotkeys: () -> [HotkeyTrigger]
    private let onShortcutChanged: () -> Void
    private var runner: VoiceControlTurnRunner?
    private var panel: VoiceControlPanelController?
    private var hotkey: HotkeyManager?
    private var speechEvents: Task<Void, Never>?
    private var runnerEvents: Task<Void, Never>?
    private var execution: Task<Void, Never>?
    private var capture: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var admissionRelease: Task<Void, Never>?
    private var invocationSnapshot: VoiceControlSnapshot?
    private var speechSubmission = false
    private var skipInvocationSnapshot = false
    private var currentCaptureID: UUID?
    private var currentUtteranceID: UUID?
    private var invocationSnapshotTask: Task<VoiceControlSnapshot?, Never>?
    private var interactionLease: GUIMutationArbiter.Lease?
    private var sessionGeneration = 0
    private var wantsCapture = false
    private var handsFree = false
    private var acceptingEvents = false
    private var globalEscape: Any?
    private var localEscape: Any?

    init(
        sharedMicStream: SharedMicrophoneStream, scheduler: STTScheduler,
        adapter: any VoiceControlAdapter,
        rewrite: VoiceControlCommandRouter.Rewrite? = nil,
        onShortcutRecording: @escaping (Bool) -> Void = { _ in },
        onShortcutChanged: @escaping () -> Void = {},
        isStartSuppressed: @escaping () -> Bool = { false },
        conflictingHotkeys: @escaping () -> [HotkeyTrigger] = { [] }
    ) {
        speech = VoiceControlSpeechSession(audio: AudioProcessor(sharedMicStream: sharedMicStream), stt: scheduler)
        self.adapter = adapter
        self.rewrite = rewrite
        self.isStartSuppressed = isStartSuppressed
        self.conflictingHotkeys = conflictingHotkeys
        self.onShortcutChanged = onShortcutChanged
        model.consent = consent.hasConsent
        model.writingConsent = UserDefaults.standard.bool(forKey: "voiceControl.writingConsent.v1")
        model.holdTrigger = Self.configuredHoldTrigger
        model.validateShortcut = { [weak self] trigger in
            if self?.conflictingHotkeys().contains(where: { trigger.conflicts(with: $0) }) == true {
                return .blocked("This shortcut is already used by another capture action.")
            }
            return .allowed
        }
        model.onShortcutRecording = { [weak self] recording in
            if recording { self?.suspendHotkey() }
            onShortcutRecording(recording)
            if !recording { self?.installHotkey() }
        }
        model.needsSetup = !consent.hasConsent || (try? credentials.loadAPIKey()) == nil
        model.diagnosticsLogPath = VoiceControlTraceStore.defaultLatestURL.path
        model.onListen = { [weak self] in self?.beginCapture(handsFree: true) }
        model.onCommit = { [weak self] in self?.commitCapture() }
        model.onStop = { [weak self] in self?.stop() }
        model.onStopListening = { [weak self] in self?.stopListening() }
        model.onCancel = { [weak self] in self?.cancelTask() }
        model.onEnd = { [weak self] in self?.end() }
        model.onRefreshDiagnostics = { [weak self] in self?.refreshDiagnostics() }
        model.onCopyDiagnostics = { [weak self] in self?.refreshDiagnostics(copy: true) }
        model.onOpenDiagnosticsFolder = { [weak self] in self?.openDiagnosticsFolder() }
        model.onCopyDiagnosticsPath = { [weak self] in self?.copyDiagnosticsPath() }
        model.onConfirm = { [weak self] in self?.confirm() }
        model.onResume = { [weak self] in self?.resume() }
        model.onSubmit = { [weak self] in self?.submit($0) }
        model.onSaveSetup = { [weak self] in self?.saveSetup() }
        model.onRevokeConsent = { [weak self] in
            guard let self else { return }
            self.consent.hasConsent = false
            self.model.needsSetup = true
            self.end(hide: false)
            self.model.message = "Cloud control is disabled. Normal dictation stays local."
        }
        model.onRevokeWritingConsent = {
            UserDefaults.standard.set(false, forKey: "voiceControl.writingConsent.v1")
        }
        model.onScreenTextChanged = { [weak self] enabled in
            UserDefaults.standard.set(enabled, forKey: AppFeatures.voiceControlScreenTextDefaultsKey)
            if enabled, !VisionScreenTextReader.hasScreenRecordingAccess {
                _ = VisionScreenTextReader.requestScreenRecordingAccess()
            }
            // The adapter is built once at launch; a new one picks up the setting.
            self?.model.message = "Restart Voice Control (End, then Start) to apply."
        }
        model.onDisable = { [weak self] in
            guard let self else { return }
            self.consent.hasConsent = false
            try? self.credentials.saveAPIKey("")
            self.model.consent = false; self.model.needsSetup = true
            self.end(hide: false)
        }
        model.onSettings = { [weak self] in
            self?.end(hide: false)
            self?.model.needsSetup = true
            self?.show()
        }
        speechEvents = Task { [weak self, speech] in
            for await event in speech.events {
                guard !Task.isCancelled else { return }
                self?.handleSpeech(event)
            }
        }
        startInboxMonitor()
    }

    func installHotkey() {
        hotkey?.stop(); hotkey = nil
        installTakeoverMonitors()
        guard !conflictingHotkeys().contains(where: { Self.configuredHoldTrigger.conflicts(with: $0) }) else {
            model.message =
                "\(Self.configuredHoldTrigger.displayName) conflicts with another shortcut. Start from the Voice Control menu or change the shortcut in Setup."
            return
        }
        let manager = HotkeyManager(
            trigger: Self.configuredHoldTrigger, gestureMode: .holdOnly,
            holdToTalkStopTailMs: AppHotkeyCoordinator.holdToTalkStopTailMs)
        manager.onStartRecording = { [weak self] _ in self?.beginCapture(handsFree: false) }
        manager.onStopRecording = { [weak self] in self?.commitCapture() }
        manager.onCancelRecording = { [weak self] in self?.stopListening() }
        manager.onDiscardRecording = { [weak self] _ in self?.stopListening() }
        manager.onEscapeWhileIdle = { [weak self] in self?.stop() }
        if manager.start() {
            hotkey = manager
        } else {
            model.message = "The shortcut could not start. Check Accessibility permission, or use Start listening."
        }
    }
    private func installTakeoverMonitors() {
        if globalEscape == nil {
            let mask: NSEvent.EventTypeMask = [
                .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel,
            ]
            globalEscape = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
                let marked = event.cgEvent.map(StreamingCursorEventMarker.isMarked) ?? false
                let key = event.type == .keyDown ? event.keyCode : nil
                let flags = event.modifierFlags.rawValue
                Task { @MainActor in self?.handleExternalInput(key: key, flags: flags, marked: marked) }
            }
            localEscape = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
                guard let self else { return event }
                if event.type == .keyDown, event.keyCode == 53 { self.stop(); return event }
                if self.panel?.owns(event: event) == true { return event }
                let marked = event.cgEvent.map(StreamingCursorEventMarker.isMarked) ?? false
                self.handleExternalInput(
                    key: event.type == .keyDown ? event.keyCode : nil,
                    flags: event.modifierFlags.rawValue, marked: marked)
                return event
            }
        }
    }
    private func handleExternalInput(key: UInt16?, flags: UInt, marked: Bool) {
        guard !marked else { return }
        if let key,
            Self.isVoiceShortcutKey(
                key, flags: NSEvent.ModifierFlags(rawValue: flags), trigger: Self.configuredHoldTrigger)
        {
            return
        }
        if interactionLease == nil {
            if model.phase == .paused, let runner {
                submissions.invalidate()
                runner.pauseForManualInput()
            }
            return
        }
        submissions.invalidate()
        runner?.pauseForManualInput()
        speech.revokePendingTranscripts()
        currentUtteranceID = nil
        model.conversation.cancel()
        model.partialTranscript = ""
        Task { [speech] in await speech.discardPendingUtterance() }
        model.phase = .paused
        model.message = "You have control. Make your correction, then choose Continue."
        model.appendActivity(model.message)
        releaseFinishedSessionIfMicOff()
    }
    static func isVoiceShortcutKey(_ key: UInt16, flags: NSEvent.ModifierFlags, trigger: HotkeyTrigger) -> Bool {
        guard key == trigger.keyCode else { return false }
        if trigger.kind == .keyCode { return true }
        guard trigger.kind == .chord else { return false }
        let names = trigger.chordModifiers ?? []
        var expected: NSEvent.ModifierFlags = []
        for (name, flag): (String, NSEvent.ModifierFlags) in [
            ("command", .command), ("option", .option), ("control", .control), ("shift", .shift), ("fn", .function),
        ] {
            if names.contains(name) { expected.insert(flag) }
        }
        return flags.intersection([.command, .option, .control, .shift, .function]) == expected
    }
    func suspendHotkey() { hotkey?.stop() }
    func show() {
        if panel == nil { panel = VoiceControlPanelController(model: model) }
        panel?.show()
    }
    func shutdown() {
        hotkey?.stop()
        if let globalEscape { NSEvent.removeMonitor(globalEscape) }
        if let localEscape { NSEvent.removeMonitor(localEscape) }
        globalEscape = nil; localEscape = nil
        end()
        speechEvents?.cancel()
    }

    private func saveSetup() {
        guard model.consent else { return }
        do {
            if !model.keyInput.isEmpty {
                try credentials.saveAPIKey(model.keyInput.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            guard let key = try credentials.loadAPIKey(), !key.isEmpty else {
                model.message = "Enter a Jev API key first."; return
            }
            if case .blocked(let message)? = model.validateShortcut?(model.holdTrigger) {
                model.message = message; return
            }
            consent.hasConsent = true
            UserDefaults.standard.set(model.writingConsent, forKey: "voiceControl.writingConsent.v1")
            UserDefaults.standard.set(try JSONEncoder().encode(model.holdTrigger), forKey: "voiceControl.holdShortcut")
            model.keyInput = ""
            model.needsSetup = false
            model.message = "Ready. Hold \(model.holdTrigger.displayName), or start a listening session."
            show()
            installHotkey()
            onShortcutChanged()
        } catch { model.message = "Could not save the API key to Keychain." }
    }

    private func ensureSession() -> Bool {
        guard cleanup == nil, admissionRelease == nil, !isStartSuppressed() else {
            model.message = "Finishing the previous action. Try again in a moment."
            return false
        }
        if interactionLease != nil { return true }
        guard consent.hasConsent, let key = try? credentials.loadAPIKey(), !key.isEmpty else {
            model.needsSetup = true; show(); return false
        }
        guard let lease = GUIMutationArbiter.shared.acquire(.voiceControl) else {
            model.message = "Finish the current dictation or Transform first."; show(); return false
        }
        interactionLease = lease
        if runner != nil { show(); return true }
        acceptingEvents = true
        sessionGeneration += 1
        let traces = traces
        let engine = JevDecisionClient(
            apiKey: key,
            consent: {
                UserDefaults.standard.bool(forKey: "voiceControl.cloudContextConsent.v1")
            },
            onDecision: { decision in await traces.noteDecision(decision) })
        let router = VoiceControlCommandRouter(
            fallback: engine, rewrite: rewrite,
            selectionAtInvocation: { [weak self] in
                await MainActor.run { self?.invocationSnapshot }
            })
        let runner = VoiceControlTurnRunner(adapter: adapter, engine: router, sink: traces)
        self.runner = runner
        runnerEvents?.cancel()
        runnerEvents = Task { [weak self, runner] in
            for await event in runner.events {
                guard !Task.isCancelled, let self, self.acceptingEvents else { return }
                self.model.apply(event)
                let phase = "\(self.model.phase)"
                let message = self.model.message
                Task { await self.traces.noteStatus(phase: phase, message: message) }
                switch event {
                case .completed, .failed, .cancelled, .paused: self.releaseFinishedSessionIfMicOff()
                default: break
                }
            }
        }
        show()
        return true
    }

    private func beginCapture(handsFree: Bool) {
        guard ensureSession(), !wantsCapture else { return }
        if model.conversation.shouldPauseForSpeech { submissions.invalidate(); runner?.stop() }
        wantsCapture = true
        self.handsFree = handsFree
        let generation = sessionGeneration
        let captureID = UUID()
        currentCaptureID = captureID
        currentUtteranceID = nil
        model.microphoneOn = true
        model.phase = .listening
        model.message =
            handsFree
            ? "Listening. Pause after an instruction. Say ‘stop listening’ to turn the mic off."
            : "Listening. Release the shortcut to act."
        if model.conversation.shouldPauseForSpeech {
            invocationSnapshotTask = Task { [adapter] in
                return try? await adapter.observe()
            }
        }
        capture = Task { [weak self, speech] in
            do {
                guard let self, self.sessionGeneration == generation, self.acceptingEvents else { return }
                try await speech.begin(handsFree: handsFree, captureID: captureID)
                guard self.sessionGeneration == generation else { return }

            } catch {
                guard let self, self.sessionGeneration == generation else { return }
                self.wantsCapture = false; self.model.microphoneOn = false
                self.model.phase = .failed;
                self.model.message = "Could not start the microphone. Check microphone permission."
                self.releaseFinishedSessionIfMicOff()
            }
        }
    }
    private func commitCapture() {
        guard wantsCapture else { return }
        wantsCapture = false; model.microphoneOn = false
        hotkey?.resetToIdle()
        let previous = capture
        capture = Task { [speech] in
            await previous?.value
            await speech.commit()
        }
    }
    private func handleSpeech(_ event: VoiceControlSpeechEvent) {
        guard acceptingEvents else { return }
        switch event {
        case .listening(let capture, let utterance):
            guard currentCaptureID == capture, speech.isCurrentUtterance(utterance) else { return }
            currentUtteranceID = utterance
            if wantsCapture { model.phase = .listening }
        case .speechBegan(let capture, let utterance):
            guard currentCaptureID == capture, wantsCapture, speech.isCurrentUtterance(utterance) else { return }
            if model.phase == .transcribing {
                model.appendActivity("The previous speech recognition was superseded by your new instruction.")
            }
            currentUtteranceID = utterance
            if model.conversation.shouldPauseForSpeech { submissions.invalidate(); runner?.stop() }
            model.phase = .listening; model.message = "Listening to your next instruction…"
            if model.conversation.shouldPauseForSpeech {
                invocationSnapshotTask?.cancel()
                invocationSnapshotTask = Task { [adapter] in try? await adapter.observe() }
            }
        case .level(let level, let capture):
            if currentCaptureID == capture { model.audioLevel = level }
        case .partial(let text, let capture, let utterance):
            guard currentCaptureID == capture, currentUtteranceID == utterance, speech.isCurrentUtterance(utterance)
            else { return }
            model.partialTranscript = text
            // Revoking is safe on a partial. No effect or resume is authorized here.
            let control = text.lowercased().trimmingCharacters(
                in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if ["stop", "stop listening", "cancel", "command stop"].contains(control) {
                submissions.invalidate(); runner?.stop()
            }
        case .transcribing(let capture, let utterance):
            guard currentCaptureID == capture, currentUtteranceID == utterance, speech.isCurrentUtterance(utterance)
            else { return }
            model.phase = .transcribing; model.message = "Recognizing speech on this Mac…"
        case .transcript(let text, let capture, let utterance):
            guard currentCaptureID == capture, currentUtteranceID == utterance, speech.isCurrentUtterance(utterance)
            else { return }
            model.partialTranscript = ""
            speechSubmission = true
            submit(text)
            speechSubmission = false
        case .stopped(let capture):
            guard currentCaptureID == capture else { return }
            if wantsCapture { stop() }
            model.microphoneOn = false; wantsCapture = false
            releaseFinishedSessionIfMicOff()
        case .failed(let message, let capture):
            guard currentCaptureID == capture else { return }
            model.phase = .failed; model.message = message
            releaseFinishedSessionIfMicOff()
        }
    }
    private func startInboxMonitor() {
        // Commands come only from the user log directory. The /tmp pointer is a
        // read-only copy of traces; a world-writable command file must not act.
        let urls = [
            VoiceControlTraceStore.defaultDirectory.appendingPathComponent("command.json")
        ]
        for url in urls {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                for url in urls {
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    let raw = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                    try? FileManager.default.removeItem(at: url)
                    guard let command = VoiceControlInboxCommand.parse(raw) else { continue }
                    self.handleInbox(command)
                    break
                }
            }
        }
    }
    private func handleInbox(_ command: VoiceControlInboxCommand) {
        Task { [weak self] in
            guard let self else { return }
            if let activate = command.activate {
                _ = await self.bringAppForward(activate)
            }
            self.show()
            self.skipInvocationSnapshot = true
            switch command.action {
            case .submit: self.submit(command.text, dryRun: command.dryRun)
            case .revise: self.dispatch(command.text, asRevision: true)
            case .continueTask: self.resume()
            case .confirm: self.confirm()
            case .stop: self.stop()
            case .cancel: self.cancelTask()
            }
        }
    }
    private func bringAppForward(_ name: String) async -> Bool {
        var app = VoiceControlAppActivation.runningApplication(matching: name)
        if app == nil {
            let bundleID: String? =
                name.lowercased().contains("chrome")
                ? "com.google.Chrome"
                : name.lowercased().contains("safari")
                    ? "com.apple.Safari"
                    : name.lowercased().contains("firefox")
                        ? "org.mozilla.firefox"
                        : name.contains(".") ? name : nil
            if let bundleID {
                app = await VoiceControlAppActivation.launch(bundleIdentifier: bundleID)
            }
        }
        guard let app else { return false }
        return await VoiceControlAppActivation.bringForward(app)
    }
    /// A dry run is a fresh proposal. It must not confirm, stop, or enter literal mode.
    nonisolated static func admitsLiveGrammar(dryRun: Bool) -> Bool { !dryRun }

    private func submit(_ text: String, dryRun: Bool = false) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, ensureSession() else { return }
        if !Self.admitsLiveGrammar(dryRun: dryRun) {
            // A proposal must not stop the turn, answer a pending question, or
            // revise the live goal. Those entry points ignore the dry-run flag.
            if runner?.hasLiveWork == true || model.conversation.expectedResponse != nil {
                return
            }
            dispatch(text, dryRun: true)
            return
        }
        let command = text.lowercased().trimmingCharacters(in: .punctuationCharacters)
        if literalMode {
            switch VoiceControlSessionGrammar.phrase(text, literalMode: true) {
            case .exitLiteral:
                literalMode = false; model.literalMode = false
                model.message = "Command mode. Instructions control the app again."
                return
            case .stopFromLiteral:
                stop(); return
            case .enterLiteral, nil:
                dismissPendingAuthorizationForLiteral()
                dispatch(Self.literalInstruction(text), asLiteralPayload: true)
                return
            }
        }
        if model.conversation.expectedResponse == .confirmation {
            if VoiceControlSessionGrammar.acceptsConfirmation(text) {
                confirm(); return
            }
            if VoiceControlSessionGrammar.declinesConfirmation(text) {
                cancelTask(); return
            }
        }
        if VoiceControlSessionGrammar.phrase(text, literalMode: false) == .enterLiteral {
            dismissPendingAuthorizationForLiteral()
            literalMode = true; model.literalMode = true
            model.message =
                "Typing mode. Words are typed. Say ‘command mode’ or ‘stop typing’ to return, or ‘command stop’ to pause."
            return
        }
        switch command {
        case "stop", "pause": stop(); return
        case "cancel", "cancel task": cancelTask(); return
        case "stop listening": stopListening(); return
        case "end voice control": end(); return
        case "resume", "continue", "continue task": resume(); return
        default: break
        }
        dispatch(text, dryRun: dryRun)
    }
    static func literalInstruction(_ text: String) -> String {
        text.lowercased().hasPrefix("type literally ") ? text : "type " + text
    }
    func explainInteractionBusy() {
        model.message =
            "Turn the Voice Control microphone off or choose End to start dictation or paste from history."
        show()
    }
    private func releaseFinishedSessionIfMicOff() {
        guard !wantsCapture, !model.microphoneOn, admissionRelease == nil,
            let lease = interactionLease, let runner
        else { return }
        switch model.phase {
        case .done, .failed, .idle, .paused: break
        default: return
        }
        let priorExecution = execution
        admissionRelease = Task { [weak self] in
            await priorExecution?.value
            await runner.waitForIdle()
            guard let self else { return }
            GUIMutationArbiter.shared.release(lease)
            if self.interactionLease == lease { self.interactionLease = nil }
            self.admissionRelease = nil
        }
    }
    private func dismissPendingAuthorizationForLiteral() {
        switch model.conversation.expectedResponse {
        case .confirmation:
            model.conversation.cancel()
            model.message = "Confirmation dismissed. That step was skipped."
        case .clarification:
            _ = model.conversation.takeClarification()
            model.message = "Question dismissed. Words will be typed."
        default:
            break
        }
    }
    private func dispatch(
        _ text: String, asRevision: Bool = false, asLiteralPayload: Bool = false, dryRun: Bool = false
    ) {
        let submission = submissions.begin()
        let correction =
            !dryRun && !asLiteralPayload
            && (asRevision || (!model.goal.isEmpty && VoiceControlConversationState.isCorrection(text)))
        if !correction && model.conversation.expectedResponse != .clarification {
            model.goal = text; model.steps = []
        }
        model.transcript = text
        if !correction {
            model.appendActivity(
                (model.conversation.expectedResponse == .clarification ? "Clarification: " : "Request: ") + text)
        }
        runner?.stop()
        guard let runner else { return }
        let clarification = !dryRun && !asLiteralPayload && model.conversation.takeClarification()
        let needsSnapshot = !speechSubmission && !skipInvocationSnapshot
        skipInvocationSnapshot = false
        let snapshotTask = invocationSnapshotTask
        let speechUtterance = currentUtteranceID
        let generation = sessionGeneration
        execution = Task { [weak self] in
            guard let self, self.submissions.accepts(submission) else { return }
            if needsSnapshot {
                self.invocationSnapshot = try? await self.adapter.observe()
            } else if let snapshotTask {
                self.invocationSnapshot = await snapshotTask.value
            }
            if !needsSnapshot, self.currentUtteranceID != speechUtterance { return }
            guard self.sessionGeneration == generation, self.acceptingEvents, self.submissions.accepts(submission)
            else { return }
            if clarification {
                await runner.clarify(text, submissionAuthority: submission)
            } else if correction {
                await runner.revise(text, submissionAuthority: submission)
            } else {
                await runner.submit(text, submissionAuthority: submission, dryRun: dryRun)
            }
        }
    }
    private func stop() {
        submissions.invalidate()
        guard interactionLease != nil else { return }
        runner?.stop()
        speech.revokePendingTranscripts()
        currentUtteranceID = nil
        model.conversation.cancel()
        model.partialTranscript = ""
        Task { [speech] in await speech.discardPendingUtterance() }
        model.phase = .paused; model.message = "Stopped. Check the app, then choose Continue."
        releaseFinishedSessionIfMicOff()
    }
    private func stopListening() {
        stop()
        wantsCapture = false; model.microphoneOn = false
        hotkey?.resetToIdle()
        currentCaptureID = nil
        let prior = capture
        capture = Task { [speech] in
            await speech.cancel()
            await prior?.value
        }
        releaseFinishedSessionIfMicOff()
    }
    private func cancelTask() {
        submissions.invalidate()
        speech.revokePendingTranscripts()
        currentUtteranceID = nil
        model.partialTranscript = ""
        Task { [speech] in await speech.discardPendingUtterance() }
        runner?.stop()
        model.conversation.cancel()
        let submission = submissions.begin()
        if let runner {
            execution = Task { [weak self] in
                guard self?.submissions.accepts(submission) == true else { return }
                await runner.cancel(submissionAuthority: submission)
            }
        }
    }
    private func confirm() {
        guard ensureSession(), let runner, model.conversation.takeConfirmation() else { return }
        let submission = submissions.currentOrBegin()
        execution = Task { [weak self] in
            guard self?.submissions.accepts(submission) == true else { return }
            await runner.confirm(submissionAuthority: submission)
        }
    }
    private func resume() {
        guard ensureSession(), let runner else { return }
        let submission = submissions.begin()
        execution = Task { [weak self] in
            guard self?.submissions.accepts(submission) == true else { return }
            await runner.continueTask(submissionAuthority: submission)
        }
    }
    private func refreshDiagnostics(copy: Bool = false) {
        let runner = runner
        let traces = traces
        Task { [weak self] in
            if let runner { await runner.flushTraces() }
            let session = await traces.loadLatest()
            let records = if let runner { await runner.traceSnapshot() } else { session?.records ?? [] }
            guard let self else { return }
            self.model.diagnosticsLogPath = VoiceControlTraceStore.defaultLatestURL.path
            if let session, let data = try? Self.sessionEncoder.encode(session),
                let text = String(data: data, encoding: .utf8)
            {
                self.model.diagnosticsText = text
                self.model.diagnosticsStatus =
                    "\(records.count) records saved locally. Instruction and control labels stay on this Mac."
            } else {
                let encoder = Self.shareableEncoder
                guard let data = try? encoder.encode(records), let text = String(data: data, encoding: .utf8) else {
                    self.model.diagnosticsStatus = "Could not format diagnostics."
                    return
                }
                self.model.diagnosticsText = records.isEmpty ? "" : text
                self.model.diagnosticsStatus =
                    records.isEmpty
                    ? "No task log yet. After a turn, latest.json is written on this Mac."
                    : "\(records.count) shareable records. Commands and labels are excluded."
            }
            if copy {
                let export = VoiceControlShareableDiagnostics.make(
                    schema: VoiceControlTraceStore.schema, taskID: session?.taskID,
                    summary: session?.summary, records: records)
                let encoder = Self.shareableEncoder
                guard let data = try? encoder.encode(export), let text = String(data: data, encoding: .utf8),
                    !records.isEmpty
                else { return }
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(text, forType: .string) {
                    self.model.diagnosticsStatus =
                        "Copied shareable diagnostics. Instruction and labels were omitted. Nothing was uploaded."
                }
            }
        }
    }
    private func openDiagnosticsFolder() {
        let latest = VoiceControlTraceStore.defaultLatestURL
        if FileManager.default.fileExists(atPath: latest.path) {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            NSWorkspace.shared.open(VoiceControlTraceStore.defaultDirectory)
        }
        model.diagnosticsStatus = "Opened the local log folder. Nothing was uploaded."
    }
    private func copyDiagnosticsPath() {
        let path = VoiceControlTraceStore.defaultLatestURL.path
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.setString(path, forType: .string) {
            model.diagnosticsStatus = "Copied log path. The file stays on this Mac."
        }
    }
    private static var sessionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
    private static var shareableEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func end(hide: Bool = true, preservePresentation: Bool = false) {
        submissions.invalidate()
        guard cleanup == nil else { return }
        runner?.stop()
        speech.revokePendingTranscripts()
        acceptingEvents = false; wantsCapture = false; sessionGeneration += 1
        model.diagnosticsText = ""
        model.diagnosticsStatus = "Task ended. Logs kept on this Mac."
        currentCaptureID = nil; currentUtteranceID = nil
        invocationSnapshotTask?.cancel(); invocationSnapshotTask = nil
        if !preservePresentation { literalMode = false; model.literalMode = false }
        model.microphoneOn = false
        hotkey?.resetToIdle()
        if hide { panel?.hide() }
        let priorAdmissionRelease = admissionRelease
        let priorCapture = capture
        let priorExecution = execution
        let currentRunner = runner
        let lease = interactionLease
        runnerEvents?.cancel()
        cleanup = Task { [weak self, speech] in
            await speech.cancel()
            await priorAdmissionRelease?.value
            await priorCapture?.value
            await priorExecution?.value
            await currentRunner?.flushTraces()
            await currentRunner?.cancelAndDrain()
            guard let self else { return }
            if let lease { GUIMutationArbiter.shared.release(lease) }
            self.interactionLease = nil; self.runner = nil; self.cleanup = nil
            self.invocationSnapshot = nil
            if !preservePresentation {
                self.model.phase = .idle; self.model.transcript = ""; self.model.goal = ""; self.model.steps = []
            }
        }
    }
}

struct VoiceControlWritingConsentRequired: LocalizedError {
    var errorDescription: String? {
        "Enable selected-text sharing with your writing provider in Voice Control setup first."
    }
}

/// Main-actor submission identity plus a thread-safe fence carried across the
/// runner actor hop. Stop invalidates preparation, not only existing effects.
@MainActor
final class VoiceControlSubmissionState {
    private var current: ActionAuthority?
    func begin() -> ActionAuthority {
        invalidate()
        let token = ActionAuthority()
        current = token
        return token
    }
    func currentOrBegin() -> ActionAuthority {
        if let current, current.isValid { return current }
        return begin()
    }
    func invalidate() { current?.revoke(); current = nil }
    func accepts(_ token: ActionAuthority) -> Bool { current === token && token.isValid }
}
