import FluidAudio
@testable import MacParakeetCore
import XCTest

final class CustomVocabularyBoostingTests: XCTestCase {
    func testMapperUsesEnabledBlankReplacementWordsOnly() {
        let vocabulary = CustomVocabularyBoostingVocabulary.mapping(
            from: [
                CustomWord(word: "MacParakeet", replacement: nil),
                CustomWord(word: "FluidAudio", replacement: ""),
                CustomWord(word: "aye pee eye", replacement: "API"),
                CustomWord(word: "disabled", replacement: nil, isEnabled: false),
                CustomWord(word: "go", replacement: nil),
            ],
            minTermLength: 3
        )

        XCTAssertEqual(vocabulary.terms, ["FluidAudio", "MacParakeet"])
        XCTAssertFalse(vocabulary.isEmpty)
    }

    func testMapperContentHashChangesWhenVocabularyContentChanges() {
        let first = CustomVocabularyBoostingVocabulary.mapping(
            from: [CustomWord(word: "MacParakeet"), CustomWord(word: "FluidAudio")],
            minTermLength: 3
        )
        let reordered = CustomVocabularyBoostingVocabulary.mapping(
            from: [CustomWord(word: "FluidAudio"), CustomWord(word: "MacParakeet")],
            minTermLength: 3
        )
        let changed = CustomVocabularyBoostingVocabulary.mapping(
            from: [CustomWord(word: "MacParakeet"), CustomWord(word: "Fluid Audio")],
            minTermLength: 3
        )

        XCTAssertEqual(first.contentHash, reordered.contentHash)
        XCTAssertNotEqual(first.contentHash, changed.contentHash)
    }

    func testMapperCanonicalizesDuplicateCasingDeterministically() {
        let first = CustomVocabularyBoostingVocabulary(
            terms: ["MacParakeet", "macparakeet", "FluidAudio"]
        )
        let reversed = CustomVocabularyBoostingVocabulary(
            terms: ["FluidAudio", "macparakeet", "MacParakeet"]
        )

        XCTAssertEqual(first.terms, reversed.terms)
        XCTAssertEqual(first.contentHash, reversed.contentHash)
    }

    func testUnsupportedEngineSkipsSidecarInvocation() async throws {
        let rescorer = FakeCustomVocabularyRescorer()
        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "MAC Parakeet",
            tokenTimings: Self.tokenTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.unified)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer
        )

        XCTAssertEqual(result.text, "MAC Parakeet")
        let requestCount = await rescorer.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testEmptyVocabularySkipsSidecarInvocation() async throws {
        let rescorer = FakeCustomVocabularyRescorer()
        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "MAC Parakeet",
            tokenTimings: Self.tokenTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: .empty,
            rescorer: rescorer
        )

        XCTAssertEqual(result.text, "MAC Parakeet")
        let requestCount = await rescorer.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    func testSupportedEngineInvokesSidecarWithOriginalSamples() async throws {
        let rescorer = FakeCustomVocabularyRescorer(text: "MacParakeet")
        let samples: [Float] = [0.1, 0.2, 0.3, 0.0, 0.0]
        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "MAC Parakeet",
            tokenTimings: Self.tokenTimings,
            audioSamples: samples,
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer
        )

        XCTAssertEqual(result.text, "MacParakeet")
        XCTAssertEqual(STTWordTimingBuilder.words(from: result.tokenTimings).map(\.word), ["MacParakeet"])
        XCTAssertEqual(STTWordTimingBuilder.words(from: result.tokenTimings).first?.startMs, 0)
        XCTAssertEqual(STTWordTimingBuilder.words(from: result.tokenTimings).first?.endMs, 600)
        let requests = await rescorer.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].audioSamples, samples)
        XCTAssertEqual(requests[0].vocabulary.terms, ["MacParakeet"])
    }

    func testBoundaryChangingBoostSkipsLongTranscriptTimingSynthesis() async throws {
        let rescorer = FakeCustomVocabularyRescorer(text: "MacParakeet")
        let longTimings = (0..<(CustomVocabularyBoostingConfiguration.maxBoundaryChangingTimingWordCount + 1))
            .map { index in
                TokenTiming(
                    token: "▁word\(index)",
                    tokenId: index,
                    startTime: Double(index),
                    endTime: Double(index + 1),
                    confidence: 0.9
                )
            }

        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: longTimings.map(\.token).joined(separator: " ").replacingOccurrences(of: "▁", with: ""),
            tokenTimings: longTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer
        )

        XCTAssertNotEqual(result.text, "MacParakeet")
        XCTAssertEqual(STTWordTimingBuilder.words(from: result.tokenTimings).count, longTimings.count)
    }

    func testSidecarFailureFallsBackToUnboostedTranscript() async throws {
        let rescorer = FakeCustomVocabularyRescorer(error: TestError.expected)
        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "MAC Parakeet",
            tokenTimings: Self.tokenTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer
        )

        XCTAssertEqual(result.text, "MAC Parakeet")
        let requestCount = await rescorer.requestCount()
        XCTAssertEqual(requestCount, 1)
    }

    func testCancellationEscapesSidecarBoosting() async throws {
        let rescorer = FakeCustomVocabularyRescorer(error: CancellationError())

        do {
            _ = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
                transcript: "MAC Parakeet",
                tokenTimings: Self.tokenTimings,
                audioSamples: [0.1, 0.2, 0.3],
                capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
                vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
                rescorer: rescorer
            )
            XCTFail("Expected cancellation to escape vocabulary boosting")
        } catch is CancellationError {
            let requestCount = await rescorer.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    private static let tokenTimings = [
        TokenTiming(token: "▁MAC", tokenId: 1, startTime: 0.0, endTime: 0.2, confidence: 0.9),
        TokenTiming(token: "▁Parakeet", tokenId: 2, startTime: 0.2, endTime: 0.6, confidence: 0.9),
    ]
}

private actor FakeCustomVocabularyRescorer: CustomVocabularyRescoring {
    private(set) var requests: [CustomVocabularyRescoringRequest] = []
    private let text: String
    private let error: Error?

    init(text: String = "boosted", error: Error? = nil) {
        self.text = text
        self.error = error
    }

    func rescore(_ request: CustomVocabularyRescoringRequest) async throws -> CustomVocabularyRescoringResult {
        requests.append(request)
        if let error {
            throw error
        }
        return CustomVocabularyRescoringResult(
            text: text,
            detectedTerms: request.vocabulary.terms,
            appliedTerms: request.vocabulary.terms,
            replacementCount: request.vocabulary.terms.count
        )
    }

    func requestCount() -> Int {
        requests.count
    }
}

private enum TestError: Error {
    case expected
}
