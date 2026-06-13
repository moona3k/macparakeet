import Foundation
import OSLog

/// Prepares the Silero VAD model used by VAD-guided meeting live chunking
/// (`AppFeatures.meetingVadLiveChunkingEnabled`,
/// `plans/completed/2026-05-meeting-vad-guided-live-chunking.md`).
///
/// A deferred launch-time task fetches the model up front (see
/// `MeetingVADLaunchPrep` + `AppDelegate.scheduleDeferredSpeechPreWarm`) so the
/// runtime path (`MeetingVADService.makeIfModelCached`) stays download-free and
/// never adds latency at meeting start.
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

/// Universal launch-time VAD model availability (Phase 4.5,
/// `plans/completed/2026-05-meeting-vad-guided-live-chunking.md` §6).
///
/// The Silero model used to be fetched only during onboarding, so it reached
/// *new installs only* — the entire installed base ran fixed chunking forever
/// because the runtime (`MeetingVADService.makeIfModelCached`) never downloads.
/// `AppDelegate.scheduleDeferredSpeechPreWarm` now runs this on every launch
/// for every user (after the speech warm-up), so flipping
/// `meetingVadLiveChunkingEnabled` actually lights VAD up for everyone.
///
/// This is the flag-and-cache gate factored out of `AppDelegate` so the
/// decision is unit-testable without driving the deferred launch timer.
public enum MeetingVADLaunchPrep {
    /// Outcome of a single launch-prep attempt. `disabled` (feature off),
    /// `alreadyCached` (steady state), and `cancelled` (app quit mid-download)
    /// are silent — only `prepared` / `failed` are worth a telemetry event.
    /// See `TelemetryVADModelPrepOutcome`.
    public enum Outcome: Sendable, Equatable {
        /// Feature flag is off — prep was not attempted.
        case disabled
        /// Model already on disk — nothing to do.
        case alreadyCached
        /// Model was just downloaded + compiled this launch.
        case prepared
        /// Download/compile failed; swallowed. The meeting path falls back to
        /// fixed chunking and the next launch retries (natural backoff).
        case failed
        /// The launch task was cancelled mid-download (e.g. app quit). Distinct
        /// from `.failed` so a normal-shutdown cancellation never emits a
        /// spurious failure telemetry event. The next launch retries.
        case cancelled
    }

    private static let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingVADLaunchPrep")

    /// Idempotent, never-throwing launch-time prep. Skips when the feature is
    /// off or the model is already cached; otherwise downloads it. A failure is
    /// logged and swallowed (returns `.failed`) — VAD live chunking is an
    /// optional enhancement, never a launch blocker.
    public static func run(
        featureEnabled: Bool,
        preparer: any MeetingVADModelPreparing
    ) async -> Outcome {
        guard featureEnabled else { return .disabled }
        if await preparer.isModelReady() { return .alreadyCached }
        do {
            try await preparer.prepareModel()
            logger.info("vad_model_launch_prep prepared")
            return .prepared
        } catch {
            // Cancellation (the deferred launch task is cancelled on app quit)
            // must not be reported as a failure. `Task.isCancelled` is the
            // ground truth — a cancelled in-flight `URLSession` download
            // surfaces as `URLError(.cancelled)`, not `CancellationError`, so
            // matching the error type alone would miss the common case.
            if Task.isCancelled || error is CancellationError {
                logger.info("vad_model_launch_prep cancelled")
                return .cancelled
            }
            logger.error("vad_model_launch_prep failed error=\(error.localizedDescription, privacy: .public)")
            return .failed
        }
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
