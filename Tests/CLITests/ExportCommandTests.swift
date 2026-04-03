import XCTest
@testable import CLI
@testable import MacParakeetCore

final class ExportCommandTests: XCTestCase {

    func testExportFormatFileExtensions() {
        XCTAssertEqual(ExportFormat.txt.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
        XCTAssertEqual(ExportFormat.srt.fileExtension, "srt")
        XCTAssertEqual(ExportFormat.vtt.fileExtension, "vtt")
        XCTAssertEqual(ExportFormat.json.fileExtension, "json")
    }

    func testExportFormatRawValues() {
        // Ensure ArgumentParser can parse these strings
        XCTAssertNotNil(ExportFormat(rawValue: "txt"))
        XCTAssertNotNil(ExportFormat(rawValue: "markdown"))
        XCTAssertNotNil(ExportFormat(rawValue: "srt"))
        XCTAssertNotNil(ExportFormat(rawValue: "vtt"))
        XCTAssertNotNil(ExportFormat(rawValue: "json"))
        XCTAssertNil(ExportFormat(rawValue: "pdf"))
        XCTAssertNil(ExportFormat(rawValue: "docx"))
    }

    @MainActor func testExportToTxtWritesFile() throws {
        let t = Transcription(
            fileName: "export-test.mp3",
            rawTranscript: "This is the transcript content",
            status: .completed
        )

        let exportService = ExportService()
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("export-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try exportService.exportToTxt(transcription: t, url: tmpURL)

        let content = try String(contentsOf: tmpURL, encoding: .utf8)
        XCTAssertTrue(content.contains("This is the transcript content"))
        XCTAssertTrue(content.contains("export-test.mp3"))
    }

    @MainActor func testExportToMarkdownWritesFile() throws {
        let t = Transcription(
            fileName: "markdown-test.mp3",
            durationMs: 120_000,
            rawTranscript: "Markdown transcript",
            status: .completed
        )

        let exportService = ExportService()
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("md-test-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try exportService.exportToMarkdown(transcription: t, url: tmpURL)

        let content = try String(contentsOf: tmpURL, encoding: .utf8)
        XCTAssertTrue(content.contains("# markdown-test.mp3"))
        XCTAssertTrue(content.contains("Markdown transcript"))
    }

    @MainActor func testExportToSRTWithTimestamps() throws {
        let t = Transcription(
            fileName: "srt-test.mp3",
            rawTranscript: "Hello world",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
                WordTimestamp(word: "world", startMs: 600, endMs: 1100, confidence: 0.95),
            ],
            status: .completed
        )

        let exportService = ExportService()
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("srt-test-\(UUID().uuidString).srt")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try exportService.exportToSRT(transcription: t, url: tmpURL)

        let content = try String(contentsOf: tmpURL, encoding: .utf8)
        // Verify SRT timestamp format (HH:MM:SS,mmm) — not just "-->" which the fallback also emits
        XCTAssertTrue(content.contains("00:00:00,000 --> 00:00:01,100"), "Expected SRT timestamps from word-level data")
        XCTAssertTrue(content.contains("Hello world"))
        // Verify cue numbering (SRT-specific, not in VTT)
        XCTAssertTrue(content.hasPrefix("1\n"))
    }

    @MainActor func testExportToVTTWritesFile() throws {
        let t = Transcription(
            fileName: "vtt-test.mp3",
            rawTranscript: "Good morning",
            wordTimestamps: [
                WordTimestamp(word: "Good", startMs: 0, endMs: 400, confidence: 0.98),
                WordTimestamp(word: "morning", startMs: 500, endMs: 1000, confidence: 0.97),
            ],
            status: .completed
        )

        let exportService = ExportService()
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vtt-test-\(UUID().uuidString).vtt")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try exportService.exportToVTT(transcription: t, url: tmpURL)

        let content = try String(contentsOf: tmpURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("WEBVTT"), "VTT must start with WEBVTT header")
        // VTT uses period not comma: HH:MM:SS.mmm
        XCTAssertTrue(content.contains("00:00:00.000 --> 00:00:01.000"), "Expected VTT timestamps")
        XCTAssertTrue(content.contains("Good morning"))
    }

    @MainActor func testExportToJSONWritesFile() throws {
        let t = Transcription(
            fileName: "json-test.mp3",
            rawTranscript: "JSON content",
            status: .completed
        )

        let exportService = ExportService()
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("json-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        try exportService.exportToJSON(transcription: t, url: tmpURL)

        let data = try Data(contentsOf: tmpURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Transcription.self, from: data)
        XCTAssertEqual(decoded.fileName, "json-test.mp3")
        XCTAssertEqual(decoded.rawTranscript, "JSON content")
    }
}
