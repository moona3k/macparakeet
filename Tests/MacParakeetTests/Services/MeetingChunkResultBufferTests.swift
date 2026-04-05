import XCTest
@testable import MacParakeetCore

final class MeetingChunkResultBufferTests: XCTestCase {
    func testReceiveSuccessDrainsResultsInSequenceOrder() {
        var buffer = MeetingChunkResultBuffer()

        let lateChunk = AudioChunker.AudioChunk(samples: [1], startMs: 4_000, endMs: 9_000)
        let earlyChunk = AudioChunker.AudioChunk(samples: [0], startMs: 0, endMs: 5_000)
        let lateResult = STTResult(text: "again", words: [
            TimestampedWord(word: "again", startMs: 0, endMs: 100, confidence: 0.9),
        ])
        let earlyResult = STTResult(text: "hello", words: [
            TimestampedWord(word: "hello", startMs: 0, endMs: 100, confidence: 0.9),
        ])

        let firstDrain = buffer.receiveSuccess(
            sequence: 1,
            source: .microphone,
            chunk: lateChunk,
            result: lateResult
        )
        let secondDrain = buffer.receiveSuccess(
            sequence: 0,
            source: .microphone,
            chunk: earlyChunk,
            result: earlyResult
        )

        XCTAssertTrue(firstDrain.isEmpty)
        XCTAssertEqual(secondDrain.map { $0.chunk.startMs }, [0, 4_000])
        XCTAssertEqual(secondDrain.map { $0.result.text }, ["hello", "again"])
    }

    func testReceiveFailureAllowsLaterBufferedResultsToDrain() {
        var buffer = MeetingChunkResultBuffer()

        let laterChunk = AudioChunker.AudioChunk(samples: [1], startMs: 4_000, endMs: 9_000)
        let laterResult = STTResult(text: "again", words: [
            TimestampedWord(word: "again", startMs: 0, endMs: 100, confidence: 0.9),
        ])

        let firstDrain = buffer.receiveSuccess(
            sequence: 1,
            source: .system,
            chunk: laterChunk,
            result: laterResult
        )
        let secondDrain = buffer.receiveFailure(sequence: 0, source: .system)

        XCTAssertTrue(firstDrain.isEmpty)
        XCTAssertEqual(secondDrain.count, 1)
        XCTAssertEqual(secondDrain.first?.chunk.startMs, 4_000)
        XCTAssertEqual(secondDrain.first?.result.text, "again")
    }
}
