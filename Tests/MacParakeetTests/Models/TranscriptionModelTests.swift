import XCTest
@testable import MacParakeetCore

final class TranscriptionModelTests: XCTestCase {

    func testDefaultInit() {
        let t = Transcription(fileName: "recording.mp3")

        XCTAssertFalse(t.id.uuidString.isEmpty)
        XCTAssertEqual(t.fileName, "recording.mp3")
        XCTAssertNil(t.filePath)
        XCTAssertNil(t.fileSizeBytes)
        XCTAssertNil(t.durationMs)
        XCTAssertNil(t.rawTranscript)
        XCTAssertNil(t.cleanTranscript)
        XCTAssertNil(t.wordTimestamps)
        XCTAssertEqual(t.language, "en")
        XCTAssertNil(t.speakerCount)
        XCTAssertNil(t.speakers)
        XCTAssertEqual(t.status, .processing)
        XCTAssertNil(t.errorMessage)
        XCTAssertNil(t.exportPath)
    }

    func testStatusRawValues() {
        XCTAssertEqual(Transcription.TranscriptionStatus.processing.rawValue, "processing")
        XCTAssertEqual(Transcription.TranscriptionStatus.completed.rawValue, "completed")
        XCTAssertEqual(Transcription.TranscriptionStatus.error.rawValue, "error")
        XCTAssertEqual(Transcription.TranscriptionStatus.cancelled.rawValue, "cancelled")
    }

    func testWordTimestampInit() {
        let w = WordTimestamp(word: "hello", startMs: 100, endMs: 500, confidence: 0.95)

        XCTAssertEqual(w.word, "hello")
        XCTAssertEqual(w.startMs, 100)
        XCTAssertEqual(w.endMs, 500)
        XCTAssertEqual(w.confidence, 0.95)
    }

    func testWordTimestampCodableRoundTrip() throws {
        let original = WordTimestamp(word: "test", startMs: 0, endMs: 300, confidence: 0.99)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(WordTimestamp.self, from: data)

        XCTAssertEqual(decoded.word, original.word)
        XCTAssertEqual(decoded.startMs, original.startMs)
        XCTAssertEqual(decoded.endMs, original.endMs)
        XCTAssertEqual(decoded.confidence, original.confidence)
    }

    func testTranscriptionWithAllFields() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 200, confidence: 0.99),
            WordTimestamp(word: "world", startMs: 210, endMs: 500, confidence: 0.97),
        ]

        let t = Transcription(
            fileName: "meeting.mp4",
            filePath: "/Users/test/meeting.mp4",
            fileSizeBytes: 1024 * 1024 * 50,
            durationMs: 500,
            rawTranscript: "Hello world",
            cleanTranscript: "Hello, world.",
            wordTimestamps: words,
            language: "en",
            speakerCount: 1,
            speakers: ["Speaker 1"],
            status: .completed,
            errorMessage: nil,
            exportPath: "/tmp/export.txt"
        )

        XCTAssertEqual(t.wordTimestamps?.count, 2)
        XCTAssertEqual(t.fileSizeBytes, 52_428_800)
        XCTAssertEqual(t.speakers, ["Speaker 1"])
        XCTAssertEqual(t.exportPath, "/tmp/export.txt")
    }

    func testTranscriptionCodableRoundTrip() throws {
        let original = Transcription(
            fileName: "test.wav",
            durationMs: 5000,
            rawTranscript: "Hello",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 0.98)
            ],
            status: .completed
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Transcription.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.fileName, original.fileName)
        XCTAssertEqual(decoded.rawTranscript, original.rawTranscript)
        XCTAssertEqual(decoded.wordTimestamps?.count, 1)
        XCTAssertEqual(decoded.status, original.status)
    }
}
