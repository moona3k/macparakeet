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

    // MARK: - SRT Timestamp Formatting

    func testSRTTimestampFormatting() {
        XCTAssertEqual(exportService.srtTimestamp(ms: 0), "00:00:00,000")
        XCTAssertEqual(exportService.srtTimestamp(ms: 1500), "00:00:01,500")
        XCTAssertEqual(exportService.srtTimestamp(ms: 65000), "00:01:05,000")
        XCTAssertEqual(exportService.srtTimestamp(ms: 3661500), "01:01:01,500")
    }

    func testVTTTimestampFormatting() {
        XCTAssertEqual(exportService.vttTimestamp(ms: 0), "00:00:00.000")
        XCTAssertEqual(exportService.vttTimestamp(ms: 1500), "00:00:01.500")
        XCTAssertEqual(exportService.vttTimestamp(ms: 65000), "00:01:05.000")
        XCTAssertEqual(exportService.vttTimestamp(ms: 3661500), "01:01:01.500")
    }

    // MARK: - Subtitle Cue Building

    func testBuildSubtitleCuesBasic() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
        ]

        let cues = exportService.buildSubtitleCues(from: words)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hello world.")
        XCTAssertEqual(cues[0].startMs, 0)
        XCTAssertEqual(cues[0].endMs, 1000)
    }

    func testBuildSubtitleCuesBreaksOnPunctuation() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
            WordTimestamp(word: "How", startMs: 1200, endMs: 1500, confidence: 0.97),
            WordTimestamp(word: "are", startMs: 1600, endMs: 1800, confidence: 0.96),
            WordTimestamp(word: "you?", startMs: 1900, endMs: 2200, confidence: 0.95),
        ]

        let cues = exportService.buildSubtitleCues(from: words)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello world.")
        XCTAssertEqual(cues[1].text, "How are you?")
    }

    func testBuildSubtitleCuesBreaksOnLongGap() {
        let words = [
            WordTimestamp(word: "First", startMs: 0, endMs: 500, confidence: 0.99),
            WordTimestamp(word: "part", startMs: 600, endMs: 1000, confidence: 0.98),
            // 1200ms gap — exceeds 800ms threshold
            WordTimestamp(word: "Second", startMs: 2200, endMs: 2700, confidence: 0.97),
            WordTimestamp(word: "part.", startMs: 2800, endMs: 3200, confidence: 0.96),
        ]

        let cues = exportService.buildSubtitleCues(from: words)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "First part")
        XCTAssertEqual(cues[1].text, "Second part.")
    }

    func testBuildSubtitleCuesBreaksOnWordCount() {
        // 14 words with no punctuation — should break at 12
        var words: [WordTimestamp] = []
        for i in 0..<14 {
            words.append(WordTimestamp(
                word: "word\(i)",
                startMs: i * 300,
                endMs: i * 300 + 250,
                confidence: 0.95
            ))
        }

        let cues = exportService.buildSubtitleCues(from: words)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text.components(separatedBy: " ").count, 12)
        XCTAssertEqual(cues[1].text.components(separatedBy: " ").count, 2)
    }

    func testBuildSubtitleCuesEmpty() {
        let cues = exportService.buildSubtitleCues(from: [])
        XCTAssertTrue(cues.isEmpty)
    }

    // MARK: - SRT Format Output

    func testFormatSRT() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
            WordTimestamp(word: "Goodbye", startMs: 2000, endMs: 2500, confidence: 0.97),
            WordTimestamp(word: "world.", startMs: 2600, endMs: 3000, confidence: 0.96),
        ]

        let srt = exportService.formatSRT(words: words)
        XCTAssertTrue(srt.contains("1\n00:00:00,000 --> 00:00:01,000\nHello world."))
        XCTAssertTrue(srt.contains("2\n00:00:02,000 --> 00:00:03,000\nGoodbye world."))
    }

    func testFormatVTT() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
            WordTimestamp(word: "Goodbye", startMs: 2000, endMs: 2500, confidence: 0.97),
            WordTimestamp(word: "world.", startMs: 2600, endMs: 3000, confidence: 0.96),
        ]

        let vtt = exportService.formatVTT(words: words)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n"))
        XCTAssertTrue(vtt.contains("00:00:00.000 --> 00:00:01.000\nHello world."))
        XCTAssertTrue(vtt.contains("00:00:02.000 --> 00:00:03.000\nGoodbye world."))
    }

    // MARK: - File Export

    func testExportToSRT() throws {
        let transcription = Transcription(
            fileName: "video.mp4",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
                WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
            ],
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).srt")

        try exportService.exportToSRT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("1\n00:00:00,000 --> 00:00:01,000\nHello world."))

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToVTT() throws {
        let transcription = Transcription(
            fileName: "video.mp4",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
                WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
            ],
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).vtt")

        try exportService.exportToVTT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("WEBVTT\n"))
        XCTAssertTrue(content.contains("00:00:00.000 --> 00:00:01.000\nHello world."))

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToSRTWithoutTimestampsFallsBack() throws {
        let transcription = Transcription(
            fileName: "audio.mp3",
            durationMs: 5000,
            rawTranscript: "Hello world",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).srt")

        try exportService.exportToSRT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("1\n00:00:00,000 --> 00:00:05,000\nHello world"))

        try? FileManager.default.removeItem(at: tempURL)
    }
}
