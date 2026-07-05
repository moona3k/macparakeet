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

    func testDictationUnpreparedVocabularyReturnsUnboostedAndStartsBackgroundPreparation() async throws {
        let rescorer = FakeCustomVocabularyRescorer(text: "MacParakeet", isPrepared: false)
        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "MAC Parakeet",
            tokenTimings: Self.tokenTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer,
            preparationMode: .backgroundIfNeeded
        )

        XCTAssertEqual(result.text, "MAC Parakeet")
        let requestCount = await rescorer.requestCount()
        XCTAssertEqual(requestCount, 0)
        try await waitForPrepareCount(1, rescorer: rescorer)
    }

    func testDictationPreparedVocabularyBoostsWithoutPreparing() async throws {
        let rescorer = FakeCustomVocabularyRescorer(text: "MacParakeet", isPrepared: true)
        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "MAC Parakeet",
            tokenTimings: Self.tokenTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer,
            preparationMode: .backgroundIfNeeded
        )

        XCTAssertEqual(result.text, "MacParakeet")
        let prepareCount = await rescorer.prepareCount()
        let requestCount = await rescorer.requestCount()
        XCTAssertEqual(prepareCount, 0)
        XCTAssertEqual(requestCount, 1)
    }

    func testFileMeetingModeAwaitsPreparationBeforeBoosting() async throws {
        let rescorer = FakeCustomVocabularyRescorer(text: "MacParakeet", isPrepared: false)
        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "MAC Parakeet",
            tokenTimings: Self.tokenTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer,
            preparationMode: .awaitPreparation
        )

        XCTAssertEqual(result.text, "MacParakeet")
        let prepareCount = await rescorer.prepareCount()
        let requestCount = await rescorer.requestCount()
        XCTAssertEqual(prepareCount, 1)
        XCTAssertEqual(requestCount, 1)
    }

    func testDictationBackgroundPreparationPropagatesCancellationAfterReadinessProbe() async throws {
        let rescorer = FakeCustomVocabularyRescorer(
            text: "MacParakeet",
            isPrepared: false,
            isPreparedDelayNanoseconds: 50_000_000
        )
        let task = Task {
            try await STTRuntime.applyCustomVocabularyBoostingForTesting(
                transcript: "MAC Parakeet",
                tokenTimings: Self.tokenTimings,
                audioSamples: [0.1, 0.2, 0.3],
                capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
                vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
                rescorer: rescorer,
                preparationMode: .backgroundIfNeeded
            )
        }

        try await Task.sleep(nanoseconds: 10_000_000)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to escape cold dictation boosting")
        } catch is CancellationError {
            let prepareCount = await rescorer.prepareCount()
            let requestCount = await rescorer.requestCount()
            XCTAssertEqual(prepareCount, 0)
            XCTAssertEqual(requestCount, 0)
        }
    }

    func testDictationBackgroundPreparationCancelsBeforeSharedWarmupStarts() async throws {
        let rescorer = FakeCustomVocabularyRescorer(text: "MacParakeet", isPrepared: false)
        let registrationProbe = BackgroundPreparationRegistrationProbe()
        let task = Task {
            try await STTRuntime.applyCustomVocabularyBoostingForTesting(
                transcript: "MAC Parakeet",
                tokenTimings: Self.tokenTimings,
                audioSamples: [0.1, 0.2, 0.3],
                capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
                vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
                rescorer: rescorer,
                preparationMode: .backgroundIfNeeded,
                backgroundPreparationTaskRegistered: {
                    await registrationProbe.holdUntilReleased()
                }
            )
        }

        await registrationProbe.waitUntilRegistered()
        task.cancel()
        await registrationProbe.release()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to escape before background preparation starts")
        } catch is CancellationError {
            await Task.yield()
            let prepareCount = await rescorer.prepareCount()
            let requestCount = await rescorer.requestCount()
            XCTAssertEqual(prepareCount, 0)
            XCTAssertEqual(requestCount, 0)
        }
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

    func testBoundaryChangingBoostPreservesLongTranscriptWithSynthesizedChangedSpan() async throws {
        let rescorer = FakeCustomVocabularyRescorer(
            text: "please open MacParakeet now and save this note"
        )
        let words = ["please", "open", "mac", "parakeet", "now", "and", "save", "this", "note"]
        let longTimings = words.enumerated().map { index, word in
            TokenTiming(
                token: "▁\(word)",
                tokenId: index,
                startTime: Double(index),
                endTime: Double(index + 1),
                confidence: 0.9
            )
        }

        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: words.joined(separator: " "),
            tokenTimings: longTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["MacParakeet"]),
            rescorer: rescorer
        )

        let resultWords = STTWordTimingBuilder.words(from: result.tokenTimings)
        XCTAssertEqual(result.text, "please open MacParakeet now and save this note")
        XCTAssertEqual(resultWords.map(\.word), ["please", "open", "MacParakeet", "now", "and", "save", "this", "note"])
        XCTAssertEqual(resultWords[0].startMs, 0)
        XCTAssertEqual(resultWords[0].endMs, 1000)
        XCTAssertEqual(resultWords[2].startMs, 2000)
        XCTAssertEqual(resultWords[2].endMs, 4000)
        XCTAssertEqual(resultWords[3].startMs, 4000)
        XCTAssertEqual(resultWords[3].endMs, 5000)
    }

    func testBoundaryChangingBoostKeepsInsertedWordWhenOriginalTimingsOverlap() async throws {
        let rescorer = FakeCustomVocabularyRescorer(text: "alpha inserted beta")
        let overlappingTimings = [
            TokenTiming(token: "▁alpha", tokenId: 1, startTime: 0.0, endTime: 1.0, confidence: 0.9),
            TokenTiming(token: "▁beta", tokenId: 2, startTime: 0.9, endTime: 1.5, confidence: 0.9),
        ]

        let result = try await STTRuntime.applyCustomVocabularyBoostingForTesting(
            transcript: "alpha beta",
            tokenTimings: overlappingTimings,
            audioSamples: [0.1, 0.2, 0.3],
            capabilities: SpeechEngineCapabilityRegistry.capabilities(for: .parakeet(.v3)),
            vocabulary: CustomVocabularyBoostingVocabulary(terms: ["inserted"]),
            rescorer: rescorer
        )

        let resultWords = STTWordTimingBuilder.words(from: result.tokenTimings)
        XCTAssertEqual(result.text, "alpha inserted beta")
        XCTAssertEqual(resultWords.map(\.word), ["alpha", "inserted", "beta"])
        XCTAssertEqual(resultWords[1].startMs, 1000)
        XCTAssertEqual(resultWords[1].endMs, 1000)
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

    private func waitForPrepareCount(
        _ expectedCount: Int,
        rescorer: FakeCustomVocabularyRescorer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<50 {
            if await rescorer.prepareCount() == expectedCount {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let count = await rescorer.prepareCount()
        XCTAssertEqual(count, expectedCount, file: file, line: line)
    }
}

private actor BackgroundPreparationRegistrationProbe {
    private var registered = false
    private var released = false
    private var registrationWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func holdUntilReleased() async {
        registered = true
        let waiters = registrationWaiters
        registrationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitUntilRegistered() async {
        guard !registered else { return }
        await withCheckedContinuation { continuation in
            registrationWaiters.append(continuation)
        }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private actor FakeCustomVocabularyRescorer: CustomVocabularyRescoring {
    private(set) var requests: [CustomVocabularyRescoringRequest] = []
    private var prepared: Bool
    private var prepareCalls = 0
    private let text: String
    private let error: Error?
    private let isPreparedDelayNanoseconds: UInt64

    init(
        text: String = "boosted",
        error: Error? = nil,
        isPrepared: Bool = true,
        isPreparedDelayNanoseconds: UInt64 = 0
    ) {
        self.text = text
        self.error = error
        self.prepared = isPrepared
        self.isPreparedDelayNanoseconds = isPreparedDelayNanoseconds
    }

    func isPrepared(vocabulary: CustomVocabularyBoostingVocabulary) async -> Bool {
        if isPreparedDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: isPreparedDelayNanoseconds)
        }
        return prepared
    }

    func prepare(vocabulary: CustomVocabularyBoostingVocabulary) async throws {
        prepareCalls += 1
        prepared = true
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

    func prepareCount() -> Int {
        prepareCalls
    }
}

private enum TestError: Error {
    case expected
}
