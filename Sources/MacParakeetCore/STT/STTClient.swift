import FluidAudio
import Foundation

/// Backwards-compatible facade for standalone callers that still construct an STT client.
/// The app now owns `STTRuntime` + `STTScheduler` directly (ADR-016).
public actor STTClient: STTManaging {
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

    public nonisolated static func isModelCached(version: AsrModelVersion = .v3) -> Bool {
        STTRuntime.isModelCached(version: version)
    }
}
