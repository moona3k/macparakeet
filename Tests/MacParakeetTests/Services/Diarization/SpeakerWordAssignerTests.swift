import XCTest
@testable import MacParakeetCore

final class SpeakerWordAssignerTests: XCTestCase {
    func testExactOverlapWins() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 100, 300)],
            segments: [
                segment("S1", 0, 300),
                segment("S2", 290, 400),
            ]
        )

        XCTAssertEqual(result.words.map(\.speakerId), ["S1"])
        XCTAssertEqual(result.summary.directOverlapWords, 1)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
    }

    func testDirectOverlapNearTieWithinAmbiguityMarginLeavesFileWordUnassigned() {
        let result = SpeakerWordAssigner(ambiguityMarginMs: 150).assign(
            words: [word("hello", 100, 300)],
            segments: [
                segment("S1", 0, 251),
                segment("S2", 200, 400),
            ]
        )

        XCTAssertNil(result.words[0].speakerId)
        XCTAssertEqual(result.summary.unassignedWords, 1)
        XCTAssertEqual(result.summary.directOverlapWords, 0)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
    }

    func testDirectOverlapWinsWhenBestSpeakerClearsAmbiguityMargin() {
        let result = SpeakerWordAssigner(ambiguityMarginMs: 100).assign(
            words: [word("hello", 100, 300)],
            segments: [
                segment("S1", 0, 300),
                segment("S2", 250, 400),
            ]
        )

        XCTAssertEqual(result.words[0].speakerId, "S1")
        XCTAssertEqual(result.summary.directOverlapWords, 1)
        XCTAssertEqual(result.summary.unassignedWords, 0)
    }

    func testNearestBeforeFallbackWithinTolerance() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 1_000, 1_100)],
            segments: [segment("S1", 800, 950)]
        )

        XCTAssertEqual(result.words.map(\.speakerId), ["S1"])
        XCTAssertEqual(result.summary.directOverlapWords, 0)
        XCTAssertEqual(result.summary.fallbackNearestWords, 1)
    }

    func testNearestAfterFallbackWithinTolerance() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 1_000, 1_100)],
            segments: [segment("S1", 1_150, 1_300)]
        )

        XCTAssertEqual(result.words.map(\.speakerId), ["S1"])
        XCTAssertEqual(result.summary.directOverlapWords, 0)
        XCTAssertEqual(result.summary.fallbackNearestWords, 1)
    }

    func testNoFallbackAcrossLargeGap() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 1_000, 1_100)],
            segments: [segment("S1", 400, 500)]
        )

        XCTAssertNil(result.words[0].speakerId)
        XCTAssertEqual(result.summary.unassignedWords, 1)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
    }

    func testNoFallbackWhenDifferentSpeakersAreCloseAndAmbiguous() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 1_000, 1_100)],
            segments: [
                segment("S1", 800, 900),
                segment("S2", 1_220, 1_320),
            ]
        )

        XCTAssertNil(result.words[0].speakerId)
        XCTAssertEqual(result.summary.unassignedWords, 1)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
    }

    func testDoesNotAssignAcrossMicrophoneAndSystemBoundaries() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 1_000, 1_100, speakerId: AudioSource.microphone.rawValue)],
            segments: [segment(SpeakerID.systemSpeaker("S1"), 980, 1_120)],
            sourceOnlySpeakerId: AudioSource.system.rawValue
        )

        XCTAssertEqual(result.words[0].speakerId, AudioSource.microphone.rawValue)
        XCTAssertEqual(result.summary.directOverlapWords, 0)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
    }

    func testDirectOverlapTieFallsBackToSourceOnlyForMeetingWords() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 100, 300, speakerId: AudioSource.system.rawValue)],
            segments: [
                segment(SpeakerID.systemSpeaker("S1"), 0, 200),
                segment(SpeakerID.systemSpeaker("S2"), 200, 400),
            ],
            sourceOnlySpeakerId: AudioSource.system.rawValue
        )

        XCTAssertEqual(result.words[0].speakerId, AudioSource.system.rawValue)
        XCTAssertEqual(result.summary.sourceOnlyWords, 1)
        XCTAssertEqual(result.summary.directOverlapWords, 0)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
    }

    func testDirectOverlapTieLeavesFileWordsUnassigned() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 100, 300)],
            segments: [
                segment("S1", 0, 200),
                segment("S2", 200, 400),
            ]
        )

        XCTAssertNil(result.words[0].speakerId)
        XCTAssertEqual(result.summary.unassignedWords, 1)
        XCTAssertEqual(result.summary.directOverlapWords, 0)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
    }

    func testSourceOnlyMeetingWordsCountAsSourceOnly() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 100, 300, speakerId: AudioSource.system.rawValue)],
            segments: [],
            sourceOnlySpeakerId: AudioSource.system.rawValue
        )

        XCTAssertEqual(result.words[0].speakerId, AudioSource.system.rawValue)
        XCTAssertEqual(result.summary.totalWords, 1)
        XCTAssertEqual(result.summary.sourceOnlyWords, 1)
        XCTAssertEqual(result.summary.directOverlapWords, 0)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
        XCTAssertEqual(result.summary.unassignedWords, 0)
    }

    func testOutputOrderingIsDeterministicWhenStartTimesTie() {
        let result = SpeakerWordAssigner().assign(
            words: [
                word("beta", 100, 200),
                word("alpha", 100, 200),
                word("lead", 0, 50),
            ],
            segments: []
        )

        XCTAssertEqual(result.words.map(\.word), ["lead", "beta", "alpha"])
    }

    func testFallbackRefusesLowQualityCandidate() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 1_000, 1_100)],
            segments: [segment("S1", 800, 950, qualityScore: 0.59)]
        )

        XCTAssertNil(result.words[0].speakerId)
        XCTAssertEqual(result.summary.unassignedWords, 1)
        XCTAssertEqual(result.summary.fallbackNearestWords, 0)
    }

    func testDirectOverlapIgnoresFallbackQualityThreshold() {
        let result = SpeakerWordAssigner().assign(
            words: [word("hello", 1_000, 1_100)],
            segments: [segment("S1", 900, 1_200, qualityScore: 0.1)]
        )

        XCTAssertEqual(result.words[0].speakerId, "S1")
        XCTAssertEqual(result.summary.directOverlapWords, 1)
    }

    func testSummaryRecordsFallbackConfiguration() {
        let assigner = SpeakerWordAssigner(
            fallbackToleranceMs: 123,
            ambiguityMarginMs: 45,
            minFallbackQualityScore: 0.72
        )

        let result = assigner.assign(words: [], segments: [])

        XCTAssertEqual(result.summary.fallbackToleranceMs, 123)
        XCTAssertEqual(result.summary.ambiguityMarginMs, 45)
        XCTAssertEqual(result.summary.minFallbackQualityScore, 0.72)
    }

    private func word(
        _ text: String,
        _ startMs: Int,
        _ endMs: Int,
        speakerId: String? = nil
    ) -> WordTimestamp {
        WordTimestamp(word: text, startMs: startMs, endMs: endMs, confidence: 0.9, speakerId: speakerId)
    }

    private func segment(
        _ speakerId: String,
        _ startMs: Int,
        _ endMs: Int,
        qualityScore: Double = 1.0
    ) -> SpeakerSegment {
        SpeakerSegment(
            speakerId: speakerId,
            startMs: startMs,
            endMs: endMs,
            qualityScore: qualityScore
        )
    }
}
