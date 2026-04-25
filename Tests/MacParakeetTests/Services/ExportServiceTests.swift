import CoreGraphics
import XCTest
@testable import MacParakeetCore

@MainActor
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

    // MARK: - Markdown Export

    func testFormatMarkdownWithTimestamps() {
        let transcription = Transcription(
            fileName: "interview.mp3",
            durationMs: 5000,
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
                WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
                WordTimestamp(word: "How", startMs: 2000, endMs: 2300, confidence: 0.97),
                WordTimestamp(word: "are", startMs: 2400, endMs: 2600, confidence: 0.96),
                WordTimestamp(word: "you?", startMs: 2700, endMs: 3000, confidence: 0.95),
            ],
            language: "en",
            status: .completed
        )

        let md = exportService.formatMarkdown(transcription: transcription)
        XCTAssertTrue(md.hasPrefix("# interview.mp3"))
        XCTAssertTrue(md.contains("**Duration:** 0:05"))
        XCTAssertTrue(md.contains("**Language:** en"))
        XCTAssertTrue(md.contains("---"))
        XCTAssertTrue(md.contains("**[0:00]** Hello world."))
        XCTAssertTrue(md.contains("**[0:02]** How are you?"))
    }

    func testFormatMarkdownWithoutTimestamps() {
        let transcription = Transcription(
            fileName: "note.mp3",
            durationMs: 3000,
            rawTranscript: "Just a plain transcript.",
            status: .completed
        )

        let md = exportService.formatMarkdown(transcription: transcription)
        XCTAssertTrue(md.contains("# note.mp3"))
        XCTAssertTrue(md.contains("Just a plain transcript."))
        // No timestamp markers
        XCTAssertFalse(md.contains("**["))
    }

    func testFormatMarkdownWithYouTubeSource() {
        let transcription = Transcription(
            fileName: "Video Title",
            durationMs: 60000,
            rawTranscript: "Some content",
            status: .completed,
            sourceURL: "https://youtube.com/watch?v=abc123"
        )

        let md = exportService.formatMarkdown(transcription: transcription)
        XCTAssertTrue(md.contains("**Source:** [https://youtube.com/watch?v=abc123](https://youtube.com/watch?v=abc123)"))
    }

    func testExportToMarkdown() throws {
        let transcription = Transcription(
            fileName: "test.mp3",
            rawTranscript: "Hello world",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).md")

        try exportService.exportToMarkdown(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("# test.mp3"))
        XCTAssertTrue(content.contains("Hello world"))

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testFormatAITextPrefersEditedCleanTranscriptAndRemovesMetadata() {
        let transcription = Transcription(
            fileName: "video.mp4",
            durationMs: 5000,
            rawTranscript: "Original transcript.",
            cleanTranscript: " Edited transcript.\nwith wrapped line. ",
            wordTimestamps: [
                WordTimestamp(word: "Original", startMs: 0, endMs: 500, confidence: 0.99),
                WordTimestamp(word: "transcript.", startMs: 600, endMs: 1000, confidence: 0.98),
            ],
            status: .completed
        )

        let text = exportService.formatAIText(transcription: transcription)

        XCTAssertEqual(text, "Edited transcript. with wrapped line.")
        XCTAssertFalse(text.contains("video.mp4"))
        XCTAssertFalse(text.contains("[0:"))
    }

    func testFormatAITextUsesSpeakerLabelsWithoutTimestamps() {
        let transcription = Transcription(
            fileName: "meeting.m4a",
            wordTimestamps: [
                WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
                WordTimestamp(word: "Hi.", startMs: 600, endMs: 1000, confidence: 0.98, speakerId: "S2"),
            ],
            speakers: [
                SpeakerInfo(id: "S1", label: "Alice"),
                SpeakerInfo(id: "S2", label: "Bob"),
            ],
            status: .completed
        )

        let text = exportService.formatAIText(transcription: transcription)

        XCTAssertTrue(text.contains("Alice:\nHello."))
        XCTAssertTrue(text.contains("Bob:\nHi."))
        XCTAssertFalse(text.contains("[0:"))
    }

    func testExportToAIText() throws {
        let transcription = Transcription(
            fileName: "test.mp3",
            rawTranscript: "Hello world",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).md")

        try exportService.exportToAIText(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertEqual(content, "Hello world")

        try? FileManager.default.removeItem(at: tempURL)
    }

    // MARK: - New Export Formats

    func testExportToJSON() throws {
        let transcription = Transcription(
            fileName: "data.mp3",
            durationMs: 10000,
            rawTranscript: "JSON export test",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).json")

        try exportService.exportToJSON(transcription: transcription, url: tempURL)

        let data = try Data(contentsOf: tempURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(Transcription.self, from: data)
        
        XCTAssertEqual(decoded.fileName, "data.mp3")
        XCTAssertEqual(decoded.rawTranscript, "JSON export test")

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToPDF() throws {
        let transcription = Transcription(
            fileName: "document.mp3",
            rawTranscript: "PDF export test content",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).pdf")

        try exportService.exportToPDF(transcription: transcription, url: tempURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        let data = try Data(contentsOf: tempURL)
        XCTAssertGreaterThan(data.count, 0)
        // Verify it's a valid PDF (starts with %PDF magic bytes)
        let header = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(header, "%PDF-")

        let stream = try firstPageContentStream(from: tempURL)
        // The PDF must contain a Y-flip (scale y=-1) for correct pagination.
        // NSGraphicsContext(flipped: true) ensures glyphs render upright despite the flip.
        XCTAssertNotNil(
            stream.range(of: #"(?m)\b1 0 0 -1 72 720 cm\b"#, options: .regularExpression),
            "Expected PDF page transform to translate AND flip Y for correct pagination"
        )

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToPDFWithTimestamps() throws {
        let transcription = Transcription(
            fileName: "timestamped.mp3",
            rawTranscript: "Hello world this is a test",
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
                WordTimestamp(word: "world", startMs: 500, endMs: 1000, confidence: 0.98),
                WordTimestamp(word: "this", startMs: 1000, endMs: 1500, confidence: 0.97),
                WordTimestamp(word: "is", startMs: 1500, endMs: 1800, confidence: 0.99),
                WordTimestamp(word: "a", startMs: 1800, endMs: 2000, confidence: 0.99),
                WordTimestamp(word: "test.", startMs: 2000, endMs: 2500, confidence: 0.95),
            ],
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_ts_\(UUID().uuidString).pdf")

        try exportService.exportToPDF(transcription: transcription, url: tempURL)

        let data = try Data(contentsOf: tempURL)
        let header = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(header, "%PDF-")

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToPDFWithSpeakers() throws {
        let transcription = Transcription(
            fileName: "interview.mp3",
            rawTranscript: "Hello. Hi there.",
            wordTimestamps: [
                WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "spk_0"),
                WordTimestamp(word: "Hi", startMs: 1000, endMs: 1300, confidence: 0.98, speakerId: "spk_1"),
                WordTimestamp(word: "there.", startMs: 1300, endMs: 1800, confidence: 0.97, speakerId: "spk_1"),
            ],
            speakers: [
                SpeakerInfo(id: "spk_0", label: "Speaker 1"),
                SpeakerInfo(id: "spk_1", label: "Speaker 2"),
            ],
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_spk_\(UUID().uuidString).pdf")

        try exportService.exportToPDF(transcription: transcription, url: tempURL)

        let data = try Data(contentsOf: tempURL)
        let header = String(data: data.prefix(5), encoding: .ascii)
        XCTAssertEqual(header, "%PDF-")

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testPDFPageTextTransformFlipsYForPagination() {
        let transform = exportService.pdfPageTextTransform(pageHeight: 792, margin: 72)

        XCTAssertEqual(transform.a, 1, accuracy: 0.001)
        XCTAssertEqual(transform.b, 0, accuracy: 0.001)
        XCTAssertEqual(transform.c, 0, accuracy: 0.001)
        XCTAssertEqual(transform.d, -1, accuracy: 0.001)
        XCTAssertEqual(transform.tx, 72, accuracy: 0.001)
        XCTAssertEqual(transform.ty, 720, accuracy: 0.001)
    }

    func testExportToDocx() throws {
        let transcription = Transcription(
            fileName: "word.mp3",
            rawTranscript: "DOCX export test content",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).docx")

        try exportService.exportToDocx(transcription: transcription, url: tempURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: tempURL.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: tempURL.path)
        let fileSize = attributes[.size] as? Int64 ?? 0
        XCTAssertGreaterThan(fileSize, 0)

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testReadableTimestampFormatting() {
        XCTAssertEqual(exportService.formatReadableTimestamp(ms: 0), "0:00")
        XCTAssertEqual(exportService.formatReadableTimestamp(ms: 5000), "0:05")
        XCTAssertEqual(exportService.formatReadableTimestamp(ms: 65000), "1:05")
        XCTAssertEqual(exportService.formatReadableTimestamp(ms: 3661000), "1:01:01")
    }

    private func firstPageContentStream(from url: URL) throws -> String {
        guard let document = CGPDFDocument(url as CFURL),
              let page = document.page(at: 1),
              let dictionary = page.dictionary else {
            throw XCTSkip("Unable to open exported PDF for content-stream inspection")
        }

        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, "Contents", &stream),
              let stream else {
            throw XCTSkip("Exported PDF did not contain a single page content stream")
        }

        var format = CGPDFDataFormat.raw
        guard let streamData = CGPDFStreamCopyData(stream, &format) as Data? else {
            throw XCTSkip("Unable to decode page content stream")
        }

        guard let text = String(data: streamData, encoding: .isoLatin1) else {
            throw XCTSkip("Unable to decode page content stream as Latin-1")
        }

        return text
    }

    // MARK: - Fallback Tests

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

    // MARK: - Speaker Labels

    func testFormatSRTWithSpeakers() {
        let words = [
            WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
            WordTimestamp(word: "Hi.", startMs: 600, endMs: 1000, confidence: 0.98, speakerId: "S1"),
            WordTimestamp(word: "Goodbye.", startMs: 2000, endMs: 2500, confidence: 0.97, speakerId: "S2"),
            WordTimestamp(word: "Bye.", startMs: 2600, endMs: 3000, confidence: 0.96, speakerId: "S2"),
        ]
        let speakers = [
            SpeakerInfo(id: "S1", label: "Alice"),
            SpeakerInfo(id: "S2", label: "Bob"),
        ]

        let srt = exportService.formatSRT(words: words, speakers: speakers)
        XCTAssertTrue(srt.contains("Alice: Hello. Hi."))
        XCTAssertTrue(srt.contains("Bob: Goodbye. Bye."))
    }

    func testFormatVTTWithSpeakers() {
        let words = [
            WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
            WordTimestamp(word: "Hi.", startMs: 600, endMs: 1000, confidence: 0.98, speakerId: "S1"),
            WordTimestamp(word: "Goodbye.", startMs: 2000, endMs: 2500, confidence: 0.97, speakerId: "S2"),
            WordTimestamp(word: "Bye.", startMs: 2600, endMs: 3000, confidence: 0.96, speakerId: "S2"),
        ]
        let speakers = [
            SpeakerInfo(id: "S1", label: "Alice"),
            SpeakerInfo(id: "S2", label: "Bob"),
        ]

        let vtt = exportService.formatVTT(words: words, speakers: speakers)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n"))
        XCTAssertTrue(vtt.contains("<v Alice>Hello. Hi.</v>"))
        XCTAssertTrue(vtt.contains("<v Bob>Goodbye. Bye.</v>"))
    }

    func testCueSplitsOnSpeakerChange() {
        let words = [
            WordTimestamp(word: "Hi", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
            WordTimestamp(word: "there", startMs: 500, endMs: 1000, confidence: 0.98, speakerId: "S2"),
        ]

        let cues = exportService.buildSubtitleCues(from: words)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].speakerId, "S1")
        XCTAssertEqual(cues[0].text, "Hi")
        XCTAssertEqual(cues[1].speakerId, "S2")
        XCTAssertEqual(cues[1].text, "there")
    }

    func testFormatMarkdownWithSpeakers() {
        let transcription = Transcription(
            fileName: "interview.mp3",
            durationMs: 5000,
            wordTimestamps: [
                WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
                WordTimestamp(word: "Hi.", startMs: 600, endMs: 1000, confidence: 0.98, speakerId: "S1"),
                WordTimestamp(word: "Goodbye.", startMs: 2000, endMs: 2500, confidence: 0.97, speakerId: "S2"),
                WordTimestamp(word: "Bye.", startMs: 2600, endMs: 3000, confidence: 0.96, speakerId: "S2"),
            ],
            language: "en",
            speakers: [
                SpeakerInfo(id: "S1", label: "Alice"),
                SpeakerInfo(id: "S2", label: "Bob"),
            ],
            status: .completed
        )

        let md = exportService.formatMarkdown(transcription: transcription)
        XCTAssertTrue(md.contains("**Alice**"))
        XCTAssertTrue(md.contains("**Bob**"))
    }

    func testSRTWithoutSpeakersHasNoLabels() {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
        ]

        let srt = exportService.formatSRT(words: words)
        // Cue text should not have "Speaker:" prefix — just the text directly
        XCTAssertTrue(srt.contains("\nHello world.\n"))
    }

    func testExportToTxtWithSpeakers() throws {
        let transcription = Transcription(
            fileName: "interview.mp3",
            durationMs: 5000,
            wordTimestamps: [
                WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
                WordTimestamp(word: "Hi.", startMs: 600, endMs: 1000, confidence: 0.98, speakerId: "S1"),
                WordTimestamp(word: "Goodbye.", startMs: 2000, endMs: 2500, confidence: 0.97, speakerId: "S2"),
            ],
            speakers: [
                SpeakerInfo(id: "S1", label: "Alice"),
                SpeakerInfo(id: "S2", label: "Bob"),
            ],
            status: .completed
        )

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-speakers.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try exportService.exportToTxt(transcription: transcription, url: url)
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.contains("Alice:"))
        XCTAssertTrue(content.contains("Bob:"))
        XCTAssertTrue(content.contains("Hello. Hi."))
        XCTAssertTrue(content.contains("Goodbye."))
    }

    func testExportToTxtWithTimestampsNoSpeakers() throws {
        let transcription = Transcription(
            fileName: "mono.mp3",
            durationMs: 2000,
            wordTimestamps: [
                WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
                WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
            ],
            status: .completed
        )

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test-no-speakers.txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try exportService.exportToTxt(transcription: transcription, url: url)
        let content = try String(contentsOf: url, encoding: .utf8)

        // Should still use word timestamps path (no speaker labels)
        XCTAssertTrue(content.contains("Hello world."))
        XCTAssertFalse(content.contains("Speaker"))
    }
}
