import FluidAudio
import Foundation
import os

public enum CustomVocabularyBoostingConfiguration {
    /// Phase 0 showed this stricter gate kept OOV recall at 74% while keeping
    /// LibriSpeech `test-clean` WER within +0.102 pt; see
    /// `docs/research/2026-07-04-custom-vocab-phase0.md`.
    public static let minSimilarity: Float = 0.65
    public static let minTermLength: Int = 3
    /// Product v1 avoids loading multi-hour file/meeting audio into RAM for the
    /// sidecar. Longer jobs keep FluidAudio's URL-backed TDT path and skip
    /// boosting until chunked sidecar rescoring lands.
    public static let maxSidecarAudioSeconds: Double = 5 * 60
    public static let termWeight: Float = 10.0
    public static let maxCachedVocabularyEntries: Int = 3

    static var maxSidecarSampleCount: Int {
        Int(maxSidecarAudioSeconds * Double(ASRConstants.sampleRate))
    }
}

public struct CustomVocabularyBoostingSupportPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public enum CustomVocabularyBoostingPresentation {
    public static func status(
        for capabilities: SpeechEngineCapabilities?,
        recognitionBoostingEnabled: Bool = true
    ) -> CustomVocabularyBoostingSupportPresentation {
        guard let capabilities else {
            return CustomVocabularyBoostingSupportPresentation(
                title: "Clean corrections only",
                detail:
                    "This engine does not support recognition-time vocabulary boosting; enabled rules still run after transcription."
            )
        }
        return status(for: capabilities, recognitionBoostingEnabled: recognitionBoostingEnabled)
    }

    public static func status(
        for capabilities: SpeechEngineCapabilities,
        recognitionBoostingEnabled: Bool = true
    ) -> CustomVocabularyBoostingSupportPresentation {
        if capabilities.supportsCustomVocabulary {
            guard recognitionBoostingEnabled else {
                return CustomVocabularyBoostingSupportPresentation(
                    title: "Clean corrections only",
                    detail:
                        "Recognition boosting is paused; enabled rules still run after transcription."
                )
            }
            return CustomVocabularyBoostingSupportPresentation(
                title: "Recognition boosting on",
                detail:
                    "Enabled anchors boost Parakeet TDT recognition; replacement rules still run after transcription."
            )
        }

        return CustomVocabularyBoostingSupportPresentation(
            title: "Clean corrections only",
            detail:
                "\(displayName(for: capabilities.key)) does not support recognition-time vocabulary boosting; enabled rules still run after transcription."
        )
    }

    public static func status(for key: SpeechEngineVariantKey) -> CustomVocabularyBoostingSupportPresentation {
        status(for: SpeechEngineCapabilityRegistry.capabilities(for: key))
    }

    private static func displayName(for key: SpeechEngineVariantKey) -> String {
        switch key {
        case .parakeet(let variant):
            "Parakeet \(variant.displayName)"
        case .nemotron(let variant):
            "Nemotron \(variant.displayName)"
        case .whisper(let variant):
            "Whisper \(variant.displayName)"
        case .cohere:
            "Cohere"
        }
    }
}

public struct CustomVocabularyBoostingVocabulary: Equatable, Sendable {
    public static let empty = CustomVocabularyBoostingVocabulary(terms: [])

    public let terms: [String]
    public let contentHash: String

    public var isEmpty: Bool { terms.isEmpty }

    public init(terms: [String]) {
        self.terms = Self.canonicalTerms(terms)
        self.contentHash = Self.contentHash(for: self.terms)
    }

    public static func mapping(
        from words: [CustomWord],
        minTermLength: Int = CustomVocabularyBoostingConfiguration.minTermLength
    ) -> CustomVocabularyBoostingVocabulary {
        CustomVocabularyBoostingVocabulary(
            terms: words.compactMap { word in
                guard word.isEnabled else { return nil }
                if let replacement = word.replacement,
                    !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                {
                    return nil
                }

                let term = word.word.trimmingCharacters(in: .whitespacesAndNewlines)
                guard term.count >= minTermLength else { return nil }
                return term
            }
        )
    }

    private static func canonicalTerms(_ terms: [String]) -> [String] {
        struct Entry {
            let key: String
            let text: String
        }

        var seenKeys: Set<String> = []
        return
            terms
            .compactMap { rawTerm -> Entry? in
                let term = rawTerm.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !term.isEmpty else { return nil }
                let key = term.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                return Entry(key: key, text: term)
            }
            .sorted {
                if $0.key != $1.key {
                    return $0.key < $1.key
                }
                return $0.text < $1.text
            }
            .compactMap { entry in
                guard seenKeys.insert(entry.key).inserted else { return nil }
                return entry.text
            }
    }

    private static func contentHash(for terms: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for term in terms {
            for byte in term.utf8 {
                hash ^= UInt64(byte)
                hash &*= 0x100000001b3
            }
            hash ^= 0xff
            hash &*= 0x100000001b3
        }
        return String(format: "%016llx", hash)
    }
}

public protocol CustomVocabularyBoostingTermProviding: Sendable {
    func currentVocabulary() async -> CustomVocabularyBoostingVocabulary
}

public struct CustomVocabularyRescoringRequest: Sendable {
    public let transcript: String
    public let tokenTimings: [TokenTiming]?
    public let audioSamples: [Float]
    public let vocabulary: CustomVocabularyBoostingVocabulary

    public init(
        transcript: String,
        tokenTimings: [TokenTiming]?,
        audioSamples: [Float],
        vocabulary: CustomVocabularyBoostingVocabulary
    ) {
        self.transcript = transcript
        self.tokenTimings = tokenTimings
        self.audioSamples = audioSamples
        self.vocabulary = vocabulary
    }
}

public struct CustomVocabularyRescoringResult: Sendable {
    public let text: String
    public let detectedTerms: [String]
    public let appliedTerms: [String]
    public let replacementCount: Int

    public init(
        text: String,
        detectedTerms: [String],
        appliedTerms: [String],
        replacementCount: Int
    ) {
        self.text = text
        self.detectedTerms = detectedTerms
        self.appliedTerms = appliedTerms
        self.replacementCount = replacementCount
    }
}

public protocol CustomVocabularyRescoring: Sendable {
    func isPrepared(vocabulary: CustomVocabularyBoostingVocabulary) async -> Bool
    func prepare(vocabulary: CustomVocabularyBoostingVocabulary) async throws
    func rescore(_ request: CustomVocabularyRescoringRequest) async throws -> CustomVocabularyRescoringResult
}

public extension CustomVocabularyRescoring {
    func isPrepared(vocabulary: CustomVocabularyBoostingVocabulary) async -> Bool { true }
    func prepare(vocabulary: CustomVocabularyBoostingVocabulary) async throws {}
}

public enum CustomVocabularyBoostingError: Error, Sendable {
    case emptyTokenizedVocabulary
    case unpreparedVocabulary
}

public struct RepositoryCustomVocabularyBoostingTermProvider: CustomVocabularyBoostingTermProviding {
    private let repository: any CustomWordRepositoryProtocol
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CustomVocabulary")

    public init(repository: any CustomWordRepositoryProtocol) {
        self.repository = repository
    }

    public func currentVocabulary() async -> CustomVocabularyBoostingVocabulary {
        do {
            return CustomVocabularyBoostingVocabulary.mapping(from: try repository.fetchEnabled())
        } catch {
            logger.warning(
                "custom_vocabulary_fetch_failed error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            return .empty
        }
    }
}

public actor FluidAudioCustomVocabularyRescorer: CustomVocabularyRescoring {
    private struct CtcResources: Sendable {
        let models: CtcModels
        let modelDirectory: URL
        let tokenizer: CtcTokenizer
    }

    private struct CachedVocabulary: Sendable {
        let hash: String
        let context: CustomVocabularyContext
        let spotter: CtcKeywordSpotter
        let rescorer: VocabularyRescorer
        let cbw: Float
        let marginSeconds: Double
    }

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "CustomVocabulary")
    private var cachedResources: CtcResources?
    private var resourceLoadTask: Task<CtcResources, Error>?
    private var cachedVocabularies: [String: CachedVocabulary] = [:]
    private var cachedVocabularyLoadTasks: [String: Task<CachedVocabulary, Error>] = [:]
    private var cachedVocabularyOrder: [String] = []

    public init() {}

    public func prepare(vocabulary: CustomVocabularyBoostingVocabulary) async throws {
        guard !vocabulary.isEmpty else { return }
        _ = try await components(for: vocabulary)
    }

    public func isPrepared(vocabulary: CustomVocabularyBoostingVocabulary) async -> Bool {
        vocabulary.isEmpty || cachedVocabularies[vocabulary.contentHash] != nil
    }

    public func rescore(_ request: CustomVocabularyRescoringRequest) async throws -> CustomVocabularyRescoringResult {
        guard !request.vocabulary.isEmpty,
            !request.audioSamples.isEmpty,
            let tokenTimings = request.tokenTimings,
            !tokenTimings.isEmpty
        else {
            return CustomVocabularyRescoringResult(
                text: request.transcript,
                detectedTerms: [],
                appliedTerms: [],
                replacementCount: 0
            )
        }

        guard let components = cachedVocabularies[request.vocabulary.contentHash] else {
            throw CustomVocabularyBoostingError.unpreparedVocabulary
        }

        let spotResult = try await components.spotter.spotKeywordsWithLogProbs(
            audioSamples: request.audioSamples,
            customVocabulary: components.context,
            minScore: nil
        )

        guard !spotResult.logProbs.isEmpty else {
            return CustomVocabularyRescoringResult(
                text: request.transcript,
                detectedTerms: [],
                appliedTerms: [],
                replacementCount: 0
            )
        }

        let output = components.rescorer.ctcTokenRescore(
            transcript: request.transcript,
            tokenTimings: tokenTimings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration,
            cbw: components.cbw,
            marginSeconds: components.marginSeconds,
            minSimilarity: CustomVocabularyBoostingConfiguration.minSimilarity
        )
        let detected = Self.uniquePreservingOrder(spotResult.detections.map { $0.term.text })
        let applied = Self.uniquePreservingOrder(
            output.replacements.compactMap { replacement in
                replacement.shouldReplace ? replacement.replacementWord : nil
            }
        )
        let replacementCount = output.replacements.filter(\.shouldReplace).count

        if output.wasModified {
            logger.info(
                "custom_vocabulary_boost_applied terms=\(request.vocabulary.terms.count, privacy: .public) replacements=\(replacementCount, privacy: .public)"
            )
        }

        return CustomVocabularyRescoringResult(
            text: output.text,
            detectedTerms: detected,
            appliedTerms: applied,
            replacementCount: replacementCount
        )
    }

    private func components(for vocabulary: CustomVocabularyBoostingVocabulary) async throws -> CachedVocabulary {
        if let cachedVocabulary = cachedVocabularies[vocabulary.contentHash] {
            rememberCachedVocabularyHash(vocabulary.contentHash)
            return cachedVocabulary
        }

        let hash = vocabulary.contentHash
        if let loadTask = cachedVocabularyLoadTasks[hash] {
            let cachedVocabulary: CachedVocabulary
            do {
                cachedVocabulary = try await loadTask.value
            } catch {
                if !(error is CancellationError) {
                    cachedVocabularyLoadTasks.removeValue(forKey: hash)
                }
                throw error
            }
            storeCachedVocabulary(cachedVocabulary)
            return cachedVocabulary
        }

        try Task.checkCancellation()
        let loadTask = Task.detached { [self, vocabulary] in
            let resources = try await self.ctcResources()
            return try await Self.makeCachedVocabulary(
                vocabulary: vocabulary,
                resources: resources
            )
        }
        cachedVocabularyLoadTasks[hash] = loadTask

        do {
            let cachedVocabulary = try await loadTask.value
            let shouldLogLoad = cachedVocabularies[hash] == nil
            storeCachedVocabulary(cachedVocabulary)
            if shouldLogLoad {
                logger.info(
                    "custom_vocabulary_boost_loaded terms=\(cachedVocabulary.context.terms.count, privacy: .public)"
                )
            }
            return cachedVocabulary
        } catch {
            if !(error is CancellationError) {
                cachedVocabularyLoadTasks.removeValue(forKey: hash)
            }
            throw error
        }
    }

    private func ctcResources() async throws -> CtcResources {
        if let cachedResources {
            return cachedResources
        }

        if let resourceLoadTask {
            do {
                let resources = try await resourceLoadTask.value
                cachedResources = resources
                self.resourceLoadTask = nil
                return resources
            } catch {
                if !(error is CancellationError) {
                    self.resourceLoadTask = nil
                }
                throw error
            }
        }

        let loadTask = Task.detached {
            try await Self.loadCtcResources()
        }
        resourceLoadTask = loadTask

        do {
            let resources = try await loadTask.value
            cachedResources = resources
            resourceLoadTask = nil
            return resources
        } catch {
            if !(error is CancellationError) {
                resourceLoadTask = nil
            }
            throw error
        }
    }

    private static func loadCtcResources() async throws -> CtcResources {
        try Task.checkCancellation()
        let modelDirectory = AppPaths.fluidAudioModelDirectory(for: CtcModelVariant.ctc110m.repo)
        let models = try await CtcModels.downloadAndLoad(to: modelDirectory, variant: .ctc110m)
        try Task.checkCancellation()
        let tokenizer = try await CtcTokenizer.load(from: modelDirectory)
        try Task.checkCancellation()
        let resources = CtcResources(
            models: models,
            modelDirectory: modelDirectory,
            tokenizer: tokenizer
        )
        return resources
    }

    private static func makeCachedVocabulary(
        vocabulary: CustomVocabularyBoostingVocabulary,
        resources: CtcResources
    ) async throws -> CachedVocabulary {
        try Task.checkCancellation()
        let tokenizedTerms = vocabulary.terms.compactMap { term -> CustomVocabularyTerm? in
            let tokenIds = resources.tokenizer.encode(term)
            guard !tokenIds.isEmpty else { return nil }
            return CustomVocabularyTerm(
                text: term,
                weight: CustomVocabularyBoostingConfiguration.termWeight,
                aliases: nil,
                tokenIds: nil,
                ctcTokenIds: tokenIds
            )
        }
        guard !tokenizedTerms.isEmpty else {
            throw CustomVocabularyBoostingError.emptyTokenizedVocabulary
        }

        let context = CustomVocabularyContext(
            terms: tokenizedTerms,
            minSimilarity: CustomVocabularyBoostingConfiguration.minSimilarity,
            minTermLength: CustomVocabularyBoostingConfiguration.minTermLength
        )
        let spotter = CtcKeywordSpotter(models: resources.models, blankId: resources.models.vocabulary.count)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: context,
            config: .default,
            ctcModelDirectory: resources.modelDirectory
        )
        try Task.checkCancellation()
        let sizeConfig = ContextBiasingConstants.rescorerConfig(forVocabSize: context.terms.count)
        return CachedVocabulary(
            hash: vocabulary.contentHash,
            context: context,
            spotter: spotter,
            rescorer: rescorer,
            cbw: sizeConfig.cbw,
            marginSeconds: ContextBiasingConstants.defaultMarginSeconds
        )
    }

    private func rememberCachedVocabularyHash(_ hash: String) {
        cachedVocabularyOrder.removeAll { $0 == hash }
        cachedVocabularyOrder.append(hash)
    }

    private func evictStaleCachedVocabularies() {
        while cachedVocabularyOrder.count > CustomVocabularyBoostingConfiguration.maxCachedVocabularyEntries {
            let removed = cachedVocabularyOrder.removeFirst()
            cachedVocabularies.removeValue(forKey: removed)
        }
    }

    private func storeCachedVocabulary(_ cachedVocabulary: CachedVocabulary) {
        let hash = cachedVocabulary.hash
        cachedVocabularyLoadTasks.removeValue(forKey: hash)
        cachedVocabularies[hash] = cachedVocabulary
        rememberCachedVocabularyHash(hash)
        evictStaleCachedVocabularies()
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
