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

    public static var defaultModelDirectory: URL {
        URL(fileURLWithPath: AppPaths.appSupportDir, isDirectory: true)
            .appendingPathComponent("models/speaker-voiceprint", isDirectory: true)
    }

    private let modelDirectory: URL
    private let archiveURL: URL
    private let archiveBytes: Int
    private let archiveSHA256: String
    private let fetch: @Sendable (URL) async throws -> Data
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
    /// Verified before anything is written, and installed by a single move, so
    /// a failed or cancelled transfer never leaves a half model behind. The
    /// actor serializes concurrent callers; the second finds it installed.
    public func prepareModel() async throws {
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

    /// Loads the compiled model, downloading the package and compiling it once
    /// when needed.
    func loadedModel() async throws -> MLModel {
        if let model { return model }
        let files = FileManager.default
        if !files.fileExists(atPath: compiledModelURL.path) {
            if !files.fileExists(atPath: packageURL.path) {
                try await prepareModel()
            }
            guard files.fileExists(atPath: packageURL.path) else {
                throw TitaNetSpeakerEmbedderError.modelMissing(packageURL)
            }
            let compiled = try await MLModel.compileModel(at: packageURL)
            try? files.removeItem(at: compiledModelURL)
            try files.moveItem(at: compiled, to: compiledModelURL)
        }
        let configuration = MLModelConfiguration()
        // FP32 export: the spectrogram front end overflows in FP16, which the
        // Neural Engine would force. CPU+GPU runs a 10 s window in ~8 ms.
        configuration.computeUnits = .cpuAndGPU
        let loaded = try MLModel(contentsOf: compiledModelURL, configuration: configuration)
        model = loaded
        return loaded
    }

    /// Voiceprints for every speaker in `segments` with usable speech.
    /// `segments` are in the audio file's own timeline.
    public func speakerEmbeddings(
        audioURL: URL,
        segments: [SpeakerSegment]
    ) async throws -> [String: SpeakerEmbedding] {
        let model = try await loadedModel()
        let samples = try Self.readMono16k(audioURL)
        var result: [String: SpeakerEmbedding] = [:]
        for speakerId in Set(segments.map(\.speakerId)) {
            try Task.checkCancellation()
            let regions = Self.exclusiveRegions(of: speakerId, in: segments)
            let speech = Self.concatenate(samples: samples, regions: regions)
            guard let vector = try embed(speech: speech, model: model) else { continue }
            result[speakerId] = SpeakerEmbedding(
                rawVector: Self.padded(vector), identity: SpeakerVoiceprintModel.identity
            )
        }
        return result
    }

    /// One voiceprint for a stretch of speech, or `nil` when it is too short.
    func embed(speech: [Float], model: MLModel) throws -> [Float]? {
        var windows = Self.windows(count: speech.count)
        guard !windows.isEmpty else { return nil }
        if windows.count > Self.maxWindowsPerSpeaker {
            let last = Double(windows.count - 1)
            let step = last / Double(Self.maxWindowsPerSpeaker - 1)
            windows = (0..<Self.maxWindowsPerSpeaker).map { windows[Int((Double($0) * step).rounded())] }
        }

        let audio = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSamples)], dataType: .float32)
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        var sum = [Float](repeating: 0, count: Self.outputDimension)
        for window in windows {
            try Task.checkCancellation()
            let pointer = audio.dataPointer.bindMemory(to: Float.self, capacity: Self.windowSamples)
            pointer.initialize(repeating: 0, count: Self.windowSamples)
            speech.withUnsafeBufferPointer { source in
                pointer.update(from: source.baseAddress! + window.lowerBound, count: window.count)
            }
            length[0] = NSNumber(value: Int32(window.count))
            let output = try model.prediction(
                from: MLDictionaryFeatureProvider(dictionary: [
                    "audio": MLFeatureValue(multiArray: audio),
                    "length": MLFeatureValue(multiArray: length),
                ])
            )
            guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue,
                embedding.count == Self.outputDimension
            else { throw TitaNetSpeakerEmbedderError.unexpectedOutput }
            var values = (0..<Self.outputDimension).map { embedding[$0].floatValue }
            let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
            guard norm.isFinite, norm > 0 else { continue }
            let weight = Float(window.count) / norm
            for index in values.indices {
                values[index] *= weight
                sum[index] += values[index]
            }
        }
        return sum
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

    static func concatenate(samples: [Float], regions: [Range<Int>]) -> [Float] {
        var speech: [Float] = []
        for region in regions {
            let start = min(samples.count, region.lowerBound * sampleRate / 1000)
            let end = min(samples.count, region.upperBound * sampleRate / 1000)
            if end > start { speech.append(contentsOf: samples[start..<end]) }
        }
        return speech
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

    /// The diarizer's input is already 16 kHz mono WAV; anything else is
    /// converted here so a caller cannot silently feed the wrong rate.
    static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false
        )!
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
            let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount)
        else { return [] }
        try file.read(into: input)

        if sourceFormat.sampleRate == target.sampleRate, sourceFormat.channelCount == 1,
            sourceFormat.commonFormat == .pcmFormatFloat32, let channel = input.floatChannelData
        {
            return Array(UnsafeBufferPointer(start: channel[0], count: Int(input.frameLength)))
        }

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

/// Diarizes with `inner`, then replaces every speaker's embedding with a TitaNet
/// voiceprint taken from the same audio. Segments, speakers and durations pass
/// through untouched, so clustering behaves exactly as before.
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
        let embeddings: [String: SpeakerEmbedding]
        do {
            let startedAt = Date()
            embeddings = try await embedder.speakerEmbeddings(audioURL: audioURL, segments: result.segments)
            logger.notice(
                "titanet_voiceprints speakers=\(embeddings.count, privacy: .public) of=\(result.speakers.count, privacy: .public) duration_s=\(String(format: "%.2f", Date().timeIntervalSince(startedAt)), privacy: .public)"
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("titanet_voiceprints_failed error=\(error.localizedDescription, privacy: .public)")
            embeddings = [:]
        }
        return MacParakeetDiarizationResult(
            segments: result.segments,
            speakerCount: result.speakerCount,
            speakers: result.speakers,
            speakerEmbeddings: embeddings,
            speechMsBySpeaker: result.speechMsBySpeaker
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
