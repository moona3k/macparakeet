import Foundation

/// Serializes CoreML / Neural Engine inference process-wide on macOS 14.
///
/// On macOS 14 (Sonoma) the Neural Engine's shared execution queue
/// intermittently bus-errors (SIGBUS — a write into read-only mmapped model
/// weights) when two CoreML inferences run concurrently. This is the fault
/// FluidAudio tracks upstream as issue #661. MacParakeet hits it from two
/// directions:
///
/// - `STTRuntime` drives interactive (dictation) and background (file/meeting)
///   transcription as concurrent scheduler lanes backed by separate
///   `AsrManager`s that share one loaded `AsrModels` instance, so the two lanes
///   can run `prediction()` on the same model objects at the same time.
/// - Offline diarization runs its own Neural Engine models from
///   `DiarizationService`, outside the STT scheduler entirely, so it can overlap
///   any in-flight ASR.
///
/// Crash telemetry confirmed a single recurring SIGBUS signature isolated
/// entirely to macOS 14 (zero occurrences on macOS 15/26/27), spread across
/// chips and app versions — the fingerprint of an OS-runtime race, not a model
/// or silicon bug. macOS 15+ rewrote the Neural Engine runtime and does not
/// exhibit it.
///
/// So the gate is a **no-op on macOS 15+**: callers keep full lane concurrency
/// and pay nothing. On macOS 14 it guarantees at most one inference runs at a
/// time. It is *uncontended* whenever only one inference is active — the common
/// case — so the only cost is that a genuinely concurrent dictation + background
/// job (precisely the window that otherwise crashes) waits instead of racing.
/// Waiting respects cancellation, so a cancelled dictation does not block on a
/// long-running background job.
public final class ANEInferenceGate: Sendable {

    /// Shared process-wide gate. The Neural Engine is a single hardware
    /// resource, so one gate per process is the correct scope.
    public static let shared = ANEInferenceGate()

    /// `true` on the OS versions where concurrent Neural Engine inference is
    /// known to SIGBUS (macOS 14 and any older runtime); `false` on macOS 15+.
    public static var serializationRequiredForCurrentOS: Bool {
        if #available(macOS 15.0, *) { false } else { true }
    }

    private let serializationRequired: Bool
    private let permit = AsyncPermit(value: 1)

    /// - Parameter serializationRequired: whether to serialize. Defaults to the
    ///   current OS check; overridable so the behavior can be unit-tested on any
    ///   host (CI typically runs macOS 15+, where the default is `false`).
    public init(serializationRequired: Bool = ANEInferenceGate.serializationRequiredForCurrentOS) {
        self.serializationRequired = serializationRequired
    }

    /// Runs `body` with exclusive Neural Engine access on macOS 14; runs it
    /// directly (no serialization, no suspension) on macOS 15+.
    ///
    /// Callers must not nest calls to this method: the gate is a plain mutex,
    /// not reentrant, so a nested acquisition on macOS 14 would deadlock. Gate
    /// at one level per inference (the FluidAudio / WhisperKit calls that run
    /// CoreML, plus the diarization process call), never around an already-gated
    /// call.
    public func withExclusiveAccess<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        guard serializationRequired else {
            return try await body()
        }
        try await permit.wait()
        defer { permit.signal() }
        return try await body()
    }
}
