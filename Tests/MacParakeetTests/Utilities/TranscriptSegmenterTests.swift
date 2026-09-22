import XCTest
@testable import MacParakeetCore

final class TranscriptSegmenterTests: XCTestCase {

    // MARK: - groupIntoSegments

    func testEmptyWordsReturnsEmptySegments() {
        let segments = TranscriptSegmenter.groupIntoSegments(words: [])
        XCTAssertTrue(segments.isEmpty)
    }

    func testSingleWordReturnsOneSegment() {
        let words = [WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9)]
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[0].startMs, 0)
    }

    func testSegmentBreaksOnPunctuationAfterThreeWords() {
        let words = [
            WordTimestamp(word: "This", startMs: 0, endMs: 200, confidence: 0.9),
            WordTimestamp(word: "is", startMs: 300, endMs: 400, confidence: 0.9),
            WordTimestamp(word: "great.", startMs: 500, endMs: 700, confidence: 0.9),
            WordTimestamp(word: "And", startMs: 800, endMs: 900, confidence: 0.9),
            WordTimestamp(word: "more.", startMs: 1000, endMs: 1200, confidence: 0.9),
        ]
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "This is great.")
        XCTAssertEqual(segments[1].text, "And more.")
    }

    func testSegmentBreaksOnLongGap() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9),
            WordTimestamp(word: "world", startMs: 2500, endMs: 3000, confidence: 0.9),
        ]
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[1].text, "world")
    }

    func testSegmentBreaksOnSpeakerChange() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "Hi", startMs: 600, endMs: 800, confidence: 0.9, speakerId: "s2"),
        ]
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].speakerId, "s1")
        XCTAssertEqual(segments[1].speakerId, "s2")
    }

    func testSegmentFlushesAt40Words() {
        // Create 45 words with no punctuation and no gaps
        let words = (0..<45).map { i in
            WordTimestamp(word: "word\(i)", startMs: i * 100, endMs: i * 100 + 80, confidence: 0.9)
        }
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        XCTAssertEqual(segments.count, 2)
        // First segment should have exactly 40 words
        XCTAssertEqual(segments[0].text.components(separatedBy: " ").count, 40)
        XCTAssertEqual(segments[1].text.components(separatedBy: " ").count, 5)
    }

    func testPunctuationWithFewerThan3WordsDoesNotSplit() {
        let words = [
            WordTimestamp(word: "Hi.", startMs: 0, endMs: 200, confidence: 0.9),
            WordTimestamp(word: "Yes.", startMs: 300, endMs: 500, confidence: 0.9),
            WordTimestamp(word: "OK.", startMs: 600, endMs: 800, confidence: 0.9),
        ]
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        // 3 words with punctuation, count >= 3 on the third, so should split after third
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hi. Yes. OK.")
    }

    func testNilSpeakerIdInheritsAfterPunctuationFlush() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 200, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "there", startMs: 300, endMs: 400, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "friend.", startMs: 500, endMs: 700, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "How", startMs: 800, endMs: 900, confidence: 0.9),
            WordTimestamp(word: "are", startMs: 1000, endMs: 1100, confidence: 0.9),
            WordTimestamp(word: "you.", startMs: 1200, endMs: 1400, confidence: 0.9),
        ]
        let segments = TranscriptSegmenter.groupIntoSegments(words: words)
        XCTAssertEqual(segments.last?.speakerId, "s1")
    }

    func testMaterializeSegmentsAddsDurableIdentityEndTimeLabelsAndWordRanges() {
        let words = [
            WordTimestamp(word: "This", startMs: 0, endMs: 120, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "is", startMs: 140, endMs: 220, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "done.", startMs: 240, endMs: 520, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "Remote", startMs: 640, endMs: 820, confidence: 0.9, speakerId: "s2"),
            WordTimestamp(word: "answer", startMs: 840, endMs: 1_000, confidence: 0.9, speakerId: "s2"),
        ]
        var ids = [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        ]

        let segments = TranscriptSegmenter.materializeSegments(
            words: words,
            speakers: [
                SpeakerInfo(id: "s1", label: "Dana"),
                SpeakerInfo(id: "s2", label: "Riley"),
            ],
            idGenerator: { ids.removeFirst() }
        )

        XCTAssertEqual(segments.map(\.id), [
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        ])
        XCTAssertEqual(segments.map(\.text), ["This is done.", "Remote answer"])
        XCTAssertEqual(segments.map(\.startMs), [0, 640])
        XCTAssertEqual(segments.map(\.endMs), [520, 1_000])
        XCTAssertEqual(segments.map(\.speakerId), ["s1", "s2"])
        XCTAssertEqual(segments.map(\.speakerLabel), ["Dana", "Riley"])
        XCTAssertEqual(segments.map(\.wordRange), [
            TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 3),
            TranscriptSegmentWordRange(startIndex: 3, endIndexExclusive: 5),
        ])

        let presentationSegments = TranscriptSegmenter.groupIntoSegments(words: words)
        XCTAssertEqual(presentationSegments.map(\.text), segments.map(\.text))
        XCTAssertEqual(presentationSegments.map(\.startMs), segments.map(\.startMs))
        XCTAssertEqual(presentationSegments.map(\.speakerId), segments.map(\.speakerId))
    }

    func testMaterializeSegmentsUsesSourceLabelsWhenSpeakerRosterIsAbsent() {
        let words = [
            WordTimestamp(word: "Local", startMs: 0, endMs: 100, confidence: 0.9, speakerId: "microphone"),
            WordTimestamp(word: "track.", startMs: 120, endMs: 240, confidence: 0.9, speakerId: "microphone"),
            WordTimestamp(word: "Remote", startMs: 260, endMs: 400, confidence: 0.9, speakerId: "system"),
        ]

        let segments = TranscriptSegmenter.materializeSegments(words: words)

        XCTAssertEqual(segments.map(\.speakerLabel), ["Me", "Others"])
    }

    // MARK: - groupIntoSpeakerTurns

    func testEmptySegmentsReturnsEmptyTurns() {
        let turns = TranscriptSegmenter.groupIntoSpeakerTurns(segments: []) { _ in "Unknown" }
        XCTAssertTrue(turns.isEmpty)
    }

    func testConsecutiveSameSpeakerMergedIntoOneTurn() {
        let segments = [
            TranscriptSegment(startMs: 0, text: "Hello", speakerId: "s1"),
            TranscriptSegment(startMs: 1000, text: "World", speakerId: "s1"),
        ]
        let turns = TranscriptSegmenter.groupIntoSpeakerTurns(segments: segments) { id in
            id == "s1" ? "Speaker 1" : "Unknown"
        }
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].segments.count, 2)
        XCTAssertEqual(turns[0].speakerLabel, "Speaker 1")
    }

    func testDifferentSpeakersCreateSeparateTurns() {
        let segments = [
            TranscriptSegment(startMs: 0, text: "Hello", speakerId: "s1"),
            TranscriptSegment(startMs: 1000, text: "Hi", speakerId: "s2"),
            TranscriptSegment(startMs: 2000, text: "Bye", speakerId: "s1"),
        ]
        let turns = TranscriptSegmenter.groupIntoSpeakerTurns(segments: segments) { _ in "S" }
        XCTAssertEqual(turns.count, 3)
    }

    func testSpeakerTurnsWithNilSpeakerIdInherits() {
        let segments = [
            TranscriptSegment(startMs: 0, text: "Hello", speakerId: "s1"),
            TranscriptSegment(startMs: 1000, text: "World", speakerId: nil),
        ]
        let turns = TranscriptSegmenter.groupIntoSpeakerTurns(segments: segments) { id in
            id == "s1" ? "Speaker 1" : "Unknown"
        }
        // nil speakerId inherits current speaker, so should be one turn
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].segments.count, 2)
    }

    // MARK: - computeSpeakerStats

    func testSpeakerStatsFromDiarizationAndWords() {
        let diarization = [
            DiarizationSegmentRecord(speakerId: "s1", startMs: 0, endMs: 5000),
            DiarizationSegmentRecord(speakerId: "s2", startMs: 5000, endMs: 8000),
        ]
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "there", startMs: 600, endMs: 900, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "Hi", startMs: 5000, endMs: 5500, confidence: 0.9, speakerId: "s2"),
        ]
        let stats = TranscriptSegmenter.computeSpeakerStats(
            diarizationSegments: diarization,
            wordTimestamps: words
        )
        XCTAssertEqual(stats["s1"]?.speakingTimeMs, 5000)
        XCTAssertEqual(stats["s1"]?.wordCount, 2)
        XCTAssertEqual(stats["s2"]?.speakingTimeMs, 3000)
        XCTAssertEqual(stats["s2"]?.wordCount, 1)
    }

    func testSpeakerStatsWithNilArguments() {
        let stats = TranscriptSegmenter.computeSpeakerStats(diarizationSegments: nil, wordTimestamps: nil)
        XCTAssertTrue(stats.isEmpty)
    }

    func testSpeakerStatsSkipsNilSpeakerWords() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9, speakerId: "s1"),
            WordTimestamp(word: "there", startMs: 600, endMs: 900, confidence: 0.9),  // nil speakerId
        ]
        let stats = TranscriptSegmenter.computeSpeakerStats(diarizationSegments: nil, wordTimestamps: words)
        XCTAssertEqual(stats["s1"]?.wordCount, 1)
        XCTAssertNil(stats[""])  // nil speakerId words should not create an entry
    }

    // MARK: - sanitizedExportStem

    func testSanitizedExportStemRemovesDisallowedChars() {
        XCTAssertEqual(TranscriptSegmenter.sanitizedExportStem(from: "my/file:name.txt"), "my file name")
    }

    func testSanitizedExportStemFallsBackToTranscript() {
        XCTAssertEqual(TranscriptSegmenter.sanitizedExportStem(from: ""), "transcript")
    }

    func testSanitizedExportStemPreservesNormalName() {
        XCTAssertEqual(TranscriptSegmenter.sanitizedExportStem(from: "interview.m4a"), "interview")
    }
}
