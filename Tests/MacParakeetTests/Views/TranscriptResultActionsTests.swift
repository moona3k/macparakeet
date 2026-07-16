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
        XCTAssertTrue(result.isCompleteSuccess)
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

    func testBulkExportUsesEffectiveDisplayTitleForFilenames() async throws {
        let transcription = Transcription(
            fileName: "IMG_1942.m4a",
            rawTranscript: "Visible title should drive the suggested export file name.",
            status: .completed,
            titleOverride: "Q3 Vendor Notes"
        )

        let result = try await TranscriptResultActions.exportTranscriptsToDirectory(
            transcriptions: [transcription],
            format: .txt,
            options: TranscriptExportOptions(
                includeTimestamps: false,
                includeSpeakerLabels: false,
                includeMetadata: false
            ),
            directory: tempDir
        )

        XCTAssertEqual(result.exportedURLs.map(\.lastPathComponent), ["Q3 Vendor Notes.txt"])
    }

    func testBulkExportUsesOriginalFilenameForUnrenamedLocalFile() async throws {
        let transcription = Transcription(
            fileName: "my_video.mp4",
            rawTranscript: "Welcome to the first few spoken words.",
            status: .completed,
            sourceType: .file,
            derivedTitle: "Welcome to the first few spoken words"
        )

        let result = try await TranscriptResultActions.exportTranscriptsToDirectory(
            transcriptions: [transcription],
            format: .txt,
            options: TranscriptExportOptions(
                includeTimestamps: false,
                includeSpeakerLabels: false,
                includeMetadata: false
            ),
            directory: tempDir
        )

        XCTAssertEqual(result.exportedURLs.map(\.lastPathComponent), ["my_video.txt"])
    }

    func testBulkExportCompleteSuccessRequiresEveryRequestedFile() {
        let result = BulkTranscriptExportResult(
            directory: tempDir,
            format: .txt,
            requestedCount: 2,
            exportedURLs: [tempDir.appendingPathComponent("one.txt")],
            failedCount: 0,
            firstErrorDescription: nil
        )

        XCTAssertFalse(result.isCompleteSuccess)
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

    func testBulkExportCancellationRemovesPartialFilesAndCreatedDirectory() async throws {
        let outputDir = tempDir.appendingPathComponent("cancelled-export", isDirectory: true)
        let first = Transcription(
            fileName: "first.m4a",
            rawTranscript: "First export should be removed",
            status: .completed
        )
        let second = Transcription(
            fileName: "second.m4a",
            rawTranscript: "Second export should never start",
            status: .completed
        )
        let cancellationProbe = MidExportCancellationProbe()

        let task = Task.detached {
            return try await TranscriptResultActions.exportTranscriptsToDirectory(
                transcriptions: [first, second],
                format: .txt,
                directory: outputDir,
                onFileExported: { url in
                    await cancellationProbe.recordAndCancel(url)
                }
            )
        }
        await cancellationProbe.setTask(task)

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate out of bulk export")
        } catch is CancellationError {
            let exportedURLs = await cancellationProbe.exportedURLs
            XCTAssertEqual(exportedURLs.map(\.lastPathComponent), ["first.txt"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: outputDir.path))
        }
    }

    func testBulkExportCancellationDoesNotDeleteReplacementFile() async throws {
        let outputDir = tempDir.appendingPathComponent("replacement-export", isDirectory: true)
        let first = Transcription(
            fileName: "first.m4a",
            rawTranscript: "First export will be replaced",
            status: .completed
        )
        let second = Transcription(
            fileName: "second.m4a",
            rawTranscript: "Second export should never start",
            status: .completed
        )
        let replacementText = "Replacement content from another writer"
        let cancellationProbe = MidExportCancellationProbe()

        let task = Task.detached {
            return try await TranscriptResultActions.exportTranscriptsToDirectory(
                transcriptions: [first, second],
                format: .txt,
                directory: outputDir,
                onFileExported: { url in
                    try? replacementText.write(to: url, atomically: true, encoding: .utf8)
                    await cancellationProbe.recordAndCancel(url)
                }
            )
        }
        await cancellationProbe.setTask(task)

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to propagate out of bulk export")
        } catch is CancellationError {
            let exportedURLs = await cancellationProbe.exportedURLs
            XCTAssertEqual(exportedURLs.map(\.lastPathComponent), ["first.txt"])
            let replacementURL = try XCTUnwrap(exportedURLs.first)
            XCTAssertEqual(
                try String(contentsOf: replacementURL, encoding: .utf8),
                replacementText
            )
        }
    }

    func testBulkExportCancellationAfterFinalFileKeepsCompletedExport() async throws {
        let outputDir = tempDir.appendingPathComponent("completed-export", isDirectory: true)
        let transcription = Transcription(
            fileName: "final.m4a",
            rawTranscript: "Final export should remain",
            status: .completed
        )
        let cancellationProbe = MidExportCancellationProbe()

        let task = Task.detached {
            return try await TranscriptResultActions.exportTranscriptsToDirectory(
                transcriptions: [transcription],
                format: .txt,
                directory: outputDir,
                onFileExported: { url in
                    await cancellationProbe.recordAndCancel(url)
                }
            )
        }
        await cancellationProbe.setTask(task)

        let result = try await task.value
        let exportedURLs = await cancellationProbe.exportedURLs
        XCTAssertEqual(result.exportedCount, 1)
        XCTAssertEqual(result.failedCount, 0)
        XCTAssertEqual(exportedURLs.map(\.lastPathComponent), ["final.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDir.appendingPathComponent("final.txt").path))
    }
}

private actor MidExportCancellationProbe {
    private var task: Task<BulkTranscriptExportResult, Error>?
    private var taskWaiters: [CheckedContinuation<Task<BulkTranscriptExportResult, Error>, Never>] = []
    private var recordedURLs: [URL] = []

    var exportedURLs: [URL] {
        recordedURLs
    }

    func setTask(_ task: Task<BulkTranscriptExportResult, Error>) {
        self.task = task
        let waiters = taskWaiters
        taskWaiters.removeAll()
        for waiter in waiters {
            waiter.resume(returning: task)
        }
    }

    func recordAndCancel(_ url: URL) async {
        recordedURLs.append(url)
        let task = await taskHandle()
        task.cancel()
    }

    private func taskHandle() async -> Task<BulkTranscriptExportResult, Error> {
        if let task {
            return task
        }
        return await withCheckedContinuation { continuation in
            taskWaiters.append(continuation)
        }
    }
}
