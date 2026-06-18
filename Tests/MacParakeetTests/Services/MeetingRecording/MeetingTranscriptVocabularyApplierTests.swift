import XCTest
@testable import MacParakeetCore

final class MeetingTranscriptVocabularyApplierTests: XCTestCase {

    private func word(
        _ text: String,
        _ startMs: Int,
        _ endMs: Int,
        speaker: String? = nil,
        confidence: Double = 0.9
    ) -> WordTimestamp {
        WordTimestamp(word: text, startMs: startMs, endMs: endMs, confidence: confidence, speakerId: speaker)
    }

    func testNoCustomWordsReturnsInputUnchanged() {
        let words = [word("acme", 0, 100), word("rocks", 100, 200)]
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "acme rocks",
            words: words,
            customWords: []
        )
        XCTAssertEqual(result.rawTranscript, "acme rocks")
        XCTAssertEqual(result.words, words)
    }

    func testCorrectsRawTranscriptAndWordTokens() {
        let words = [word("acme", 0, 100, speaker: "system"), word("rocks", 100, 200, speaker: "system")]
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "acme rocks",
            words: words,
            customWords: [CustomWord(word: "acme", replacement: "ACME Corp")]
        )
        XCTAssertEqual(result.rawTranscript, "ACME Corp rocks")
        XCTAssertEqual(result.words.map(\.word), ["ACME Corp", "rocks"])
    }

    func testPreservesTimestampsConfidenceAndSpeaker() {
        let original = word("k8s", 1_200, 1_650, speaker: "microphone", confidence: 0.42)
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "k8s",
            words: [original],
            customWords: [CustomWord(word: "k8s", replacement: "Kubernetes")]
        )
        let corrected = try! XCTUnwrap(result.words.first)
        XCTAssertEqual(corrected.word, "Kubernetes")
        XCTAssertEqual(corrected.startMs, original.startMs)
        XCTAssertEqual(corrected.endMs, original.endMs)
        XCTAssertEqual(corrected.confidence, original.confidence)
        XCTAssertEqual(corrected.speakerId, original.speakerId)
    }

    func testCorrectsAcrossMultipleSpeakers() {
        let words = [
            word("acme", 0, 100, speaker: "microphone"),
            word("and", 100, 200, speaker: "system"),
            word("acme", 200, 300, speaker: "system:speaker-1"),
        ]
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "acme and acme",
            words: words,
            customWords: [CustomWord(word: "acme", replacement: "ACME")]
        )
        XCTAssertEqual(result.words.map(\.word), ["ACME", "and", "ACME"])
        XCTAssertEqual(result.words.map(\.speakerId), ["microphone", "system", "system:speaker-1"])
    }

    func testDisabledCustomWordSkipped() {
        let words = [word("acme", 0, 100)]
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "acme",
            words: words,
            customWords: [CustomWord(word: "acme", replacement: "ACME", isEnabled: false)]
        )
        XCTAssertEqual(result.rawTranscript, "acme")
        XCTAssertEqual(result.words, words)
    }

    func testCaseInsensitiveCorrection() {
        let words = [word("Acme", 0, 100)]
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "Acme",
            words: words,
            customWords: [CustomWord(word: "acme", replacement: "ACME Corp")]
        )
        XCTAssertEqual(result.words.map(\.word), ["ACME Corp"])
    }

    func testTokenPrefilterPreservesPunctuationBoundaryCorrection() {
        let words = [word("acme,", 0, 100), word("next", 100, 200)]
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "acme, next",
            words: words,
            customWords: [CustomWord(word: "acme", replacement: "ACME")]
        )
        XCTAssertEqual(result.words.map(\.word), ["ACME,", "next"])
    }

    func testTokenPrefilterPreservesInternalBoundaryCorrection() {
        let words = [word("acme-based", 0, 100), word("vendor", 100, 200)]
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "acme-based vendor",
            words: words,
            customWords: [CustomWord(word: "acme", replacement: "ACME")]
        )
        XCTAssertEqual(result.words.map(\.word), ["ACME-based", "vendor"])
    }

    /// Multi-token rules rewrite the contiguous plain text, but per-word tokens
    /// are corrected individually, so a phrase split across tokens is corrected
    /// in `rawTranscript` only. Documents the known limitation.
    func testMultiWordPhraseCorrectsRawTranscriptButNotSplitTokens() {
        let words = [word("mac", 0, 100), word("parakeet", 100, 200)]
        let result = MeetingTranscriptVocabularyApplier.apply(
            rawTranscript: "mac parakeet ships",
            words: words,
            customWords: [CustomWord(word: "mac parakeet", replacement: "MacParakeet")]
        )
        XCTAssertEqual(result.rawTranscript, "MacParakeet ships")
        XCTAssertEqual(result.words.map(\.word), ["mac", "parakeet"])
    }
}
