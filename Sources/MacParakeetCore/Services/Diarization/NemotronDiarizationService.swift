import CoreML
import FluidAudio
import Foundation
import OSLog

enum NemotronDiarizationError: LocalizedError {
    case invalidModelAsset(String)

    var errorDescription: String? {
        switch self {
        case .invalidModelAsset(let path):
            "The downloaded speaker model failed verification: \(path)"
        }
    }
}

struct NemotronSpeakerActivity: Sendable {
    let speakerIndex: Int
    let startSeconds: Float
    let endSeconds: Float
}

protocol NemotronDiarizationRunning: Sendable {
    func process(audioURL: URL) throws -> [NemotronSpeakerActivity]
}

/// Post-recording eight-speaker activity detection. Microphone attribution and
/// ASR stay outside this service. Explicit count choices use Community-1.
public actor NemotronDiarizationService: DiarizationServiceProtocol {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "NemotronDiarization")
    public enum Preset: String, Sendable {
        case fast128
        case offline

        var config: Nemotron3Config {
            self == .offline ? .offline : .fast128
        }
    }

    typealias RunnerLoader = @Sendable () async throws -> any NemotronDiarizationRunning
    private let loadRunner: RunnerLoader
    private let cached: @Sendable () -> Bool
    private let fallback: any DiarizationServiceProtocol
    private let inferenceGate: ANEInferenceGate
    private let inferencePermit: AsyncPermit
    private var runner: (any NemotronDiarizationRunning)?
    private var preparation: Task<Void, Error>?

    public init(preset: Preset = .fast128, modelsDirectory: URL? = nil) {
        let base = modelsDirectory ?? AppPaths.fluidAudioModelsDirURL
        loadRunner = {
            let root = try await NemotronDiarizationModelStore.prepare(base: base, preset: preset)
            return try await NativeNemotronDiarizationRunner.load(preset: preset, directory: root)
        }
        cached = { NemotronDiarizationModelStore.isCached(base: base, preset: preset) }
        fallback = DiarizationService(modelsDirectory: base)
        inferenceGate = .shared
        inferencePermit = AsyncPermit(value: 1)
    }

    init(
        loadRunner: @escaping RunnerLoader,
        cached: @escaping @Sendable () -> Bool = { false },
        fallback: any DiarizationServiceProtocol = DiarizationService(),
        inferenceGate: ANEInferenceGate = .shared,
        inferencePermit: AsyncPermit = AsyncPermit(value: 1)
    ) {
        self.loadRunner = loadRunner
        self.cached = cached
        self.fallback = fallback
        self.inferenceGate = inferenceGate
        self.inferencePermit = inferencePermit
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        onProgress?("Preparing Nemotron speaker model...")
        try await ensurePrepared()
        // Setup promises readiness for Auto and explicit count choices. Keep
        // the compatibility assets available before the user goes offline.
        try await fallback.prepareModels(onProgress: onProgress)
        onProgress?("Speaker model ready")
    }

    public func isReady() async -> Bool {
        guard runner != nil else { return false }
        return await fallback.isReady()
    }

    public func hasCachedModels() async -> Bool {
        guard cached() else { return false }
        return await fallback.hasCachedModels()
    }

    public nonisolated static func clearModelCache(directory: URL? = nil) {
        let base = directory ?? AppPaths.fluidAudioModelsDirURL
        try? FileManager.default.removeItem(at: base.appendingPathComponent("nemotron-diarization", isDirectory: true))
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        try await ensurePrepared()
        try Task.checkCancellation()
        guard let runner else { throw OfflineDiarizationError.modelNotLoaded("nemotron-diarization") }
        let native = try await run(runner, audioURL: audioURL)
        try Task.checkCancellation()
        let result = Self.result(from: native)
        // Calendar hints are advisory bounds, not oracle counts. A natural
        // Nemotron result within those bounds needs no forced clustering. If
        // it violates them, preserve the existing count-cap behavior instead
        // of deleting speaker channels or silently ignoring the prior.
        if !Self.satisfies(speakerConstraint, count: result.speakerCount), !native.isEmpty {
            do {
                return try await fallback.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                // Calendar bounds are advisory. A missing fallback model (for
                // example on an offline first run) must not discard successful
                // native attribution. Explicit choices use the factory's
                // Community-1 service directly and retain its failure semantics.
                logger.warning("calendar_speaker_bound_unavailable retaining_nemotron_result=true")
            }
        }
        return result
    }

    private func run(_ runner: any NemotronDiarizationRunning, audioURL: URL) async throws -> [NemotronSpeakerActivity]
    {
        // The SDK shares mutable model buffers within this service. Queued
        // callers suspend and can cancel instead of blocking on its NSLock.
        try await inferencePermit.wait()
        defer { inferencePermit.signal() }
        try Task.checkCancellation()
        return try await inferenceGate.withExclusiveAccess {
            try runner.process(audioURL: audioURL)
        }
    }

    private func ensurePrepared() async throws {
        try Task.checkCancellation()
        guard runner == nil else { return }
        let task: Task<Void, Error>
        if let preparation {
            task = preparation
        } else {
            task = Task {
                defer { self.preparation = nil }
                self.runner = try await self.loadRunner()
            }
            preparation = task
        }
        let awaiter = CancellationResponsiveTaskAwaiter()
        let waiter = Task { awaiter.resume(with: await task.result) }
        defer { waiter.cancel() }
        try await awaiter.wait()
        try Task.checkCancellation()
    }

    static func satisfies(_ constraint: SpeakerDiarizationConstraint?, count: Int) -> Bool {
        switch constraint {
        case nil: true
        case .exact(let expected): count == expected
        case .range(let minimum, let maximum):
            count >= (minimum ?? 0) && count <= (maximum ?? Int.max)
        }
    }

    static func result(from native: [NemotronSpeakerActivity]) -> MacParakeetDiarizationResult {
        let chronological = native.filter {
            $0.startSeconds.isFinite && $0.endSeconds.isFinite && $0.endSeconds > max(0, $0.startSeconds)
                && (0..<8).contains($0.speakerIndex)
        }.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.speakerIndex < $1.speakerIndex
        }
        var identities: [Int: String] = [:]
        var speakers: [SpeakerInfo] = []
        var segments: [SpeakerSegment] = []
        var durations: [String: Int] = [:]
        for segment in chronological {
            let start = max(0, Int((segment.startSeconds * 1000).rounded()))
            let end = max(0, Int((segment.endSeconds * 1000).rounded()))
            guard end > start else { continue }
            let id: String
            if let existing = identities[segment.speakerIndex] {
                id = existing
            } else {
                id = "S\(speakers.count + 1)"
                identities[segment.speakerIndex] = id
                speakers.append(SpeakerInfo(id: id, label: "Speaker \(speakers.count + 1)"))
            }
            segments.append(SpeakerSegment(speakerId: id, startMs: start, endMs: end))
            durations[id, default: 0] += end - start
        }
        return MacParakeetDiarizationResult(
            segments: segments, speakerCount: speakers.count, speakers: speakers,
            speakerEmbeddings: [:], speechMsBySpeaker: durations
        )
    }
}

/// Sendability is provided by this lock, not by the SDK's model struct. Its
/// MLMultiArrays are mutable; even different diarizers must not share them
/// during inference. No await occurs while the lock is held.
private final class NativeNemotronDiarizationRunner: NemotronDiarizationRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let models: Nemotron3Models
    private let config: Nemotron3Config

    private init(models: Nemotron3Models, config: Nemotron3Config) {
        self.models = models
        self.config = config
    }

    static func load(preset: NemotronDiarizationService.Preset, directory: URL) async throws
        -> NativeNemotronDiarizationRunner
    {
        let config = preset.config
        let units: MLComputeUnits =
            preset == .offline || ANEInferenceGate.serializationRequiredForCurrentOS
            ? .cpuAndGPU : .all
        let models = try await Nemotron3Models.load(config: config, directory: directory, computeUnits: units)
        return NativeNemotronDiarizationRunner(models: models, config: config)
    }

    func process(audioURL: URL) throws -> [NemotronSpeakerActivity] {
        try lock.withLock {
            try Task.checkCancellation()
            let samples = try AudioConverter().resampleAudioFile(path: audioURL.path)
            try Task.checkCancellation()
            guard !samples.isEmpty else { return [] }
            let diarizer = Nemotron3Diarizer(config: config, models: models)
            defer { diarizer.reset() }
            var probabilities: [Float] = []
            var frames = 0
            func append(_ chunks: [Nemotron3ChunkResult]) {
                for chunk in chunks {
                    probabilities.append(contentsOf: chunk.probabilities)
                    frames += chunk.frameCount
                }
            }
            // Bounded feeds allow cancellation between individual inferences;
            // processComplete would run the whole recording without a check.
            for offset in stride(from: 0, to: samples.count, by: 16_000) {
                try Task.checkCancellation()
                diarizer.appendAudio(Array(samples[offset..<min(offset + 16_000, samples.count)]))
                append(try diarizer.processBufferedAudio())
            }
            try Task.checkCancellation()
            append(try diarizer.finishStream())
            try Task.checkCancellation()
            return Nemotron3Diarizer.segments(
                probabilities: probabilities, frameCount: frames,
                numSpeakers: 8, threshold: 0.5, frameSeconds: 0.01, minDurationSeconds: 0
            ).map {
                NemotronSpeakerActivity(
                    speakerIndex: $0.speakerIndex, startSeconds: $0.startSeconds, endSeconds: $0.endSeconds
                )
            }
        }
    }
}
