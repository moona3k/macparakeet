import XCTest
@testable import MacParakeetCore

final class ExportServiceTests: XCTestCase {
    var exportService: ExportService!

    override func setUp() {
        exportService = ExportService()
    }

    func testFormatForClipboard() {
        let transcription = Transcription(
            fileName: "test.mp3",
            rawTranscript: "Hello world",
            status: .completed
        )

        let text = exportService.formatForClipboard(transcription: transcription)
        XCTAssertEqual(text, "Hello world")
    }

    func testFormatForClipboardFallsToClean() {
        let transcription = Transcription(
            fileName: "test.mp3",
            cleanTranscript: "Clean text",
            status: .completed
        )

        let text = exportService.formatForClipboard(transcription: transcription)
        XCTAssertEqual(text, "Clean text")
    }

    func testFormatForClipboardEmpty() {
        let transcription = Transcription(
            fileName: "test.mp3",
            status: .processing
        )

        let text = exportService.formatForClipboard(transcription: transcription)
        XCTAssertEqual(text, "")
    }

    func testExportToTxt() throws {
        let transcription = Transcription(
            fileName: "interview.mp3",
            durationMs: 65000,
            rawTranscript: "This is the full transcript of the interview.",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).txt")

        try exportService.exportToTxt(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("interview.mp3"))
        XCTAssertTrue(content.contains("Duration: 1:05"))
        XCTAssertTrue(content.contains("This is the full transcript"))

        // Cleanup
        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToTxtLongDuration() throws {
        let transcription = Transcription(
            fileName: "lecture.mp3",
            durationMs: 3661000, // 1h 1m 1s
            rawTranscript: "Long lecture content",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).txt")

        try exportService.exportToTxt(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Duration: 1:01:01"))

        try? FileManager.default.removeItem(at: tempURL)
    }
}
