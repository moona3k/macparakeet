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

    public init(speakerId: String, startMs: Int, endMs: Int) {
        self.speakerId = speakerId
        self.startMs = startMs
        self.endMs = endMs
    }
}

public protocol DiarizationServiceProtocol: Sendable {
    func diarize(audioURL: URL) async throws -> MacParakeetDiarizationResult
    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
    func hasCachedModels() async -> Bool
}

extension DiarizationServiceProtocol {
    public func prepareModels() async throws {
        try await prepareModels(onProgress: nil)
    }

    public func hasCachedModels() async -> Bool {
        false
    }
}

public actor DiarizationService: DiarizationServiceProtocol {
    private let manager: OfflineDiarizerManager
    private let modelsDirectory: URL
    private var modelsReady = false

    public init(
        config: OfflineDiarizerConfig = .default,
        modelsDirectory: URL? = nil
    ) {
        self.manager = OfflineDiarizerManager(config: config)
        self.modelsDirectory = (modelsDirectory ?? OfflineDiarizerModels.defaultModelsDirectory()).standardizedFileURL
    }

    public func diarize(audioURL: URL) async throws -> MacParakeetDiarizationResult {
        let fluidResult: DiarizationResult
        do {
            fluidResult = try await manager.process(audioURL)
        } catch let error as OfflineDiarizationError where error.isNoSpeechDetected {
            return MacParakeetDiarizationResult(segments: [], speakerCount: 0, speakers: [])
        }

        // Collect unique speaker IDs from FluidAudio (e.g. "speaker_0", "speaker_1")
        // and normalize to stable IDs ("S1", "S2")
        var idMapping: [String: String] = [:]
        var nextIndex = 1
        for segment in fluidResult.segments {
            if idMapping[segment.speakerId] == nil {
                idMapping[segment.speakerId] = "S\(nextIndex)"
                nextIndex += 1
            }
        }

        let segments: [SpeakerSegment] = fluidResult.segments.map { seg in
            let mappedId = idMapping[seg.speakerId] ?? seg.speakerId
            let startMs = max(0, Int((seg.startTimeSeconds * 1000).rounded()))
            let endMs = max(0, Int((seg.endTimeSeconds * 1000).rounded()))
            return SpeakerSegment(speakerId: mappedId, startMs: startMs, endMs: endMs)
        }

        let speakers: [SpeakerInfo] = idMapping
            .sorted { Int($0.value.dropFirst()) ?? 0 < Int($1.value.dropFirst()) ?? 0 }
            .map { _, stableId in
                let number = String(stableId.dropFirst())
                return SpeakerInfo(id: stableId, label: "Speaker \(number)")
            }

        return MacParakeetDiarizationResult(
            segments: segments,
            speakerCount: speakers.count,
            speakers: speakers
        )
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        onProgress?("Downloading speaker models...")
        try await manager.prepareModels(directory: modelsDirectory)
        modelsReady = true
        onProgress?("Speaker models ready")
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

    public func diarize(audioURL: URL) async throws -> MacParakeetDiarizationResult {
        diarizeCalled = true
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
