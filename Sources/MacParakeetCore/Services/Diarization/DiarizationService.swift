import FluidAudio
import Foundation

public struct MacParakeetDiarizationResult: Sendable {
    public let segments: [SpeakerSegment]
    public let speakerCount: Int
    public let speakers: [SpeakerInfo]

    public init(segments: [SpeakerSegment], speakerCount: Int, speakers: [SpeakerInfo]) {
        self.segments = segments
        self.speakerCount = speakerCount
        self.speakers = speakers
    }
}

public struct SpeakerSegment: Sendable {
    public let speakerId: String
    public let startMs: Int
    public let endMs: Int
    public let qualityScore: Double

    public init(speakerId: String, startMs: Int, endMs: Int, qualityScore: Double = 1.0) {
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
        self.qualityScore = qualityScore
    }
}

public enum SpeakerDiarizationConstraint: Equatable, Sendable {
    case exact(Int)
    case range(min: Int?, max: Int?)

    public var speakerCountHint: SpeakerCountHint {
        switch self {
        case .exact(let count):
            return SpeakerCountHint(exact: count)
        case .range(let min, let max):
            return SpeakerCountHint(minimum: min, maximum: max)
        }
    }
}

public protocol DiarizationServiceProtocol: Sendable {
    func diarize(
        audioURL: URL,
        options: DiarizationOptions
    ) async throws -> MacParakeetDiarizationResult

    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
    func hasCachedModels() async -> Bool
}

public extension DiarizationServiceProtocol {
    func diarize(audioURL: URL) async throws -> MacParakeetDiarizationResult {
        try await diarize(audioURL: audioURL, options: .default)
    }

    func prepareModels() async throws {
        try await prepareModels(onProgress: nil)
    }

    func hasCachedModels() async -> Bool {
        false
    }
}

protocol OfflineDiarizerManaging: AnyObject, Sendable {
    func prepareModels(at directory: URL) async throws
    func process(audioURL: URL) async throws -> DiarizationResult
}

extension OfflineDiarizerManager: OfflineDiarizerManaging {
    func prepareModels(at directory: URL) async throws {
        try await prepareModels(directory: directory)
    }

    func process(audioURL: URL) async throws -> DiarizationResult {
        try await process(audioURL)
    }
}

// @unchecked Sendable: all access is serialized through DiarizationService actor isolation.
extension OfflineDiarizerManager: @retroactive @unchecked Sendable {}

public actor DiarizationService: DiarizationServiceProtocol {
    private let baseConfig: OfflineDiarizerConfig
    private let makeManager: @Sendable (OfflineDiarizerConfig) -> any OfflineDiarizerManaging
    private let modelsDirectory: URL
    private var modelsReady = false

    public init(
        config: OfflineDiarizerConfig = .default,
        modelsDirectory: URL? = nil
    ) {
        self.init(
            baseConfig: config,
            modelsDirectory: modelsDirectory ?? OfflineDiarizerModels.defaultModelsDirectory(),
            makeManager: { OfflineDiarizerManager(config: $0) }
        )
    }

    public init(
        speakerConstraint: SpeakerDiarizationConstraint,
        modelsDirectory: URL? = nil
    ) {
        self.init(
            config: Self.offlineConfig(speakerConstraint: speakerConstraint),
            modelsDirectory: modelsDirectory
        )
    }

    init(
        baseConfig: OfflineDiarizerConfig,
        modelsDirectory: URL,
        makeManager: @escaping @Sendable (OfflineDiarizerConfig) -> any OfflineDiarizerManaging
    ) {
        self.baseConfig = baseConfig
        self.makeManager = makeManager
        self.modelsDirectory = modelsDirectory.standardizedFileURL
    }

    public func diarize(
        audioURL: URL,
        options: DiarizationOptions
    ) async throws -> MacParakeetDiarizationResult {
        try options.validate()
        let config = Self.offlineConfig(baseConfig: baseConfig, options: options)
        let manager = makeManager(config)
        try await prepareModels(for: manager)

        let fluidResult: DiarizationResult
        do {
            fluidResult = try await manager.process(audioURL: audioURL)
        } catch let error as OfflineDiarizationError where error.isNoSpeechDetected {
            return MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: [])
        }

        // Sort by start time before assigning stable IDs so "S1" is the
        // first speaker to *talk* (chronologically), not the first speaker
        // to appear in whatever order FluidAudio's offline pipeline happens
        // to return segments. FluidAudio doesn't formally document the
        // ordering of its `segments` array, so we don't rely on it.
        let chronologicalSegments = fluidResult.segments.sorted { lhs, rhs in
            lhs.startTimeSeconds < rhs.startTimeSeconds
        }

        // Collect unique speaker IDs from FluidAudio (e.g. "speaker_0", "speaker_1")
        // and normalize to stable IDs ("S1", "S2") in chronological encounter order.
        var idMapping: [String: String] = [:]
        var nextIndex = 1
        for segment in chronologicalSegments {
            if idMapping[segment.speakerId] == nil {
                idMapping[segment.speakerId] = "S\(nextIndex)"
                nextIndex += 1
            }
        }

        let segments: [SpeakerSegment] = chronologicalSegments.map { seg in
            let mappedId = idMapping[seg.speakerId] ?? seg.speakerId
            let startMs = max(0, Int((seg.startTimeSeconds * 1000).rounded()))
            let endMs = max(0, Int((seg.endTimeSeconds * 1000).rounded()))
            return SpeakerSegment(
                speakerId: mappedId,
                startMs: startMs,
                endMs: endMs,
                qualityScore: Double(seg.qualityScore)
            )
        }

        let speakers: [SpeakerInfo] = idMapping
            .sorted { Int($0.value.dropFirst()) ?? 0 < Int($1.value.dropFirst()) ?? 0 }
            .map { rawProviderSpeakerId, stableId in
                let number = String(stableId.dropFirst())
                return SpeakerInfo(
                    id: stableId,
                    label: "Speaker \(number)",
                    rawProviderSpeakerId: rawProviderSpeakerId,
                    labelSource: .modelDefault
                )
            }

        return MacParakeetDiarizationResult(
            segments: segments,
            speakerCount: speakers.count,
            speakers: speakers
        )
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        onProgress?("Downloading speaker models...")
        let manager = makeManager(baseConfig)
        try await prepareModels(for: manager)
        onProgress?("Speaker models ready")
    }

    private func prepareModels(for manager: any OfflineDiarizerManaging) async throws {
        try await manager.prepareModels(at: modelsDirectory)
        modelsReady = true
    }

    public func isReady() async -> Bool {
        modelsReady
    }

    public func hasCachedModels() async -> Bool {
        Self.isModelCached(directory: modelsDirectory)
    }

    public nonisolated static func isModelCached(directory: URL? = nil) -> Bool {
        let repoDirectory = modelCacheDirectory(directory: directory)
        return requiredModelNames().allSatisfy { modelName in
            FileManager.default.fileExists(
                atPath: repoDirectory.appendingPathComponent(modelName, isDirectory: false).path
            )
        }
    }

    public nonisolated static func clearModelCache(directory: URL? = nil) {
        try? FileManager.default.removeItem(at: modelCacheDirectory(directory: directory))
    }

    nonisolated static func modelCacheDirectory(directory: URL? = nil) -> URL {
        let baseDirectory = (directory ?? OfflineDiarizerModels.defaultModelsDirectory()).standardizedFileURL
        return baseDirectory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
    }

    nonisolated static func requiredModelNames() -> [String] {
        Array(ModelNames.OfflineDiarizer.requiredModels)
    }

    nonisolated static func offlineConfig(
        speakerConstraint: SpeakerDiarizationConstraint?
    ) -> OfflineDiarizerConfig {
        let config = OfflineDiarizerConfig.default
        guard let speakerConstraint else { return config }

        switch speakerConstraint {
        case .exact(let count):
            return config.withSpeakers(exactly: count)
        case .range(let min, let max):
            return config.withSpeakers(min: min, max: max)
        }
    }

    nonisolated static func offlineConfig(
        baseConfig: OfflineDiarizerConfig,
        options: DiarizationOptions
    ) -> OfflineDiarizerConfig {
        var config = baseConfig
        guard let hint = options.speakerCountHint else { return config }

        if let exact = hint.exact {
            config.clustering.numSpeakers = exact
            config.clustering.minSpeakers = nil
            config.clustering.maxSpeakers = nil
        } else {
            config.clustering.numSpeakers = nil
            config.clustering.minSpeakers = hint.minimum
            config.clustering.maxSpeakers = hint.maximum
        }

        return config
    }
}

extension OfflineDiarizationError {
    var isNoSpeechDetected: Bool {
        if case .noSpeechDetected = self { return true }
        return false
    }
}

public actor MockDiarizationService: DiarizationServiceProtocol {
    public var diarizeResult: MacParakeetDiarizationResult?
    public var diarizeError: Error?
    public var diarizeCalled = false
    public var diarizeOptions: [DiarizationOptions] = []
    public var prepareModelsCalled = false
    public var prepareModelsError: Error?
    public var ready = false
    public var cachedModels = false

    public init() {}

    public func configure(result: MacParakeetDiarizationResult) {
        self.diarizeResult = result
        self.diarizeError = nil
    }

    public func configure(error: Error) {
        self.diarizeError = error
        self.diarizeResult = nil
    }

    public func configurePrepareModels(error: Error?) {
        self.prepareModelsError = error
    }

    public func configureReady(_ ready: Bool) {
        self.ready = ready
    }

    public func configureCachedModels(_ cachedModels: Bool) {
        self.cachedModels = cachedModels
    }

    public func diarize(
        audioURL: URL,
        options: DiarizationOptions
    ) async throws -> MacParakeetDiarizationResult {
        diarizeCalled = true
        diarizeOptions.append(options)
        if let error = diarizeError { throw error }
        return diarizeResult ?? MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: [])
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws {
        prepareModelsCalled = true
        if let error = prepareModelsError { throw error }
        ready = true
        cachedModels = true
    }

    public func isReady() async -> Bool {
        ready
    }

    public func hasCachedModels() async -> Bool {
        cachedModels
    }
}
