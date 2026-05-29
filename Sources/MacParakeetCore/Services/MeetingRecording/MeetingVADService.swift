@preconcurrency import CoreML
import FluidAudio
import Foundation
import OSLog

/// A speech boundary emitted by streaming VAD. The `speechEnd` `sampleIndex` is
/// **retroactive**: it points back to where speech ended (minus padding) in the
/// VAD stream's own absolute sample coordinate, not the current ingest position.
/// `speechStart` carries no index — the chunker only needs to know that speech
/// began since the last emit, and uses `speechEnd` as the cut point.
enum MeetingVADEvent: Sendable {
    case speechStart
    case speechEnd(sampleIndex: Int)
}

/// Opaque, adapter-owned streaming VAD state. Product code round-trips this
/// without depending on FluidAudio's `VadStreamState`; the FluidAudio-backed
/// storage is internal. The no-argument init produces a fresh stream state.
struct MeetingVADStreamState: Sendable {
    var fluidState: VadStreamState

    init() {
        self.fluidState = VadStreamState()
    }

    init(fluidState: VadStreamState) {
        self.fluidState = fluidState
    }
}

struct MeetingVADResult: Sendable {
    let state: MeetingVADStreamState
    let event: MeetingVADEvent?
}

/// MacParakeet-owned VAD config. Mirrors only the knobs that actually affect
/// FluidAudio's **streaming** state machine (verified in
/// `VadManager+Streaming.swift`): silence-before-end and retroactive padding.
/// `minSpeechDuration` / `maxSpeechDuration` / `silenceThresholdForSplit` are
/// inert in streaming mode, so they are deliberately absent. Min/max chunk
/// bounds live in the chunker, not VAD. The two values below are deliberate
/// non-defaults tuned for live-meeting feel (FluidAudio defaults 0.75 / 0.10).
struct MeetingVADConfig: Sendable {
    /// Silence that must elapse before a `speechEnd` fires.
    var minSilenceDuration: TimeInterval = 0.50
    /// Padding folded into the retroactive boundary index.
    var speechPadding: TimeInterval = 0.15

    static let `default` = MeetingVADConfig()
}

/// Streaming voice-activity detection, MacParakeet-facing. Per-stream state is
/// carried in the `MeetingVADStreamState` value the caller threads through
/// `processStreamingChunk`, so one instance can back several sources (mic +
/// system). Callers must invoke it **serially**, though: the FluidAudio-backed
/// implementation shares a pooled ANE buffer inside `VadManager`, so it is not
/// safe to call truly concurrently (e.g. from a `TaskGroup`). The actor hop plus
/// `CaptureOrchestrator`'s sequential mic-then-system calls provide that
/// serialization.
protocol MeetingVoiceActivityDetecting: Sendable {
    func makeStreamState() async -> MeetingVADStreamState
    func processStreamingChunk(
        _ samples: [Float],
        state: MeetingVADStreamState,
        config: MeetingVADConfig
    ) async throws -> MeetingVADResult
}

/// FluidAudio-backed VAD adapter. Owns a single `VadManager` (one CoreML model
/// load) and exposes only MacParakeet types. The same instance backs both the
/// microphone and system chunkers; each chunker keeps its own stream state.
actor MeetingVADService: MeetingVoiceActivityDetecting {
    private let manager: VadManager

    init(manager: VadManager) {
        self.manager = manager
    }

    /// Build a service **only if the VAD model is already cached on disk**.
    /// Never downloads, so it cannot add hidden meeting-start latency or block
    /// on the network. Returns `nil` when the model is absent or fails to load,
    /// so callers fall back to fixed chunking for the session.
    ///
    /// `computeUnits` defaults to `.cpuOnly` to avoid Neural Engine contention
    /// with Parakeet during live transcription (Phase 0 benchmark may revisit).
    static func makeIfModelCached(
        computeUnits: MLComputeUnits = .cpuOnly
    ) async -> MeetingVADService? {
        let logger = Logger(subsystem: "com.macparakeet.core", category: "MeetingVADService")
        guard isModelCached() else {
            logger.info("meeting_vad_model_uncached — falling back to fixed live chunking")
            return nil
        }
        do {
            let manager = try await VadManager(config: VadConfig(computeUnits: computeUnits))
            guard await manager.isAvailable else {
                logger.error("meeting_vad_init_unavailable — model loaded but not available")
                return nil
            }
            return MeetingVADService(manager: manager)
        } catch {
            logger.error("meeting_vad_init_failed error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// `true` when every required Silero VAD model file already exists in the
    /// shared FluidAudio model cache.
    static func isModelCached() -> Bool {
        let directory = MLModelConfigurationUtils.defaultModelsDirectory(for: .vad)
        return ModelNames.VAD.requiredModels.allSatisfy { modelName in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(modelName, isDirectory: false).path
            )
        }
    }

    /// Download + compile the Silero VAD model if it is not already cached, then
    /// discard the loaded manager. `MeetingVADModelPreparer` (onboarding model
    /// prep) calls this so the runtime `makeIfModelCached` path stays
    /// download-free. Uses the same `.cpuOnly` load path as the runtime; throws
    /// on download/compile failure. FluidAudio's `VadManager` init handles the
    /// cached-or-download decision internally.
    static func downloadModel(computeUnits: MLComputeUnits = .cpuOnly) async throws {
        _ = try await VadManager(config: VadConfig(computeUnits: computeUnits))
    }

    func makeStreamState() async -> MeetingVADStreamState {
        MeetingVADStreamState(fluidState: await manager.makeStreamState())
    }

    func processStreamingChunk(
        _ samples: [Float],
        state: MeetingVADStreamState,
        config: MeetingVADConfig
    ) async throws -> MeetingVADResult {
        let result = try await manager.processStreamingChunk(
            samples,
            state: state.fluidState,
            config: config.fluidConfig
        )
        return MeetingVADResult(
            state: MeetingVADStreamState(fluidState: result.state),
            event: result.event.map(Self.mapEvent)
        )
    }

    private static func mapEvent(_ event: VadStreamEvent) -> MeetingVADEvent {
        switch event.kind {
        case .speechStart:
            return .speechStart
        case .speechEnd:
            return .speechEnd(sampleIndex: event.sampleIndex)
        }
    }
}

extension MeetingVADConfig {
    /// Map to FluidAudio's `VadSegmentationConfig`, carrying only the
    /// streaming-relevant knobs and leaving the inert segmentation fields at
    /// their defaults.
    var fluidConfig: VadSegmentationConfig {
        VadSegmentationConfig(
            minSilenceDuration: minSilenceDuration,
            speechPadding: speechPadding
        )
    }
}
