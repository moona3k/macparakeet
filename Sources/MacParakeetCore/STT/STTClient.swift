import FluidAudio
import Foundation

/// Standalone STT facade for the CLI tool and test helpers.
///
/// - Warning: Each ``STTClient`` creates its **own** `STTRuntime` and `STTScheduler`,
///   bypassing the process-wide singleton that ADR-016 requires.
///   **App code must never instantiate this type directly.**
///   Use the shared ``STTScheduler`` from `AppEnvironment` instead.
public actor STTClient: STTManaging, SpeechEngineRoutedTranscribing, SpeechEngineSwitching, SpeechEngineSessionManaging {
    private let scheduler: STTScheduler

    public init(modelVersion: AsrModelVersion = .v3) {
        let runtime = STTRuntime(modelVersion: modelVersion)
        self.scheduler = STTScheduler(runtime: runtime)
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        try await scheduler.transcribe(audioPath: audioPath, job: job, onProgress: onProgress)
    }

    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        try await scheduler.transcribe(
            audioPath: audioPath,
            job: job,
            speechEngine: speechEngine,
            onProgress: onProgress
        )
    }

    public func warmUp(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await scheduler.warmUp(onProgress: onProgress)
    }

    public func backgroundWarmUp() async {
        await scheduler.backgroundWarmUp()
    }

    public func observeWarmUpProgress() async -> (id: UUID, stream: AsyncStream<STTWarmUpState>) {
        await scheduler.observeWarmUpProgress()
    }

    public func removeWarmUpObserver(id: UUID) async {
        await scheduler.removeWarmUpObserver(id: id)
    }

    public func isReady() async -> Bool {
        await scheduler.isReady()
    }

    public func clearModelCache() async {
        await scheduler.clearModelCache()
    }

    public func shutdown() async {
        await scheduler.shutdown()
    }

    public func setSpeechEngine(_ preference: SpeechEnginePreference) async throws {
        try await scheduler.setSpeechEngine(preference)
    }

    public func beginSpeechEngineSession() async -> SpeechEngineLease {
        await scheduler.beginSpeechEngineSession()
    }

    public func endSpeechEngineSession(_ lease: SpeechEngineLease) async {
        await scheduler.endSpeechEngineSession(lease)
    }

    public nonisolated static func isModelCached(version: AsrModelVersion = .v3) -> Bool {
        STTRuntime.isModelCached(version: version)
    }
}
