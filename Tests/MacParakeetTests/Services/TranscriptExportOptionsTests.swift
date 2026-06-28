import XCTest
@testable import MacParakeetCore

/// Covers the availability + resolution logic behind the export dialog's
/// "Include timestamps"/"Include speaker labels" toggles. The view resolves the
/// user's options through `TranscriptExportOptions.resolved(...)` using these
/// `Transcription` predicates, so the displayed checkbox state and the written
/// file always agree.
@MainActor
final class TranscriptExportOptionsTests: XCTestCase {
    private let exportService = ExportService()

    private func words(withSpeaker: Bool) -> [WordTimestamp] {
        [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9,
                          speakerId: withSpeaker ? "S1" : nil),
            WordTimestamp(word: "world", startMs: 500, endMs: 1000, confidence: 0.9,
                          speakerId: withSpeaker ? "S1" : nil),
        ]
    }

    // MARK: - hasWordTimestamps

    func testHasWordTimestampsTrueWithWords() {
        let t = Transcription(fileName: "a.mp3", wordTimestamps: words(withSpeaker: false))
        XCTAssertTrue(t.hasWordTimestamps)
    }

    func testHasWordTimestampsFalseWhenNil() {
        let t = Transcription(fileName: "a.mp3", wordTimestamps: nil)
        XCTAssertFalse(t.hasWordTimestamps)
    }

    func testHasWordTimestampsFalseWhenEmpty() {
        let t = Transcription(fileName: "a.mp3", wordTimestamps: [])
        XCTAssertFalse(t.hasWordTimestamps)
    }

    // MARK: - hasSpeakerLabeledWords

    func testHasSpeakerLabeledWordsTrueWhenAttributed() {
        let t = Transcription(
            fileName: "a.mp3",
            wordTimestamps: words(withSpeaker: true),
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")]
        )
        XCTAssertTrue(t.hasSpeakerLabeledWords)
    }

    /// Words are present but none carries a `speakerId` (diarization ran but
    /// attributed nothing). Speaker labels cannot be exported, so this is false.
    /// Exercises the `contains { speakerId != nil }` branch.
    func testHasSpeakerLabeledWordsFalseWhenWordsHaveNoSpeakerId() {
        let t = Transcription(
            fileName: "a.mp3",
            wordTimestamps: words(withSpeaker: false),
            speakerCount: 3,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")]
        )
        XCTAssertFalse(t.hasSpeakerLabeledWords)
    }

    /// The motivating legacy / plain-text-engine state: a `speakers` roster
    /// exists (so the header shows "N speakers") but the engine emitted no word
    /// timings at all — Parakeet Unified / Cohere, or pre-#623 diarized records.
    /// Speaker labels cannot be exported, so this must be false. Exercises the
    /// `guard let wordTimestamps` branch.
    func testHasSpeakerLabeledWordsFalseWhenSpeakersButNoWordTimestamps() {
        let t = Transcription(
            fileName: "a.mp3",
            wordTimestamps: nil,
            speakerCount: 3,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")]
        )
        XCTAssertFalse(t.hasSpeakerLabeledWords)
    }

    func testHasSpeakerLabeledWordsFalseWhenNoSpeakers() {
        let t = Transcription(fileName: "a.mp3", wordTimestamps: words(withSpeaker: true), speakers: nil)
        XCTAssertFalse(t.hasSpeakerLabeledWords)
    }

    // MARK: - TranscriptExportOptions.resolved

    func testResolvedForcesUnavailableOptionsOff() {
        let resolved = TranscriptExportOptions().resolved(
            canIncludeTimestamps: false,
            canIncludeSpeakerLabels: false
        )
        XCTAssertFalse(resolved.includeTimestamps)
        XCTAssertFalse(resolved.includeSpeakerLabels)
        // Metadata has no data dependency and must never be forced off.
        XCTAssertTrue(resolved.includeMetadata)
    }

    func testResolvedKeepsAvailableOptionsOn() {
        let resolved = TranscriptExportOptions().resolved(
            canIncludeTimestamps: true,
            canIncludeSpeakerLabels: true
        )
        XCTAssertTrue(resolved.includeTimestamps)
        XCTAssertTrue(resolved.includeSpeakerLabels)
        XCTAssertTrue(resolved.includeMetadata)
    }

    func testResolvedRespectsUserOptOutEvenWhenAvailable() {
        let opts = TranscriptExportOptions(includeTimestamps: false, includeSpeakerLabels: false)
        let resolved = opts.resolved(canIncludeTimestamps: true, canIncludeSpeakerLabels: true)
        XCTAssertFalse(resolved.includeTimestamps)
        XCTAssertFalse(resolved.includeSpeakerLabels)
    }

    // MARK: - End-to-end: resolution controls the written file

    func testResolvedOptionsDriveMarkdownTimestamps() {
        let t = Transcription(
            fileName: "a.mp3",
            rawTranscript: "Hello world",
            wordTimestamps: words(withSpeaker: false),
            status: .completed
        )

        let withTimestamps = exportService.formatMarkdown(
            transcription: t,
            options: TranscriptExportOptions().resolved(canIncludeTimestamps: true, canIncludeSpeakerLabels: false)
        )
        XCTAssertTrue(withTimestamps.contains("**["), "Expected timestamp markers when timestamps are included")

        let withoutTimestamps = exportService.formatMarkdown(
            transcription: t,
            options: TranscriptExportOptions().resolved(canIncludeTimestamps: false, canIncludeSpeakerLabels: false)
        )
        XCTAssertFalse(withoutTimestamps.contains("**["), "Expected no timestamp markers once resolved off")
    }
}
