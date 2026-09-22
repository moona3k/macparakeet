import XCTest
@testable import MacParakeetCore

final class MeetingTranscriptAssemblerTests: XCTestCase {
    func testApplyDeduplicatesOverlapForSingleSource() {
        var assembler = MeetingTranscriptAssembler()

        let firstChunk = AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000)
        let firstResult = STTResult(text: "Hello team", words: [
            TimestampedWord(word: "Hello", startMs: 100, endMs: 400, confidence: 0.9),
            TimestampedWord(word: "team", startMs: 4_200, endMs: 4_600, confidence: 0.9),
        ])
        _ = assembler.apply(result: firstResult, chunk: firstChunk, source: .microphone)

        let secondChunk = AudioChunker.AudioChunk(samples: [0], startMs: 4_000, endMs: 9_000)
        let secondResult = STTResult(text: "team again", words: [
            TimestampedWord(word: "team", startMs: 100, endMs: 500, confidence: 0.9),
            TimestampedWord(word: "again", startMs: 700, endMs: 1_000, confidence: 0.9),
        ])
        let update = assembler.apply(result: secondResult, chunk: secondChunk, source: .microphone)

        XCTAssertEqual(update.words.map(\.word), ["Hello", "team", "again"])
        XCTAssertEqual(update.words.map(\.speakerId), ["microphone", "microphone", "microphone"])
    }

    func testApplySynthesizesLivePreviewWordsForTextOnlyResult() {
        var assembler = MeetingTranscriptAssembler()

        let chunk = AudioChunker.AudioChunk(samples: [0], startMs: 4_000, endMs: 9_000)
        let result = STTResult(text: "Hello unified world.", words: [])
        let update = assembler.apply(result: result, chunk: chunk, source: .microphone)

        XCTAssertEqual(update.words.map(\.word), ["Hello", "unified", "world."])
        XCTAssertEqual(update.words.map(\.speakerId), ["microphone", "microphone", "microphone"])
        XCTAssertEqual(update.words.first?.startMs, 0)
        XCTAssertEqual(update.words.last?.endMs, 5_000)
        XCTAssertEqual(update.speakers, [SpeakerInfo(id: "microphone", label: "Me")])
    }

    func testApplyTrimsTextOnlyOverlapPrefix() {
        var assembler = MeetingTranscriptAssembler()

        _ = assembler.apply(
            result: STTResult(text: "Hello team", words: []),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .microphone
        )

        let update = assembler.apply(
            result: STTResult(text: "Team, again", words: []),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 4_000, endMs: 9_000),
            source: .microphone
        )

        XCTAssertEqual(update.words.map(\.word), ["Hello", "team", "again"])
        XCTAssertEqual(update.words.last?.startMs, 5_000)
        XCTAssertEqual(update.words.last?.endMs, 9_000)
    }

    func testApplyPreservesRepeatedPrefixForContiguousTextOnlyChunks() {
        var assembler = MeetingTranscriptAssembler()

        _ = assembler.apply(
            result: STTResult(text: "yes", words: []),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 1_000),
            source: .microphone
        )

        let update = assembler.apply(
            result: STTResult(text: "yes please", words: []),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 1_000, endMs: 3_000),
            source: .microphone
        )

        XCTAssertEqual(update.words.map(\.word), ["yes", "yes", "please"])
        XCTAssertEqual(update.words[1].startMs, 1_000)
        XCTAssertEqual(update.words.last?.endMs, 3_000)
    }

    func testApplyIgnoresTextOnlyResultWithoutWords() {
        var assembler = MeetingTranscriptAssembler()

        let update = assembler.apply(
            result: STTResult(text: " \n\t ", words: []),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .microphone
        )

        XCTAssertTrue(update.words.isEmpty)
        XCTAssertTrue(update.speakers.isEmpty)
    }

    func testFinalizedTranscriptBuildsSpeakerMetadataAcrossSources() {
        var assembler = MeetingTranscriptAssembler()

        _ = assembler.apply(
            result: STTResult(text: "Hello there", words: [
                TimestampedWord(word: "Hello", startMs: 0, endMs: 300, confidence: 0.9),
                TimestampedWord(word: "there", startMs: 320, endMs: 650, confidence: 0.9),
            ]),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .microphone
        )

        _ = assembler.apply(
            result: STTResult(text: "Sounds good", words: [
                TimestampedWord(word: "Sounds", startMs: 900, endMs: 1_200, confidence: 0.9),
                TimestampedWord(word: "good", startMs: 1_250, endMs: 1_500, confidence: 0.9),
            ]),
            chunk: AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000),
            source: .system
        )

        let transcript = assembler.finalizedTranscript(durationMs: 1_500)

        XCTAssertEqual(transcript?.speakerCount, 2)
        XCTAssertEqual(transcript?.speakers, [
            SpeakerInfo(id: "microphone", label: "Me"),
            SpeakerInfo(id: "system", label: "Others"),
        ])
        XCTAssertEqual(transcript?.words.map(\.word), ["Hello", "there", "Sounds", "good"])
        XCTAssertEqual(transcript?.diarizationSegments.count, 2)
        XCTAssertEqual(transcript?.rawTranscript, "Hello there Sounds good")
    }
}
