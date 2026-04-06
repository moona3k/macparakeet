import Foundation
@testable import MacParakeetCore

public actor MockSTTClient: STTClientProtocol {
    public var transcribeResult: STTResult?
    public var transcribeError: Error?
    public var transcribeCallCount = 0
    public var lastAudioPath: String?
    public var lastJob: STTJobKind?
    public var warmUpCalled = false
    public var warmUpCallCount = 0
    public var warmUpError: Error?
    public var warmUpFailuresBeforeSuccess: Int = 0
    public var warmUpProgressPhases: [String]?
    public var clearModelCacheCalled = false
    public var shutdownCalled = false
    private var warmUpState: STTWarmUpState = .idle
    private var warmUpObservers: [UUID: AsyncStream<STTWarmUpState>.Continuation] = [:]
    private var backgroundWarmUpTask: Task<Void, Never>?

    public init() {}

    public func configure(result: STTResult) {
        self.transcribeResult = result
        self.transcribeError = nil
    }

    public func configure(error: Error) {
        self.transcribeError = error
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

        if let error = transcribeError {
            throw error
        }

        return transcribeResult ?? STTResult(text: "Mock transcription", words: [])
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
        if backgroundWarmUpTask != nil { return }
        prepareWarmUpStateForRetry()
        setWarmUpState(.working(message: "Checking setup requirements...", progress: nil))

        backgroundWarmUpTask = Task { [weak self] in
            guard let self else { return }
            let maxAttempts = 3
            var attempt = 1
            while attempt <= maxAttempts {
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
                    await self.clearBackgroundWarmUpTask()
                    return
                } catch {
                    if attempt == maxAttempts {
                        await self.setWarmUpState(.failed(message: error.localizedDescription))
                        break
                    }
                    attempt += 1
                    await self.setWarmUpState(
                        .working(message: "Retrying speech model setup (attempt \(attempt)/\(maxAttempts))...", progress: nil)
                    )
                    try? await Task.sleep(for: .milliseconds(250))
                }
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
        warmUpObservers.removeValue(forKey: id)
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
