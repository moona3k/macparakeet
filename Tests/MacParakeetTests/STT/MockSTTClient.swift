import Foundation
@testable import MacParakeetCore

public actor MockSTTClient: STTClientProtocol, SpeechEngineRoutedTranscribing, STTLiveDictationTranscribing, SpeechEngineSwitching {
    public var transcribeResult: STTResult?
    public var transcribeError: Error?
    public var transcribeCallCount = 0
    public var lastAudioPath: String?
    public var lastJob: STTJobKind?
    public var audioPaths: [String] = []
    public var jobs: [STTJobKind] = []
    public var speechEngineSelections: [SpeechEngineSelection] = []
    public var warmUpCalled = false
    public var warmUpCallCount = 0
    public var warmUpError: Error?
    public var warmUpFailuresBeforeSuccess: Int = 0
    public var warmUpProgressPhases: [String]?
    public var clearModelCacheCalled = false
    public var shutdownCalled = false
    public var speechEngineSwitches: [SpeechEnginePreference] = []
    public var speechEngineSwitchError: Error?
    public var speechEngineSwitchProgressMessages: [String] = []
    public var parakeetModelVariantSwitches: [ParakeetModelVariant] = []
    public var parakeetModelVariantSwitchError: Error?
    public var nemotronModelVariantSwitches: [NemotronModelVariant] = []
    public var nemotronModelVariantSwitchError: Error?
    public var liveBeginError: Error?
    public var liveAppendError: Error?
    public var liveFinishError: Error?
    public var liveFinishResult: STTResult?
    public var liveBeginCallCount = 0
    public var liveAppendCallCount = 0
    public var liveFinishCallCount = 0
    public var liveCancelCallCount = 0
    public var liveAppendedSamples: [[Float]] = []
    public var liveEnabled = false
    private var warmUpState: STTWarmUpState = .idle
    private var warmUpObservers: [UUID: AsyncStream<STTWarmUpState>.Continuation] = [:]
    private var backgroundWarmUpTask: Task<Void, Never>?
    private var queuedTranscribeResults: [STTResult] = []
    private var queuedTranscribeErrors: [Error] = []
    private var liveSessionID: UUID?
    private var livePartialHandler: (@Sendable (String) -> Void)?
    private var liveAppendsHeld = false
    private var liveAppendHoldContinuations: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func configure(result: STTResult) {
        self.transcribeResult = result
        self.transcribeError = nil
        self.queuedTranscribeResults = []
        self.queuedTranscribeErrors = []
    }

    public func configure(error: Error) {
        self.transcribeError = error
        self.transcribeResult = nil
        self.queuedTranscribeResults = []
        self.queuedTranscribeErrors = []
    }

    public func configureSequence(results: [STTResult]) {
        self.queuedTranscribeResults = results
        self.queuedTranscribeErrors = []
        self.transcribeError = nil
        self.transcribeResult = nil
    }

    public func configureSequence(errors: [Error]) {
        self.queuedTranscribeErrors = errors
        self.queuedTranscribeResults = []
        self.transcribeError = nil
        self.transcribeResult = nil
    }

    public func configureWarmUp(error: Error? = nil, progressPhases: [String]? = nil) {
        self.warmUpError = error
        self.warmUpProgressPhases = progressPhases
    }

    public func configureWarmUpFailuresBeforeSuccess(_ count: Int) {
        self.warmUpFailuresBeforeSuccess = max(0, count)
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        transcribeCallCount += 1
        lastAudioPath = audioPath
        lastJob = job
        audioPaths.append(audioPath)
        jobs.append(job)

        if !queuedTranscribeErrors.isEmpty {
            throw queuedTranscribeErrors.removeFirst()
        }

        if !queuedTranscribeResults.isEmpty {
            return queuedTranscribeResults.removeFirst()
        }

        if let error = transcribeError {
            throw error
        }

        return transcribeResult ?? STTResult(text: "Mock transcription", words: [])
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        speechEngineSelections.append(speechEngine)
        return try await transcribe(audioPath: audioPath, job: job, onProgress: onProgress)
    }

    public func configureLive(
        result: STTResult? = nil,
        beginError: Error? = nil,
        appendError: Error? = nil,
        finishError: Error? = nil
    ) {
        liveEnabled = true
        liveFinishResult = result
        liveBeginError = beginError
        liveAppendError = appendError
        liveFinishError = finishError
        liveBeginCallCount = 0
        liveAppendCallCount = 0
        liveFinishCallCount = 0
        liveCancelCallCount = 0
        liveAppendedSamples = []
        liveSessionID = nil
        livePartialHandler = nil
        releaseLiveAppends()
    }

    public func beginLiveDictationTranscription(
        onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> UUID {
        liveBeginCallCount += 1
        guard liveEnabled else {
            throw STTLiveDictationTranscriptionError.unsupportedEngine(.parakeet)
        }
        if let liveBeginError {
            throw liveBeginError
        }
        let id = UUID()
        liveSessionID = id
        livePartialHandler = onPartial
        return id
    }

    public func appendLiveDictationSamples(_ samples: [Float], sessionID: UUID) async throws {
        guard liveSessionID == sessionID else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        liveAppendCallCount += 1
        liveAppendedSamples.append(samples)
        if liveAppendsHeld {
            await withCheckedContinuation { continuation in
                liveAppendHoldContinuations.append(continuation)
            }
        }
        if let liveAppendError {
            throw liveAppendError
        }
    }

    /// Suspend every subsequent live append until `releaseLiveAppends()` —
    /// lets tests overflow the service's live sample stream deterministically.
    public func holdLiveAppends() {
        liveAppendsHeld = true
    }

    public func releaseLiveAppends() {
        liveAppendsHeld = false
        let waiters = liveAppendHoldContinuations
        liveAppendHoldContinuations = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    public func finishLiveDictationTranscription(sessionID: UUID) async throws -> STTResult {
        guard liveSessionID == sessionID else {
            throw STTLiveDictationTranscriptionError.sessionNotActive
        }
        liveFinishCallCount += 1
        liveSessionID = nil
        livePartialHandler = nil
        if let liveFinishError {
            throw liveFinishError
        }
        return liveFinishResult ?? STTResult(text: "Mock live transcription", words: [], engine: .nemotron)
    }

    public func cancelLiveDictationTranscription(sessionID: UUID) async {
        guard liveSessionID == sessionID else { return }
        liveCancelCallCount += 1
        liveSessionID = nil
        livePartialHandler = nil
    }

    public func emitLivePartial(_ partial: String) {
        livePartialHandler?(partial)
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        warmUpCalled = true
        warmUpCallCount += 1

        if let phases = warmUpProgressPhases {
            for phase in phases {
                onProgress?(phase)
            }
        }

        if warmUpFailuresBeforeSuccess > 0 {
            warmUpFailuresBeforeSuccess -= 1
            throw STTError.engineStartFailed("warm-up failed")
        }

        if let error = warmUpError {
            throw error
        }

        ready = true
    }

    public func backgroundWarmUp() async {
        if case .ready = warmUpState { return }
        if backgroundWarmUpTask != nil { return }
        prepareWarmUpStateForRetry()
        setWarmUpState(.working(message: "Checking setup requirements...", progress: nil))

        backgroundWarmUpTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.warmUp { [weak self] progressMessage in
                    Task {
                        await self?.setWarmUpState(
                            .working(
                                message: "Speech model: \(progressMessage)",
                                progress: OnboardingProgressParser.parseProgressFraction(
                                    from: "Speech model: \(progressMessage)"
                                )
                            )
                        )
                    }
                }
                await self.setWarmUpState(.ready)
            } catch is CancellationError {
                // Match STTRuntime: cancellation does not mutate the shared state machine.
            } catch {
                await self.setWarmUpState(.failed(message: error.localizedDescription))
            }
            await self.clearBackgroundWarmUpTask()
        }
    }

    public func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        let id = UUID()
        let stream = AsyncStream<STTWarmUpState> { continuation in
            continuation.yield(warmUpState)
            warmUpObservers[id] = continuation
            continuation.onTermination = { @Sendable _ in
                Task { [weak self] in
                    await self?.removeWarmUpObserver(id: id)
                }
            }
        }
        return (id, stream)
    }

    public func removeWarmUpObserver(id: UUID) async {
        warmUpObservers.removeValue(forKey: id)?.finish()
    }

    public func wasWarmUpCalled() -> Bool {
        warmUpCalled
    }

    public var ready = true

    public func setReady(_ value: Bool) {
        ready = value
    }

    public func isReady() async -> Bool {
        ready
    }

    public func configureSpeechEngineSwitch(error: Error?) {
        speechEngineSwitchError = error
    }

    public func speechEngineSwitchesSnapshot() -> [SpeechEnginePreference] {
        speechEngineSwitches
    }

    public func warmUpCallCountSnapshot() -> Int {
        warmUpCallCount
    }

    public func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        try await setSpeechEngine(preference, onProgress: nil)
    }

    public func setSpeechEngine(
        _ preference: SpeechEnginePreference,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        speechEngineSwitches.append(preference)
        onProgress?("Preparing \(preference.displayName)...")
        speechEngineSwitchProgressMessages.append("Preparing \(preference.displayName)...")
        if let speechEngineSwitchError {
            throw speechEngineSwitchError
        }
        ready = true
    }

    public func setParakeetModelVariant(
        _ variant: ParakeetModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        parakeetModelVariantSwitches.append(variant)
        onProgress?("Preparing \(variant.modelName)...")
        if let parakeetModelVariantSwitchError {
            throw parakeetModelVariantSwitchError
        }
        ready = true
    }

    public func setNemotronModelVariant(
        _ variant: NemotronModelVariant,
        onProgress: (@Sendable (String) -> Void)?
    ) async throws {
        nemotronModelVariantSwitches.append(variant)
        onProgress?("Preparing \(variant.modelName)...")
        if let nemotronModelVariantSwitchError {
            throw nemotronModelVariantSwitchError
        }
        ready = true
    }

    public func clearModelCache() async {
        clearModelCacheCalled = true
        ready = false
        setWarmUpState(.idle)
    }

    public func shutdown() async {
        shutdownCalled = true
    }

    private func prepareWarmUpStateForRetry() {
        if case .failed = warmUpState {
            warmUpState = .idle
        }
    }

    private func setWarmUpState(_ state: STTWarmUpState) {
        if case .working = state {
            switch warmUpState {
            case .ready, .failed:
                return
            default:
                break
            }
        }
        warmUpState = state
        for (_, observer) in warmUpObservers {
            observer.yield(state)
        }
    }

    private func clearBackgroundWarmUpTask() {
        backgroundWarmUpTask = nil
    }
}
