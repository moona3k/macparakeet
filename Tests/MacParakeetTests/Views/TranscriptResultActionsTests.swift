import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class TranscriptResultActionsTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bulk-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
    }

    func testBulkExportWritesCollisionSafeFiles() async throws {
        let first = Transcription(
            fileName: "call.m4a",
            rawTranscript: "First transcript",
            status: .completed
        )
        let second = Transcription(
            fileName: "call.mp3",
            rawTranscript: "Second transcript",
            status: .completed
        )
        try "Existing".write(
            to: tempDir.appendingPathComponent("call.txt"),
            atomically: true,
            encoding: .utf8
        )

        let result = try await TranscriptResultActions.exportTranscriptsToDirectory(
            transcriptions: [first, second],
            format: .txt,
            options: TranscriptExportOptions(
                includeTimestamps: false,
                includeSpeakerLabels: false,
                includeMetadata: false
            ),
            directory: tempDir
        )

        XCTAssertEqual(result.requestedCount, 2)
        XCTAssertEqual(result.exportedCount, 2)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(result.exportedURLs.map(\.lastPathComponent), ["call (1).txt", "call (2).txt"])
        XCTAssertEqual(
            try String(contentsOf: tempDir.appendingPathComponent("call (1).txt"), encoding: .utf8),
            "First transcript"
        )
        XCTAssertEqual(
            try String(contentsOf: tempDir.appendingPathComponent("call (2).txt"), encoding: .utf8),
            "Second transcript"
        )
        XCTAssertEqual(
            try String(contentsOf: tempDir.appendingPathComponent("call.txt"), encoding: .utf8),
            "Existing"
        )
    }

    func testBulkExportResolvesOptionsPerTranscript() async throws {
        let timed = Transcription(
            fileName: "timed.m4a",
            rawTranscript: "Hello world.",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.9),
                WordTimestamp(word: "world.", startMs: 500, endMs: 1000, confidence: 0.9),
            ],
            status: .completed
        )
        let edited = Transcription(
            fileName: "edited.m4a",
            rawTranscript: "Original",
            cleanTranscript: "Edited transcript",
            wordTimestamps: [
                WordTimestamp(word: "Original", startMs: 0, endMs: 500, confidence: 0.9)
            ],
            status: .completed,
            isTranscriptEdited: true
        )

        _ = try await TranscriptResultActions.exportTranscriptsToDirectory(
            transcriptions: [timed, edited],
            format: .md,
            options: TranscriptExportOptions(
                includeTimestamps: true,
                includeSpeakerLabels: true,
                includeMetadata: false
            ),
            directory: tempDir
        )

        let timedContent = try String(contentsOf: tempDir.appendingPathComponent("timed.md"), encoding: .utf8)
        let editedContent = try String(contentsOf: tempDir.appendingPathComponent("edited.md"), encoding: .utf8)

        XCTAssertTrue(timedContent.contains("**[0:00]** Hello world."))
        XCTAssertEqual(editedContent.trimmingCharacters(in: .whitespacesAndNewlines), "Edited transcript")
        XCTAssertFalse(editedContent.contains("**[0:00]**"))
    }
}
