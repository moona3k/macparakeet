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

    func testBulkExportPropagatesCancellationAndCleansEmptyCreatedDirectory() async throws {
        let outputDir = tempDir.appendingPathComponent("cancelled-export", isDirectory: true)
        let transcription = Transcription(
            fileName: "cancel-me.m4a",
            rawTranscript: "Should not export",
            status: .completed
        )
        let gate = CancellationStartGate()

        let task = Task.detached {
            await gate.wait()
            return try await TranscriptResultActions.exportTranscriptsToDirectory(
                transcriptions: [transcription],
                format: .txt,
                directory: outputDir
            )
        }
        task.cancel()
        await gate.open()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate out of bulk export")
        } catch is CancellationError {
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputDir.path))
        }
    }
}

private actor CancellationStartGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
