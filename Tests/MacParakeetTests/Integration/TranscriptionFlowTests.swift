import XCTest
@testable import MacParakeetCore

final class TranscriptionFlowTests: XCTestCase {
    var transcriptionService: TranscriptionService!
    var mockAudio: MockAudioProcessor!
    var mockSTT: MockSTTClient!
    var transcriptionRepo: TranscriptionRepository!
    var exportService: ExportService!

    override func setUp() async throws {
        let dbManager = try DatabaseManager()
        mockAudio = MockAudioProcessor()
        mockSTT = MockSTTClient()
        transcriptionRepo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        exportService = ExportService()

        transcriptionService = TranscriptionService(
            audioProcessor: mockAudio,
            sttClient: mockSTT,
            transcriptionRepo: transcriptionRepo
        )
    }

    /// End-to-end: file → convert → STT → save → export
    func testFullTranscriptionFlow() async throws {
        let sttResult = STTResult(
            text: "The advancement in cloud native technology has been remarkable over the past year.",
            words: [
                TimestampedWord(word: "The", startMs: 0, endMs: 150, confidence: 0.99),
                TimestampedWord(word: "advancement", startMs: 160, endMs: 720, confidence: 0.97),
                TimestampedWord(word: "in", startMs: 730, endMs: 800, confidence: 0.99),
                TimestampedWord(word: "cloud", startMs: 810, endMs: 1100, confidence: 0.98),
                TimestampedWord(word: "native", startMs: 1110, endMs: 1400, confidence: 0.96),
                TimestampedWord(word: "technology", startMs: 1410, endMs: 2000, confidence: 0.97),
                TimestampedWord(word: "has", startMs: 2010, endMs: 2200, confidence: 0.99),
                TimestampedWord(word: "been", startMs: 2210, endMs: 2400, confidence: 0.99),
                TimestampedWord(word: "remarkable", startMs: 2410, endMs: 3000, confidence: 0.95),
                TimestampedWord(word: "over", startMs: 3010, endMs: 3200, confidence: 0.98),
                TimestampedWord(word: "the", startMs: 3210, endMs: 3300, confidence: 0.99),
                TimestampedWord(word: "past", startMs: 3310, endMs: 3500, confidence: 0.98),
                TimestampedWord(word: "year", startMs: 3510, endMs: 3800, confidence: 0.97),
            ]
        )
        await mockSTT.configure(result: sttResult)

        // 1. Transcribe file
        let fileURL = URL(fileURLWithPath: "/tmp/interview.mp3")
        let transcription = try await transcriptionService.transcribe(fileURL: fileURL)

        // 2. Verify result
        XCTAssertEqual(transcription.fileName, "interview.mp3")
        XCTAssertEqual(transcription.status, .completed)
        XCTAssertTrue(transcription.rawTranscript?.contains("cloud native") ?? false)
        XCTAssertEqual(transcription.wordTimestamps?.count, 13)
        XCTAssertEqual(transcription.durationMs, 3800)

        // 3. Verify audio was converted
        let convertCount = await mockAudio.convertCallCount
        XCTAssertEqual(convertCount, 1)

        // 4. Verify saved to DB
        let saved = try transcriptionRepo.fetch(id: transcription.id)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.status, .completed)

        // 5. Test export
        let tempExportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).txt")
        try exportService.exportToTxt(transcription: transcription, url: tempExportURL)

        let exportedContent = try String(contentsOf: tempExportURL, encoding: .utf8)
        XCTAssertTrue(exportedContent.contains("interview.mp3"))
        XCTAssertTrue(exportedContent.contains("cloud native"))

        try? FileManager.default.removeItem(at: tempExportURL)

        // 6. Test clipboard format
        let clipboardText = exportService.formatForClipboard(transcription: transcription)
        XCTAssertTrue(clipboardText.contains("advancement"))
    }

    /// Test error handling during transcription
    func testTranscriptionFlowWithError() async throws {
        await mockSTT.configure(error: STTError.outOfMemory)

        let fileURL = URL(fileURLWithPath: "/tmp/large_file.mp3")

        do {
            _ = try await transcriptionService.transcribe(fileURL: fileURL)
            XCTFail("Should have thrown")
        } catch let error as STTError {
            if case .outOfMemory = error {} else {
                XCTFail("Expected outOfMemory error, got \(error)")
            }
        }

        // Verify error state saved to DB
        let all = try transcriptionRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].status, .error)
        XCTAssertNotNil(all[0].errorMessage)
    }

    /// Test multiple transcriptions
    func testMultipleTranscriptions() async throws {
        let result1 = STTResult(text: "First file content")
        let result2 = STTResult(text: "Second file content")

        // Transcribe first file
        await mockSTT.configure(result: result1)
        let t1 = try await transcriptionService.transcribe(
            fileURL: URL(fileURLWithPath: "/tmp/file1.mp3")
        )

        // Transcribe second file
        await mockSTT.configure(result: result2)
        let t2 = try await transcriptionService.transcribe(
            fileURL: URL(fileURLWithPath: "/tmp/file2.wav")
        )

        XCTAssertEqual(t1.rawTranscript, "First file content")
        XCTAssertEqual(t2.rawTranscript, "Second file content")

        let all = try transcriptionRepo.fetchAll(limit: nil)
        XCTAssertEqual(all.count, 2)
    }
}
