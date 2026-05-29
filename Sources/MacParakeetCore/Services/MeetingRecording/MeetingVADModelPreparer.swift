import Foundation

/// Prepares the Silero VAD model used by VAD-guided meeting live chunking
/// (`AppFeatures.meetingVadLiveChunkingEnabled`,
/// `plans/active/2026-05-meeting-vad-guided-live-chunking.md`).
///
/// Onboarding fetches the model up front so the runtime path
/// (`MeetingVADService.makeIfModelCached`) stays download-free and never adds
/// latency at meeting start. Mirrors `DiarizationServiceProtocol` model prep so
/// the onboarding warm-up treats both optional model stacks the same way.
public protocol MeetingVADModelPreparing: Sendable {
    /// `true` when every required Silero VAD model file is already cached.
    func isModelReady() async -> Bool
    /// Download + compile the Silero VAD model if it is not already cached;
    /// no-ops when it is. `onProgress` receives coarse status strings.
    func prepareModel(onProgress: (@Sendable (String) -> Void)?) async throws
}

extension MeetingVADModelPreparing {
    public func prepareModel() async throws {
        try await prepareModel(onProgress: nil)
    }
}

/// FluidAudio-backed preparer. Reuses `MeetingVADService`'s cache check and the
/// same `.cpuOnly` load path, so a successful prep guarantees a later
/// `makeIfModelCached()` hit.
public struct MeetingVADModelPreparer: MeetingVADModelPreparing {
    public init() {}

    public func isModelReady() async -> Bool {
        MeetingVADService.isModelCached()
    }

    public func prepareModel(onProgress: (@Sendable (String) -> Void)?) async throws {
        if MeetingVADService.isModelCached() {
            onProgress?("Voice-activity model ready")
            return
        }
        onProgress?("Downloading voice-activity model...")
        try await MeetingVADService.downloadModel()
        onProgress?("Voice-activity model ready")
    }
}

/// Test double. `prepareModel` records the call and flips the cached flag so a
/// follow-up `isModelReady()` reflects the prepared state.
public actor MockMeetingVADModelPreparer: MeetingVADModelPreparing {
    public var prepareModelCalled = false
    public var prepareModelError: Error?
    public var cached = false

    public init() {}

    public func configureCached(_ cached: Bool) {
        self.cached = cached
    }

    public func configurePrepareModel(error: Error?) {
        self.prepareModelError = error
    }

    public func isModelReady() async -> Bool {
        cached
    }

    public func prepareModel(onProgress: (@Sendable (String) -> Void)?) async throws {
        prepareModelCalled = true
        if let error = prepareModelError { throw error }
        cached = true
    }
}
