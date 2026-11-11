import AVFoundation
import CoreML
import CryptoKit
import FluidAudio
import Foundation
import OSLog

/// The voiceprint representation saved voices are stored and matched in.
///
/// Diarization still clusters with Community-1 (WeSpeaker); only the per-speaker
/// voiceprint that is saved, matched and compared across recordings comes from
/// NVIDIA TitaNet-Large. Changing this identity retires every saved sample made
/// with the previous one: vectors from different models share no space.
public enum SpeakerVoiceprintModel {
    public static let identity = SpeakerModelIdentity(
        embeddingModelId: TitaNetSpeakerEmbedder.embeddingModelId,
        aggregationProfileId: TitaNetSpeakerEmbedder.aggregationProfileId
    )

    /// Thresholds calibrated for TitaNet's distance scale; see `titanetV1`.
    public static let policy = SpeakerMatchPolicy.titanetV1
}

extension SpeakerMatchPolicy {
    /// TitaNet-Large thresholds, calibrated on labelled real meetings (2, 4 and
    /// 11 Nov 2026: one owner, three colleagues, call and in-room microphone).
    ///
    /// - Same person, same capture domain: 0.05–0.34 on full clusters, up to
    ///   0.50 on 15–30 s queries.
    /// - Same person across call audio and a room microphone: 0.51–0.63. This
    ///   overlaps different people, so no threshold can bridge it; the profile
    ///   needs a sample from each domain (references are scored like-for-like).
    /// - Different people: never below 0.58 on full clusters, 0.51 on 15 s.
    ///
    /// `tau` 0.40 keeps ≥ 0.11 clear of every impostor pair seen. The pollution
    /// guard sits under the closest impostor so a cross-domain sample of the
    /// same person still asks before merging rather than merging silently.
    public static let titanetV1 = SpeakerMatchPolicy(
        tau: 0.40,
        margin: 0.10,
        minSpeechSecondsToMatch: 3,
        minSpeechSecondsToEnroll: 15,
        maxReferencesPerProfile: 10,
        crossAggregationPenalty: 0.05,
        pollutionGuardDistance: 0.55
    )
}

public enum TitaNetSpeakerEmbedderError: LocalizedError {
    case modelMissing(URL)
    case invalidModelArchive
    case unexpectedOutput

    public var errorDescription: String? {
        switch self {
        case .modelMissing(let url):
            "TitaNet voiceprint model not found at \(url.path)"
        case .invalidModelArchive:
            "The downloaded TitaNet voiceprint model failed verification"
        case .unexpectedOutput:
            "TitaNet returned an embedding of the wrong shape"
        }
    }
}

/// Per-speaker voiceprints from NVIDIA TitaNet-Large (192-d), run with Core ML.
///
/// The model is a waveform-in export (`scripts/models/export_titanet_coreml.py`):
/// 10 s of 16 kHz mono plus a valid-sample count, so shorter windows are
/// zero-padded and masked inside the model, matching NeMo's own output.
///
/// The model is fetched on first need (`prepareModel`) from a pinned release
/// asset and accepted only if its size and SHA-256 match, the same contract as
/// `NemotronDiarizationModelStore`.
///
/// One speaker's voiceprint: that speaker's speech with every overlapped stretch
/// removed, concatenated in time order, cut into 10 s windows (a tail under
/// 1.5 s is dropped unless it is all there is), each window embedded and
/// unit-normalized, then a duration-weighted mean, normalized again.
///
/// Stored at `SpeakerEmbedding.dimension` (256) by zero-padding the 192 values:
/// cosine distance is unchanged by trailing zeros, and the existing schema and
/// storage format stay as they are. The model id keeps these vectors from ever
/// being compared with 256-d WeSpeaker ones.
public actor TitaNetSpeakerEmbedder {
    public static let embeddingModelId = "nvidia-titanet-large-192"
    public static let aggregationProfileId = "titanet-concat10s-v1"
    public static let sampleRate = 16_000
    public static let windowSamples = 160_000
    static let outputDimension = 192
    static let minimumTailSamples = 24_000
    /// Bounds the cost on very long speakers (200 windows ≈ 33 min of speech,
    /// about 1.6 s of compute); beyond that, windows are sampled evenly.
    static let maxWindowsPerSpeaker = 200

    /// Pinned, immutable release asset (CC-BY-4.0, NVIDIA; see
    /// THIRD_PARTY_LICENSES.md). Rebuild with `scripts/models/export_titanet_coreml.py`.
    public static let modelArchiveURL = URL(
        string: "https://github.com/liam-machine/macparakeet/releases/download/titanet-large-coreml-v1/TitaNetLarge.mlpackage.zip"
    )!
    public static let modelArchiveBytes = 83_785_741
    public static let modelArchiveSHA256 = "c30fc4bb723ff15b533855f78f15bdf35890fac23891d57f1f8a2d301c4bbdbc"

    /// Speech with nobody else talking that a voiceprint needs. Below the
    /// match gate a vector is mostly noise, and it would be scored and stored
    /// as if it were a person.
    public static let minimumVoiceprintSeconds = SpeakerVoiceprintModel.policy.minSpeechSecondsToMatch

    /// Beside the other speaker models, so clearing speaker models clears it.
    public static var defaultModelDirectory: URL {
        modelCacheRoot().appendingPathComponent("v1", isDirectory: true)
    }

    static func modelCacheRoot(directory: URL? = nil) -> URL {
        (directory ?? AppPaths.fluidAudioModelsDirURL).appendingPathComponent("titanet-voiceprint", isDirectory: true)
    }

    public nonisolated static func clearModelCache(directory: URL? = nil) {
        try? FileManager.default.removeItem(at: modelCacheRoot(directory: directory))
    }

    private let modelDirectory: URL
    private let archiveURL: URL
    private let archiveBytes: Int
    private let archiveSHA256: String
    private let fetch: @Sendable (URL) async throws -> Data
    /// Installs and compiles are coordinated per model directory across every
    /// embedder in the process: the factory makes one per diarization service,
    /// and two of them compiling into the same directory would delete each
    /// other's bundle. Actor isolation alone would not help either, since a
    /// second caller re-enters across each `await`.
    private static let coordinator = TitaNetModelCoordinator()
    /// This embedder's own model instance. Only the files are shared: an
    /// `MLModel` is not shared across embedders, so its predictions only ever
    /// run serialized on this actor.
    private var model: MLModel?
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "TitaNetEmbedder")

    public init(
        modelDirectory: URL = TitaNetSpeakerEmbedder.defaultModelDirectory,
        archiveURL: URL = TitaNetSpeakerEmbedder.modelArchiveURL,
        archiveBytes: Int = TitaNetSpeakerEmbedder.modelArchiveBytes,
        archiveSHA256: String = TitaNetSpeakerEmbedder.modelArchiveSHA256,
        fetch: @escaping @Sendable (URL) async throws -> Data = {
            try await ModelHub.fetchFile(from: $0, description: "TitaNet speaker voiceprint model")
        }
    ) {
        self.modelDirectory = modelDirectory
        self.archiveURL = archiveURL
        self.archiveBytes = archiveBytes
        self.archiveSHA256 = archiveSHA256
        self.fetch = fetch
    }

    public nonisolated var compiledModelURL: URL {
        modelDirectory.appendingPathComponent("TitaNetLarge.mlmodelc", isDirectory: true)
    }

    public nonisolated var packageURL: URL {
        modelDirectory.appendingPathComponent("TitaNetLarge.mlpackage", isDirectory: true)
    }

    public nonisolated func isModelAvailable() -> Bool {
        let files = FileManager.default
        return files.fileExists(atPath: compiledModelURL.path) || files.fileExists(atPath: packageURL.path)
    }

    /// Downloads and installs the model package when it is not already here.
    /// Verified before anything is written and installed by a single move, so a
    /// failed or cancelled transfer never leaves a half model behind. Concurrent
    /// callers share one download.
    public func prepareModel() async throws {
        guard !isModelAvailable() else { return }
        try await Self.coordinator.run(key: "install:" + modelDirectory.standardizedFileURL.path) {
            try await self.install()
        }
        guard isModelAvailable() else { throw TitaNetSpeakerEmbedderError.modelMissing(packageURL) }
    }

    private func install() async throws {
        guard !isModelAvailable() else { return }
        let data = try await fetch(archiveURL)
        try Task.checkCancellation()
        guard data.count == archiveBytes,
            SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == archiveSHA256
        else { throw TitaNetSpeakerEmbedderError.invalidModelArchive }

        let files = FileManager.default
        let staging = files.temporaryDirectory.appendingPathComponent("titanet-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("model.zip")
        try data.write(to: archive)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path, staging.path]
        try unzip.run()
        unzip.waitUntilExit()
        let unpacked = staging.appendingPathComponent(packageURL.lastPathComponent, isDirectory: true)
        guard unzip.terminationStatus == 0, files.fileExists(atPath: unpacked.path) else {
            throw TitaNetSpeakerEmbedderError.invalidModelArchive
        }
        try files.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        guard !isModelAvailable() else { return }
        try files.moveItem(at: unpacked, to: packageURL)
        logger.notice("titanet_model_installed bytes=\(data.count, privacy: .public)")
    }

    /// This embedder's model, downloading the package and compiling it once
    /// when needed. Concurrent embedders share one compile, so a second compile
    /// can never delete the bundle the first is reading; each then loads its
    /// own instance from the compiled bundle.
    func loadedModel() async throws -> MLModel {
        if let model { return model }
        if !FileManager.default.fileExists(atPath: compiledModelURL.path) {
            try await Self.coordinator.run(key: "compile:" + modelDirectory.standardizedFileURL.path) {
                try await self.compile()
            }
        }
        guard FileManager.default.fileExists(atPath: compiledModelURL.path) else {
            throw TitaNetSpeakerEmbedderError.modelMissing(compiledModelURL)
        }
        // A concurrent call on this actor may have loaded it across the await.
        if let model { return model }
        let configuration = MLModelConfiguration()
        // FP32 export: the spectrogram front end overflows in FP16, which the
        // Neural Engine would force. CPU+GPU runs a 10 s window in ~8 ms.
        configuration.computeUnits = .cpuAndGPU
        let loaded = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        model = loaded
        return loaded
    }

    private func compile() async throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: compiledModelURL.path) else { return }
        if !files.fileExists(atPath: packageURL.path) {
            try await prepareModel()
        }
        guard files.fileExists(atPath: packageURL.path) else {
            throw TitaNetSpeakerEmbedderError.modelMissing(packageURL)
        }
        let compiled = try await MLModel.compileModel(at: packageURL)
        defer { try? files.removeItem(at: compiled) }
        try Task.checkCancellation()
        try? files.removeItem(at: compiledModelURL)
        try files.moveItem(at: compiled, to: compiledModelURL)
    }

    /// One speaker's voiceprint and the speech it was actually made from.
    public struct Voiceprint: Sendable {
        public let embedding: SpeakerEmbedding
        /// Non-overlapped speech behind the vector, in milliseconds. This, not
        /// the speaker's total activity, is what the match and enrollment
        /// gates should trust.
        public let speechMs: Int
    }

    /// Voiceprints for the given speakers (all speakers in `segments` when
    /// `nil`) that have at least `minimumVoiceprintSeconds` of speech with
    /// nobody else talking. `segments` are in the audio file's own timeline.
    ///
    /// Reads only the windows it embeds, so memory stays at one 10 s window
    /// however long the recording is.
    public func voiceprints(
        audioURL: URL,
        segments: [SpeakerSegment],
        speakers: Set<String>? = nil
    ) async throws -> [String: Voiceprint] {
        let audio = try SpeechAudio(url: audioURL)
        // Loaded only once a speaker qualifies, so a recording of fragments
        // never triggers a download.
        var model: MLModel?
        var result: [String: Voiceprint] = [:]
        for speakerId in Set(segments.map(\.speakerId)) where speakers?.contains(speakerId) ?? true {
            try Task.checkCancellation()
            let regions = Self.sampleRegions(
                Self.exclusiveRegions(of: speakerId, in: segments), limit: audio.count
            )
            let total = regions.reduce(0) { $0 + $1.count }
            guard Double(total) / Double(Self.sampleRate) >= Self.minimumVoiceprintSeconds else { continue }
            if model == nil { model = try await loadedModel() }
            guard let model,
                let embedded = try embed(regions: regions, total: total, audio: audio, model: model),
                let embedding = SpeakerEmbedding(
                    rawVector: Self.padded(embedded.vector), identity: SpeakerVoiceprintModel.identity
                )
            else { continue }
            // The evidence actually in the vector: a dropped tail or windows
            // skipped by the cap are not counted.
            result[speakerId] = Voiceprint(
                embedding: embedding, speechMs: embedded.samples * 1000 / Self.sampleRate
            )
        }
        return result
    }

    /// Embeds the selected windows of a speaker's concatenated speech; returns
    /// the summed vector and how many samples it was made from.
    func embed(
        regions: [Range<Int>], total: Int, audio: SpeechAudio, model: MLModel
    ) throws -> (vector: [Float], samples: Int)? {
        var windows = Self.windows(count: total)
        guard !windows.isEmpty else { return nil }
        if windows.count > Self.maxWindowsPerSpeaker {
            let last = Double(windows.count - 1)
            let step = last / Double(Self.maxWindowsPerSpeaker - 1)
            windows = (0..<Self.maxWindowsPerSpeaker).map { windows[Int((Double($0) * step).rounded())] }
        }

        let input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        var sum = [Float](repeating: 0, count: Self.outputDimension)
        var used = 0
        for window in windows {
            try Task.checkCancellation()
            let samples = try audio.samples(for: Self.fileRanges(of: window, in: regions))
            let pointer = input.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
            pointer.initialize(repeating: 0, count: Self.windowSamples)
            samples.withUnsafeBufferPointer { source in
                pointer.update(from: source.baseAddress!, count: min(samples.count, Self.windowSamples))
            }
            length[0] = NSNumber(value: Int32(min(samples.count, Self.windowSamples)))
            let output = try model.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "audio": MLFeatureValue(multiArray: input),
                    "length": MLFeatureValue(multiArray: length),
                ])
            )
            guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue,
                embedding.count == Self.outputDimension
            else { throw TitaNetSpeakerEmbedderError.unexpectedOutput }
            var values = (0..<Self.outputDimension).map { embedding[$0].floatValue }
            let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm.isFinite, norm > 0 else { continue }
            let weight = Float(samples.count) / norm
            for index in values.indices {
                values[index] *= weight
                sum[index] += values[index]
            }
            used += samples.count
        }
        return used > 0 ? (sum, used) : nil
    }

    // MARK: Pure helpers (tested)

    /// The parts of one speaker's segments where nobody else is talking.
    static func exclusiveRegions(of speakerId: String, in segments: [SpeakerSegment]) -> [Range<Int>] {
        let others = segments.filter { $0.speakerId != speakerId }.map { $0.startMs..<$0.endMs }
        var regions: [Range<Int>] = []
        for segment in segments where segment.speakerId == speakerId && segment.endMs > segment.startMs {
            var pieces = [segment.startMs..<segment.endMs]
            for other in others where !other.isEmpty {
                pieces = pieces.flatMap { piece -> [Range<Int>] in
                    guard piece.overlaps(other) else { return [piece] }
                    var kept: [Range<Int>] = []
                    if other.lowerBound > piece.lowerBound { kept.append(piece.lowerBound..<other.lowerBound) }
                    if other.upperBound < piece.upperBound { kept.append(other.upperBound..<piece.upperBound) }
                    return kept
                }
            }
            regions += pieces.filter { !$0.isEmpty }
        }
        return regions.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Millisecond regions as sample ranges, clamped to the audio's length.
    static func sampleRegions(_ regions: [Range<Int>], limit: Int) -> [Range<Int>] {
        regions.compactMap { region in
            let start = min(limit, region.lowerBound * sampleRate / 1000)
            let end = min(limit, region.upperBound * sampleRate / 1000)
            return end > start ? start..<end : nil
        }
    }

    /// Where a stretch of the concatenated speech lives in the file.
    static func fileRanges(of window: Range<Int>, in regions: [Range<Int>]) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var offset = 0
        for region in regions {
            let next = offset + region.count
            defer { offset = next }
            guard next > window.lowerBound else { continue }
            guard offset < window.upperBound else { break }
            let start = region.lowerBound + max(0, window.lowerBound - offset)
            let end = region.lowerBound + min(region.count, window.upperBound - offset)
            if end > start { ranges.append(start..<end) }
        }
        return ranges
    }

    /// 10 s windows over `count` samples; a short tail goes unless it is alone.
    static func windows(count: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        var windows = stride(from: 0, to: count, by: windowSamples).map {
            $0..<min(count, $0 + windowSamples)
        }
        if windows.count > 1, let tail = windows.last, tail.count < minimumTailSamples {
            windows.removeLast()
        }
        return windows
    }

    static func padded(_ vector: [Float]) -> [Float] {
        vector + [Float](repeating: 0, count: max(0, SpeakerEmbedding.dimension - vector.count))
    }
}

/// Process-wide single flight for TitaNet installs and compiles, keyed by
/// model directory. Concurrent callers for the same key share one task.
///
/// Cancellation is per caller: a cancelled caller stops waiting at once, and
/// the shared work is cancelled only when its last caller has gone. The key
/// stays taken until that abandoned work has actually stopped, so a new caller
/// waits for it (still cancellable) and then starts afresh instead of racing
/// it in the same directory. Reentrant across `await`, so an install started
/// by a compile does not deadlock.
actor TitaNetModelCoordinator {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Error>
        var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
        /// Cancelled because its last caller left. Callers arriving now wait
        /// for it to stop, then start new work.
        var abandoned = false
    }

    private var flights: [String: Flight] = [:]

    func run(key: String, _ work: @escaping @Sendable () async throws -> Void) async throws {
        while true {
            try Task.checkCancellation()
            let flightID: UUID
            let waitingForAbandoned: Bool
            if let flight = flights[key] {
                flightID = flight.id
                waitingForAbandoned = flight.abandoned
            } else {
                flightID = UUID()
                waitingForAbandoned = false
                let task = Task { try await work() }
                flights[key] = Flight(id: flightID, task: task)
                Task {
                    let result = await task.result
                    self.finish(key: key, flightID: flightID, result: result)
                }
            }
            try await wait(key: key, flightID: flightID)
            // `finish` can resume a caller with success just before its
            // cancellation handler runs; a cancelled caller must not go on.
            try Task.checkCancellation()
            if !waitingForAbandoned { return }
        }
    }

    /// Callers currently waiting on `key` (for tests).
    func waiterCount(key: String) -> Int {
        flights[key]?.waiters.count ?? 0
    }

    private func wait(key: String, flightID: UUID) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard flights[key]?.id == flightID else {
                    // Already finished; the caller checks the files it needed.
                    continuation.resume()
                    return
                }
                flights[key]?.waiters[waiterID] = continuation
            }
        } onCancel: {
            Task { await self.leave(key: key, flightID: flightID, waiterID: waiterID) }
        }
    }

    private func leave(key: String, flightID: UUID, waiterID: UUID) {
        guard var flight = flights[key], flight.id == flightID,
            let continuation = flight.waiters.removeValue(forKey: waiterID)
        else { return }
        continuation.resume(throwing: CancellationError())
        if !flight.abandoned, flight.waiters.isEmpty {
            flight.abandoned = true
            flight.task.cancel()
        }
        flights[key] = flight
    }

    private func finish(key: String, flightID: UUID, result: Result<Void, Error>) {
        guard let flight = flights[key], flight.id == flightID else { return }
        flights[key] = nil
        for continuation in flight.waiters.values {
            // Callers of abandoned work were only waiting for it to stop; they
            // start afresh rather than inherit its cancellation.
            if flight.abandoned { continuation.resume() } else { continuation.resume(with: result) }
        }
    }
}

/// 16 kHz mono speech, read by range. The diarizer's input is already a 16 kHz
/// mono WAV, which is read straight from disk a window at a time; any other
/// format is converted once in memory so a caller cannot feed the wrong rate.
struct SpeechAudio {
    let count: Int
    private let file: AVAudioFile?
    private let converted: [Float]

    init(url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        if format.sampleRate == Double(TitaNetSpeakerEmbedder.sampleRate), format.channelCount == 1,
            format.commonFormat == .pcmFormatFloat32
        {
            self.file = file
            self.converted = []
            self.count = Int(file.length)
        } else {
            self.file = nil
            self.converted = try Self.convertAll(file)
            self.count = converted.count
        }
    }

    func samples(for ranges: [Range<Int>]) throws -> [Float] {
        var out: [Float] = []
        out.reserveCapacity(ranges.reduce(0) { $0 + $1.count })
        for range in ranges {
            guard let file else {
                out.append(contentsOf: converted[range])
                continue
            }
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(range.count)
            ) else { continue }
            file.framePosition = AVAudioFramePosition(range.lowerBound)
            try file.read(into: buffer, frameCount: AVAudioFrameCount(range.count))
            if let channel = buffer.floatChannelData {
                out.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
            }
        }
        return out
    }

    private static func convertAll(_ file: AVAudioFile) throws -> [Float] {
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(TitaNetSpeakerEmbedder.sampleRate),
            channels: 1, interleaved: false
        )!
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
            let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { return [] }
        try file.read(into: input)
        guard let converter = AVAudioConverter(from: sourceFormat, to: target) else { return [] }
        let ratio = target.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var supplied = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }
}

/// Diarizes with `inner`, then replaces each speaker's embedding with a TitaNet
/// voiceprint taken from the same audio. Segments, speakers and activity
/// durations pass through untouched, so clustering behaves exactly as before.
///
/// Only speakers the inner diarizer gave an embedding get a voiceprint: the
/// hybrid deliberately withholds one from a speaker whose voice is unclear or
/// shared, and that decision must survive the swap, or a mixed voice could be
/// saved as a sample. `voiceprintSpeechMsBySpeaker` carries the non-overlapped
/// speech each vector was made from, for the match and enrollment gates.
///
/// When TitaNet cannot run, the result carries no embeddings at all rather than
/// the inner diarizer's: a WeSpeaker vector would be stored as a candidate that
/// no TitaNet profile can ever score or accept.
public actor TitaNetVoiceprintDiarizationService: DiarizationServiceProtocol {
    private let inner: any DiarizationServiceProtocol
    private let embedder: TitaNetSpeakerEmbedder
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "TitaNetVoiceprints")

    public init(
        inner: any DiarizationServiceProtocol,
        embedder: TitaNetSpeakerEmbedder = TitaNetSpeakerEmbedder()
    ) {
        self.inner = inner
        self.embedder = embedder
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        let result = try await inner.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
        try Task.checkCancellation()
        var voiceprints: [String: TitaNetSpeakerEmbedder.Voiceprint] = [:]
        let eligible = Set(result.speakerEmbeddings.keys)
        if !eligible.isEmpty {
            do {
                let startedAt = Date()
                voiceprints = try await embedder.voiceprints(
                    audioURL: audioURL, segments: result.segments, speakers: eligible
                )
                logger.notice(
                    "titanet_voiceprints speakers=\(voiceprints.count, privacy: .public) eligible=\(eligible.count, privacy: .public) of=\(result.speakers.count, privacy: .public) duration_s=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public)"
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                logger.error("titanet_voiceprints_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
        return MacParakeetDiarizationResult(
            segments: result.segments,
            speakerCount: result.speakerCount,
            speakers: result.speakers,
            speakerEmbeddings: voiceprints.mapValues(\.embedding),
            speechMsBySpeaker: result.speechMsBySpeaker,
            voiceprintSpeechMsBySpeaker: voiceprints.mapValues(\.speechMs)
        )
    }

    /// The diarizer's models must be ready; the voiceprint model is best
    /// effort here and retried on first use, so a download problem costs
    /// voice matching, never speaker detection.
    public func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {
        try await inner.prepareModels(onProgress: onProgress)
        do {
            try await embedder.prepareModel()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("titanet_model_prepare_failed error=\(error.localizedDescription, privacy: .public)")
        }
    }

    public func isReady() async -> Bool {
        await inner.isReady()
    }

    public func hasCachedModels() async -> Bool {
        await inner.hasCachedModels()
    }

    public func explicitSpeakerConstraint() async -> SpeakerDiarizationConstraint? {
        await inner.explicitSpeakerConstraint()
    }
}
