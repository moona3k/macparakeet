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

    func testFormatPlainTextDefaultIncludesMetadataTimestampsAndSpeakers() {
        let transcription = makeExportOptionsTranscription()
        let options = TranscriptExportOptions(includeSpeakerLabels: true)

        let text = exportService.formatPlainText(transcription: transcription, options: options)

        XCTAssertTrue(text.contains("interview.mp3"))
        XCTAssertTrue(text.contains("Duration: 0:05"))
        XCTAssertTrue(text.contains("Alice:"))
        XCTAssertTrue(text.contains("Bob:"))
        XCTAssertTrue(text.contains("[0:00] Hello."))
        XCTAssertTrue(text.contains("[0:02] Goodbye."))
    }

    func testFormatPlainTextDefaultUsesEditedTranscriptWhenTimestampsExist() {
        let transcription = makeExportOptionsTranscription(
            cleanTranscript: "Edited transcript without timing.",
            isTranscriptEdited: true
        )

        let text = exportService.formatPlainText(transcription: transcription)

        XCTAssertTrue(text.contains("interview.mp3"))
        XCTAssertTrue(text.contains("Edited transcript without timing."))
        XCTAssertFalse(text.contains("[0:00] Hello."))
        XCTAssertFalse(text.contains("[0:02] Goodbye."))
        XCTAssertFalse(text.contains("Alice:"))
        XCTAssertFalse(text.contains("Bob:"))
    }

    func testFormatPlainTextDefaultKeepsTimestampsForAutomaticCleanTranscript() {
        let transcription = makeExportOptionsTranscription(cleanTranscript: "Automatically cleaned transcript.")
        let options = TranscriptExportOptions(includeSpeakerLabels: true)

        let text = exportService.formatPlainText(transcription: transcription, options: options)

        XCTAssertTrue(text.contains("[0:00] Hello."))
        XCTAssertTrue(text.contains("[0:02] Goodbye."))
        XCTAssertTrue(text.contains("Alice:"))
        XCTAssertTrue(text.contains("Bob:"))
        XCTAssertFalse(text.contains("Automatically cleaned transcript."))
    }

    func testFormatPlainTextCanOmitMetadataTimestampsAndSpeakers() {
        let transcription = makeExportOptionsTranscription(cleanTranscript: "Edited transcript without timing.")
        let options = TranscriptExportOptions(
            includeTimestamps: false,
            includeSpeakerLabels: false,
            includeMetadata: false
        )

        let text = exportService.formatPlainText(transcription: transcription, options: options)

        XCTAssertEqual(text, "Edited transcript without timing.")
        XCTAssertFalse(text.contains("interview.mp3"))
        XCTAssertFalse(text.contains("Duration:"))
        XCTAssertFalse(text.contains("Alice:"))
        XCTAssertFalse(text.contains("[0:00]"))
    }

    func testFormatPlainTextCanKeepSpeakersWithoutTimestamps() {
        let transcription = makeExportOptionsTranscription()
        let options = TranscriptExportOptions(
            includeTimestamps: false,
            includeSpeakerLabels: true,
            includeMetadata: false
        )

        let text = exportService.formatPlainText(transcription: transcription, options: options)

        XCTAssertTrue(text.contains("Alice:"))
        XCTAssertTrue(text.contains("Bob:"))
        XCTAssertTrue(text.contains("Hello."))
        XCTAssertFalse(text.contains("[0:00]"))
    }

    func testFormatPlainTextWithoutTimestampsJoinsSameSpeakerCues() {
        let transcription = makeMultiCueSpeakerTranscription()
        let options = TranscriptExportOptions(
            includeTimestamps: false,
            includeSpeakerLabels: true,
            includeMetadata: false
        )

        let text = exportService.formatPlainText(transcription: transcription, options: options)

        XCTAssertTrue(text.contains("Alice:\nFirst cue. Second cue."))
        XCTAssertFalse(text.contains("First cue.\nSecond cue."))
        XCTAssertFalse(text.contains("[0:00]"))
    }

    func testFormatMarkdownCanOmitMetadataTimestampsAndSpeakers() {
        let transcription = makeExportOptionsTranscription(cleanTranscript: "Edited transcript without timing.")
        let options = TranscriptExportOptions(
            includeTimestamps: false,
            includeSpeakerLabels: false,
            includeMetadata: false
        )

        let markdown = exportService.formatMarkdown(transcription: transcription, options: options)

        XCTAssertEqual(markdown.trimmingCharacters(in: .whitespacesAndNewlines), "Edited transcript without timing.")
        XCTAssertFalse(markdown.contains("# interview.mp3"))
        XCTAssertFalse(markdown.contains("**Duration:**"))
        XCTAssertFalse(markdown.contains("**Alice**"))
        XCTAssertFalse(markdown.contains("**[0:00]**"))
    }

    func testFormatMarkdownDefaultUsesEditedTranscriptWhenTimestampsExist() {
        let transcription = makeExportOptionsTranscription(
            cleanTranscript: "Edited transcript without timing.",
            isTranscriptEdited: true
        )

        let markdown = exportService.formatMarkdown(transcription: transcription)

        XCTAssertTrue(markdown.contains("# interview.mp3"))
        XCTAssertTrue(markdown.contains("Edited transcript without timing."))
        XCTAssertFalse(markdown.contains("**[0:00]** Hello."))
        XCTAssertFalse(markdown.contains("**[0:02]** Goodbye."))
        XCTAssertFalse(markdown.contains("**Alice**"))
        XCTAssertFalse(markdown.contains("**Bob**"))
    }

    func testFormatMarkdownWithoutTimestampsJoinsSameSpeakerCues() {
        let transcription = makeMultiCueSpeakerTranscription()
        let options = TranscriptExportOptions(
            includeTimestamps: false,
            includeSpeakerLabels: true,
            includeMetadata: false
        )

        let markdown = exportService.formatMarkdown(transcription: transcription, options: options)

        XCTAssertTrue(markdown.contains("**Alice**\n\nFirst cue. Second cue."))
        XCTAssertFalse(markdown.contains("First cue.\n\nSecond cue."))
        XCTAssertFalse(markdown.contains("**[0:00]**"))
    }

    func testExportToMarkdownUsesOptions() throws {
        let transcription = makeExportOptionsTranscription(cleanTranscript: "Edited transcript without timing.")
        let options = TranscriptExportOptions(
            includeTimestamps: false,
            includeSpeakerLabels: false,
            includeMetadata: false
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_options_\(UUID().uuidString).md")

        try exportService.exportToMarkdown(transcription: transcription, url: tempURL, options: options)
        let content = try String(contentsOf: tempURL, encoding: .utf8)

        XCTAssertEqual(content.trimmingCharacters(in: .whitespacesAndNewlines), "Edited transcript without timing.")

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
        // Use a > 800ms gap between sentences so the two-line packing pass
        // (`mergeAdjacentCuesForTwoLine`) leaves the cues separate. With a
        // short gap the algorithm intentionally merges adjacent short cues
        // into a single two-line cue for readability — see
        // `testBuildSubtitleCuesPacksShortAdjacentSentences` for that path.
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 500, confidence: 0.99),
            WordTimestamp(word: "world.", startMs: 600, endMs: 1000, confidence: 0.98),
            WordTimestamp(word: "How", startMs: 2000, endMs: 2300, confidence: 0.97),
            WordTimestamp(word: "are", startMs: 2400, endMs: 2600, confidence: 0.96),
            WordTimestamp(word: "you?", startMs: 2700, endMs: 3000, confidence: 0.95),
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

    func testBuildSubtitleCuesBreaksOnCharBudget() {
        // 8 words where the combined text clearly exceeds a tight maxCharsPerLine,
        // so the character-budget path (Phase 3) splits the cue.
        // Each "wordXX" is 6 chars; 8 words joined = 55 chars with spaces.
        // With maxCharsPerLine: 30, two cues are expected.
        var words: [WordTimestamp] = []
        for i in 0..<8 {
            words.append(WordTimestamp(
                word: String(format: "word%02d", i),
                startMs: i * 500,
                endMs: i * 500 + 400,
                confidence: 0.95
            ))
        }
        let config = SubtitleExportConfig(
            maxCharsPerLine: 30,
            maxLinesPerCue: 1,
            maxCPS: 0  // disable CPS enforcement so only char budget splits
        )
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        XCTAssertGreaterThan(cues.count, 1, "Long text should be split when it exceeds the char budget")
        // Every individual cue must fit within the budget (with small tolerance for wrap)
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.text.count, 40,
                "Each cue should be close to the character budget")
        }
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

    func testFormatSRTTranscriptionWithoutTimestampsUsesSingleCue() {
        let transcription = Transcription(
            fileName: "meeting.m4a",
            durationMs: 2500,
            rawTranscript: " Hello\n\nworld. ",
            status: .completed,
            sourceType: .meeting
        )

        let srt = exportService.formatSRT(transcription: transcription)

        XCTAssertEqual(srt, "1\n00:00:00,000 --> 00:00:02,500\nHello world.\n")
    }

    func testFormatVTTTranscriptionWithoutTimestampsUsesSingleCue() {
        let transcription = Transcription(
            fileName: "meeting.m4a",
            durationMs: 2500,
            rawTranscript: " Hello\n\nworld. ",
            status: .completed,
            sourceType: .meeting
        )

        let vtt = exportService.formatVTT(transcription: transcription)

        XCTAssertEqual(vtt, "WEBVTT\n\n00:00:00.000 --> 00:00:02.500\nHello world.\n")
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

    func testExportToSRTUsesEditedTranscriptWhenTimestampsExist() throws {
        let transcription = makeExportOptionsTranscription(
            cleanTranscript: "Edited transcript without timing.",
            isTranscriptEdited: true
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).srt")

        try exportService.exportToSRT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("1\n00:00:00,000 --> 00:00:05,000\nEdited transcript without timing."))
        XCTAssertFalse(content.contains("Hello."))
        XCTAssertFalse(content.contains("Goodbye."))

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToSRTCollapsesEditedTranscriptWhitespaceForSingleCue() throws {
        let transcription = makeExportOptionsTranscription(
            cleanTranscript: "Edited first line.\n\nEdited second line.\n  Edited third line.",
            isTranscriptEdited: true
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).srt")

        try exportService.exportToSRT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Edited first line. Edited second line. Edited third line."))
        XCTAssertFalse(content.contains("Edited first line.\n\nEdited second line."))

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToVTTUsesEditedTranscriptWhenTimestampsExist() throws {
        let transcription = makeExportOptionsTranscription(
            cleanTranscript: "Edited transcript without timing.",
            isTranscriptEdited: true
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).vtt")

        try exportService.exportToVTT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("WEBVTT\n"))
        XCTAssertTrue(content.contains("00:00:00.000 --> 00:00:05.000\nEdited transcript without timing."))
        XCTAssertFalse(content.contains("Hello."))
        XCTAssertFalse(content.contains("Goodbye."))

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToVTTCollapsesEditedTranscriptWhitespaceForSingleCue() throws {
        let transcription = makeExportOptionsTranscription(
            cleanTranscript: "Edited first line.\n\nEdited second line.\n  Edited third line.",
            isTranscriptEdited: true
        )
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).vtt")

        try exportService.exportToVTT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Edited first line. Edited second line. Edited third line."))
        XCTAssertFalse(content.contains("Edited first line.\n\nEdited second line."))

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

    func testExportToSRTWithoutTimestampsCollapsesWhitespace() throws {
        let transcription = Transcription(
            fileName: "audio.mp3",
            durationMs: 5000,
            rawTranscript: "Hello world.\n\nSecond paragraph.\n  Third line.",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).srt")

        try exportService.exportToSRT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Hello world. Second paragraph. Third line."))
        XCTAssertFalse(content.contains("Hello world.\n\nSecond paragraph."))

        try? FileManager.default.removeItem(at: tempURL)
    }

    func testExportToVTTWithoutTimestampsCollapsesWhitespace() throws {
        let transcription = Transcription(
            fileName: "audio.mp3",
            durationMs: 5000,
            rawTranscript: "Hello world.\n\nSecond paragraph.\n  Third line.",
            status: .completed
        )

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_export_\(UUID().uuidString).vtt")

        try exportService.exportToVTT(transcription: transcription, url: tempURL)

        let content = try String(contentsOf: tempURL, encoding: .utf8)
        XCTAssertTrue(content.contains("Hello world. Second paragraph. Third line."))
        XCTAssertFalse(content.contains("Hello world.\n\nSecond paragraph."))

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

        let srt = exportService.formatSRT(
            words: words,
            speakers: speakers,
            includeSpeakerLabels: true
        )
        XCTAssertTrue(srt.contains("Alice: Hello. Hi."))
        XCTAssertTrue(srt.contains("Bob: Goodbye. Bye."))
    }

    func testFormatSRTWithSpeakersLabelsDisabled() {
        let words = [
            WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
            WordTimestamp(word: "Hi.", startMs: 600, endMs: 1000, confidence: 0.98, speakerId: "S1"),
        ]
        let speakers = [SpeakerInfo(id: "S1", label: "Alice")]

        let srt = exportService.formatSRT(
            words: words,
            speakers: speakers,
            includeSpeakerLabels: false
        )
        XCTAssertTrue(srt.contains("\nHello. Hi.\n"))
        XCTAssertFalse(srt.contains("Alice:"))
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

        let vtt = exportService.formatVTT(
            words: words,
            speakers: speakers,
            includeSpeakerLabels: true
        )
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n"))
        XCTAssertTrue(vtt.contains("<v Alice>Hello. Hi.</v>"))
        XCTAssertTrue(vtt.contains("<v Bob>Goodbye. Bye.</v>"))
    }

    func testCueDoesNotSplitOnSpeakerChangeByDefault() {
        let words = [
            WordTimestamp(word: "Hi", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
            WordTimestamp(word: "there", startMs: 500, endMs: 1000, confidence: 0.98, speakerId: "S2"),
        ]

        let cues = exportService.buildSubtitleCues(from: words)
        XCTAssertEqual(cues.count, 1)
        XCTAssertEqual(cues[0].text, "Hi there")
    }

    func testCueSplitsOnSpeakerChange() {
        // Each speaker segment must have enough words/chars to survive mergeOrphanedCues
        // (which absorbs cues < 15 chars or < 3 words into neighbors).
        // The gap between speakers is > 800ms (gapThresholdMs default) so that
        // mergeAdjacentCuesForTwoLine does not pack the two speaker segments back
        // into a single two-line cue, which would lose speaker identity.
        let words = [
            WordTimestamp(word: "Hello",   startMs:    0, endMs:  300, confidence: 0.99, speakerId: "S1"),
            WordTimestamp(word: "there,",  startMs:  310, endMs:  600, confidence: 0.99, speakerId: "S1"),
            WordTimestamp(word: "Alice.",  startMs:  610, endMs:  900, confidence: 0.99, speakerId: "S1"),
            // 1100ms pause before speaker change (well above 800ms gapThresholdMs)
            WordTimestamp(word: "Good",    startMs: 2000, endMs: 2200, confidence: 0.99, speakerId: "S2"),
            WordTimestamp(word: "morning", startMs: 2210, endMs: 2500, confidence: 0.99, speakerId: "S2"),
            WordTimestamp(word: "Bob.",    startMs: 2510, endMs: 2800, confidence: 0.99, speakerId: "S2"),
        ]

        let cues = exportService.buildSubtitleCues(from: words, breakOnSpeakerChange: true)
        XCTAssertGreaterThanOrEqual(cues.count, 2,
            "Should produce separate cues for each speaker")
        // All cues from S1 must precede all cues from S2
        let s1Cues = cues.filter { $0.speakerId == "S1" }
        let s2Cues = cues.filter { $0.speakerId == "S2" }
        XCTAssertFalse(s1Cues.isEmpty, "S1 should have at least one cue")
        XCTAssertFalse(s2Cues.isEmpty, "S2 should have at least one cue")
        if let lastS1 = s1Cues.last, let firstS2 = s2Cues.first {
            XCTAssertLessThanOrEqual(lastS1.endMs, firstS2.startMs,
                "S1 cues should end before S2 cues start")
        }
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

        let md = exportService.formatMarkdown(
            transcription: transcription,
            options: TranscriptExportOptions(includeSpeakerLabels: true)
        )
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
        try exportService.exportToTxt(
            transcription: transcription,
            url: url,
            options: TranscriptExportOptions(includeSpeakerLabels: true)
        )
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

    private func makeExportOptionsTranscription(
        cleanTranscript: String? = nil,
        isTranscriptEdited: Bool = false
    ) -> Transcription {
        Transcription(
            fileName: "interview.mp3",
            durationMs: 5000,
            rawTranscript: "Hello. Goodbye.",
            cleanTranscript: cleanTranscript,
            wordTimestamps: [
                WordTimestamp(word: "Hello.", startMs: 0, endMs: 500, confidence: 0.99, speakerId: "S1"),
                WordTimestamp(word: "Goodbye.", startMs: 2000, endMs: 2500, confidence: 0.97, speakerId: "S2"),
            ],
            speakers: [
                SpeakerInfo(id: "S1", label: "Alice"),
                SpeakerInfo(id: "S2", label: "Bob"),
            ],
            status: .completed,
            isTranscriptEdited: isTranscriptEdited
        )
    }

    private func makeMultiCueSpeakerTranscription() -> Transcription {
        Transcription(
            fileName: "interview.mp3",
            durationMs: 8000,
            rawTranscript: "First cue. Second cue. Bob answers.",
            wordTimestamps: [
                WordTimestamp(word: "First", startMs: 0, endMs: 300, confidence: 0.99, speakerId: "S1"),
                WordTimestamp(word: "cue.", startMs: 350, endMs: 700, confidence: 0.99, speakerId: "S1"),
                WordTimestamp(word: "Second", startMs: 3000, endMs: 3300, confidence: 0.99, speakerId: "S1"),
                WordTimestamp(word: "cue.", startMs: 3350, endMs: 3700, confidence: 0.99, speakerId: "S1"),
                WordTimestamp(word: "Bob", startMs: 6000, endMs: 6300, confidence: 0.99, speakerId: "S2"),
                WordTimestamp(word: "answers.", startMs: 6350, endMs: 6800, confidence: 0.99, speakerId: "S2"),
            ],
            speakers: [
                SpeakerInfo(id: "S1", label: "Alice"),
                SpeakerInfo(id: "S2", label: "Bob"),
            ],
            status: .completed
        )
    }

    // MARK: - Word Timing Accuracy Tests

    // MARK: Improvement 1: Gap-Preferred Split Selection

    /// When enforceReadingSpeed must split a fast cue, the split should land at the
    /// word boundary with the largest inter-word gap — where the speaker paused —
    /// rather than at the midpoint.
    ///
    /// Fixture: 7 words, all < gapThreshold apart so they land in one cue.
    /// The biggest gap (600 ms) is after word2 at index 2.
    /// The midpoint (old default) is index 3.
    /// With the gap bonus, index 2 should score higher and win.
    func testGapPreferredSplitPicksLargestPause() {
        let words: [WordTimestamp] = [
            WordTimestamp(word: "wordA", startMs:    0, endMs:  200, confidence: 0.99),
            WordTimestamp(word: "wordB", startMs:  210, endMs:  400, confidence: 0.99),
            WordTimestamp(word: "wordC", startMs:  410, endMs:  600, confidence: 0.99),
            // 600ms gap here (largest, under gapThresholdMs=800 so stays in one cue)
            WordTimestamp(word: "wordD", startMs: 1200, endMs: 1400, confidence: 0.99),
            WordTimestamp(word: "wordE", startMs: 1410, endMs: 1600, confidence: 0.99),
            WordTimestamp(word: "wordF", startMs: 1610, endMs: 1800, confidence: 0.99),
            WordTimestamp(word: "wordG", startMs: 1810, endMs: 2000, confidence: 0.99),
        ]
        // Config: wide char budget (only CPS triggers split); maxCPS very low to force it.
        // Total text ≈ 41 chars over 2.0s ≈ 20 CPS >> 5.0 → split required.
        let config = SubtitleExportConfig(
            maxCharsPerLine: 100,
            gapThresholdMs: 800,  // 600ms gap < threshold, so all words stay in one cue
            maxCPS: 5.0
        )
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        XCTAssertGreaterThan(cues.count, 1, "High-CPS cue should be split by enforceReadingSpeed")
        // The split at the 600ms pause (after wordC, index 2) should win over the
        // midpoint (after wordD, index 3). First cue's endMs should be at wordC.endMs = 600.
        XCTAssertLessThanOrEqual(cues[0].endMs, 600,
            "Split should land at or before the 600ms gap boundary (wordC endMs=600), not the midpoint")
    }

    // MARK: Improvement 2: Trailing End-Time Buffer

    /// endTimeBufferMs extends each cue's endMs by the specified amount.
    func testEndTimeBufferExtendsEndMs() {
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Hello", startMs: 0,   endMs: 500, confidence: 0.99),
            WordTimestamp(word: "world", startMs: 600, endMs: 900, confidence: 0.99),
        ]
        let noBuffer = SubtitleExportConfig(endTimeBufferMs: 0)
        let withBuffer = SubtitleExportConfig(endTimeBufferMs: 60)

        let cuesNoBuffer   = exportService.buildSubtitleCues(from: words, config: noBuffer)
        let cuesWithBuffer = exportService.buildSubtitleCues(from: words, config: withBuffer)

        XCTAssertEqual(cuesNoBuffer.count, 1)
        XCTAssertEqual(cuesWithBuffer.count, 1)
        XCTAssertEqual(cuesNoBuffer[0].endMs, 900, "Without buffer, endMs should be the last word's endMs")
        XCTAssertEqual(cuesWithBuffer[0].endMs, 960, "With 60ms buffer, endMs should be extended by 60ms")
    }

    /// When the buffer would push endMs past the next cue's startMs, it is clamped
    /// so at least a 1 ms gap remains between cues.
    func testEndTimeBufferClampedByNextCueStart() {
        // Two cues separated by exactly the gapThreshold (800ms gap after "Hello world.")
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Hello",   startMs:    0, endMs:  400, confidence: 0.99),
            WordTimestamp(word: "world.",  startMs:  450, endMs:  700, confidence: 0.99),
            WordTimestamp(word: "Second.", startMs: 2000, endMs: 2500, confidence: 0.99),
        ]
        // Large buffer that would normally extend the first cue's endMs well past 2000ms
        let config = SubtitleExportConfig(gapThresholdMs: 800, endTimeBufferMs: 2000)
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        XCTAssertEqual(cues.count, 2, "Should produce 2 cues across the long gap")
        // First cue's endMs must be < second cue's startMs
        XCTAssertLessThan(cues[0].endMs, cues[1].startMs,
                          "Buffer must not cause cue 0 to overlap cue 1")
    }

    // MARK: Improvement 3: Input Overlap Sanitization

    /// Overlapping timestamps (word[i].endMs > word[i+1].startMs) are clamped so
    /// the earlier word's endMs does not exceed the next word's startMs.
    func testSanitizeOverlappingTimestamps() {
        // word[0].endMs (600) exceeds word[1].startMs (400) — an overlap
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Alpha", startMs:   0, endMs: 600, confidence: 0.99),
            WordTimestamp(word: "Beta",  startMs: 400, endMs: 800, confidence: 0.99),
        ]
        let config = SubtitleExportConfig(gapThresholdMs: 200)
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        // Should not crash. Both words should land in one cue.
        XCTAssertFalse(cues.isEmpty, "Should produce at least one cue")
        // After sanitization, the cue's startMs must be <= endMs
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.startMs, cue.endMs,
                                     "Cue start must not exceed cue end after overlap sanitization")
        }
    }

    /// A word with startMs == endMs (zero duration) is extended by 1 ms to prevent
    /// divide-by-zero in reading-speed enforcement.
    func testSanitizeZeroDurationWord() {
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Normal", startMs: 0,   endMs: 300, confidence: 0.99),
            WordTimestamp(word: "Zero",   startMs: 400, endMs: 400, confidence: 0.99), // zero-duration
        ]
        let config = SubtitleExportConfig()
        // Should not crash or produce invalid cues
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        XCTAssertFalse(cues.isEmpty, "Should produce cues from words including zero-duration word")
        for cue in cues {
            XCTAssertLessThanOrEqual(cue.startMs, cue.endMs)
        }
    }

    // MARK: Improvement 4: Frame-Snapping

    /// At 24fps (41.666…ms/frame), startMs rounds down and endMs rounds up to the
    /// nearest frame boundary.
    ///
    /// startMs = 100ms → frame 2 (83.333ms) → snaps DOWN to 83ms
    /// endMs   = 950ms → frame 23 (958.333ms) → snaps UP to 958ms
    func testFrameSnapAt24fps() {
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Hello", startMs: 100, endMs: 600, confidence: 0.99),
            WordTimestamp(word: "world", startMs: 700, endMs: 950, confidence: 0.99),
        ]
        let config = SubtitleExportConfig(snapToFrameRate: 24.0)
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        XCTAssertFalse(cues.isEmpty)
        let cue = cues[0]
        // startMs 100 → floor(100 / 41.6667) * 41.6667 = floor(2.4) * 41.6667 = 2 * 41.6667 ≈ 83ms
        XCTAssertEqual(cue.startMs, 83,
                       "startMs should snap down to frame 2 at 24fps (83ms)")
        // endMs 950 → ceil(950 / 41.6667) * 41.6667 = ceil(22.8) * 41.6667 = 23 * 41.6667 ≈ 958ms
        XCTAssertEqual(cue.endMs, 958,
                       "endMs should snap up to frame 23 at 24fps (958ms)")
    }

    /// When snapToFrameRate is nil, timestamps pass through unchanged.
    func testFrameSnapNilDoesNothing() {
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Hello", startMs: 123, endMs: 456, confidence: 0.99),
        ]
        let config = SubtitleExportConfig(snapToFrameRate: nil)
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        XCTAssertFalse(cues.isEmpty)
        XCTAssertEqual(cues[0].startMs, 123, "startMs should be unchanged when snapToFrameRate is nil")
        XCTAssertEqual(cues[0].endMs,   456, "endMs should be unchanged when snapToFrameRate is nil")
    }

    /// The default config (endTimeBufferMs: 0, snapToFrameRate: nil) produces the
    /// same output as before these improvements were added.
    func testDefaultConfigProducesUnchangedBehavior() {
        let words: [WordTimestamp] = [
            WordTimestamp(word: "This",    startMs:    0, endMs:  200, confidence: 0.99),
            WordTimestamp(word: "is",      startMs:  220, endMs:  350, confidence: 0.99),
            WordTimestamp(word: "a",       startMs:  360, endMs:  400, confidence: 0.99),
            WordTimestamp(word: "test.",   startMs:  410, endMs:  600, confidence: 0.99),
        ]
        let defaultConfig = SubtitleExportConfig()
        let explicitConfig = SubtitleExportConfig(endTimeBufferMs: 0, snapToFrameRate: nil)
        let cuesDefault  = exportService.buildSubtitleCues(from: words, config: defaultConfig)
        let cuesExplicit = exportService.buildSubtitleCues(from: words, config: explicitConfig)
        XCTAssertEqual(cuesDefault.count, cuesExplicit.count)
        for (a, b) in zip(cuesDefault, cuesExplicit) {
            XCTAssertEqual(a.startMs, b.startMs)
            XCTAssertEqual(a.endMs,   b.endMs)
            XCTAssertEqual(a.text,    b.text)
        }
    }

    /// SubtitleExportConfig can be encoded and decoded without data loss.
    /// New fields (endTimeBufferMs, snapToFrameRate) survive the round-trip.
    func testSubtitleExportConfigCodableRoundTrip() throws {
        let original = SubtitleExportConfig(
            maxCPS: 20.0,
            endTimeBufferMs: 50,
            snapToFrameRate: 29.97
        )
        let data    = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SubtitleExportConfig.self, from: data)
        XCTAssertEqual(decoded.endTimeBufferMs, 50)
        XCTAssertEqual(decoded.snapToFrameRate, 29.97)
        XCTAssertEqual(decoded.maxCPS, 20.0)
    }

    /// Overlapping consecutive cue timestamps are corrected by enforceMonotonicCues.
    /// Simulates Parakeet jitter where cue N's endMs exceeds cue N+1's startMs.
    func testEnforceMonotonicCuesFixesOverlap() {
        // Word stream: two short phrases separated by a long silence (2000ms)
        // which forces a gap-flush. We then manually craft the scenario by using
        // a long first word whose endMs slightly exceeds the next word's startMs
        // (simulating Parakeet timestamp jitter).
        let words: [WordTimestamp] = [
            WordTimestamp(word: "Hello",  startMs:     0, endMs: 17_851, confidence: 0.99),
            // Next word starts 34ms BEFORE previous word's endMs — classic Parakeet jitter
            WordTimestamp(word: "there.", startMs: 17_817, endMs: 19_452, confidence: 0.99),
        ]
        // Use gapThreshold=0 so words are NOT gap-split, forcing them to merge
        // into one cue — which lets us test that the output timestamps are sane.
        let config = SubtitleExportConfig(
            gapThresholdMs: 0,
            breakOnPunctuation: false,
            maxCPS: 0
        )
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        // Verify no cue ends after the next one starts
        for i in 0..<cues.count - 1 {
            XCTAssertLessThan(cues[i].endMs, cues[i + 1].startMs,
                "Cue \(i) endMs (\(cues[i].endMs)) must be < cue \(i+1) startMs (\(cues[i+1].startMs))")
        }
        // Verify all cues have positive duration
        for (i, cue) in cues.enumerated() {
            XCTAssertGreaterThan(cue.endMs, cue.startMs,
                "Cue \(i) must have positive duration: \(cue.startMs) → \(cue.endMs)")
        }
    }

    /// WordNumberSplitter is applied inside sanitizeWordTimestamps so fused tokens
    /// like "arms30." appear as "arms 30." in the resulting subtitle cue text.
    func testFusedTokensAreSplitInSubtitleCues() {
        let words: [WordTimestamp] = [
            WordTimestamp(word: "welcome",  startMs:   0, endMs:  300, confidence: 0.99),
            WordTimestamp(word: "to",       startMs: 350, endMs:  500, confidence: 0.99),
            WordTimestamp(word: "arms30.",  startMs: 550, endMs:  900, confidence: 0.99),
        ]
        let config = SubtitleExportConfig(breakOnPunctuation: false, maxCPS: 0)
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        let text = cues.map(\.text).joined(separator: " ")
        XCTAssertTrue(text.contains("arms 30."),
            "Expected 'arms 30.' after fused-token split, got: \(text)")
        XCTAssertFalse(text.contains("arms30"),
            "Fused token 'arms30' should not appear in output, got: \(text)")
    }

    /// A config stored before endTimeBufferMs/snapToFrameRate existed (missing those
    /// keys) decodes without error and falls back to the defaults (0 and nil).
    func testSubtitleExportConfigDecodesLegacyPayloadGracefully() throws {
        // Simulate an older stored payload that has no endTimeBufferMs or snapToFrameRate
        let legacyJSON = """
        {
            "maxWordsPerCue": 12,
            "maxCharsPerLine": 42,
            "maxLinesPerCue": 2,
            "maxDurationMs": 7000,
            "gapThresholdMs": 800,
            "breakOnPunctuation": true,
            "minWordsBeforePunctuationBreak": 4,
            "preferBalancedLines": true,
            "useLLMRefinement": false,
            "maxCPS": 17.0
        }
        """
        let data    = legacyJSON.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(SubtitleExportConfig.self, from: data)
        XCTAssertEqual(decoded.endTimeBufferMs, 0,   "Missing key should default to 0")
        XCTAssertNil(decoded.snapToFrameRate,        "Missing key should default to nil")
    }

    // MARK: - Merge behaviour

    /// A run of one-to-three-word cues with small gaps used to slip through
    /// mergeOrphanedCues because each pass produced new orphans. The
    /// iterate-to-fixpoint version should collapse them into one or two cues.
    func testMergeOrphanedCuesChainsTinyFragmentsToFixpoint() {
        // Six tiny cues separated by 100ms gaps. Pre-fix this stayed as 6
        // separate cues. Post-fix the chain should collapse.
        let words = [
            WordTimestamp(word: "oh",    startMs:    0, endMs:  100, confidence: 0.99),
            WordTimestamp(word: "five", startMs:  120, endMs:  240, confidence: 0.99),
            WordTimestamp(word: "to",    startMs:  340, endMs:  440, confidence: 0.99),
            WordTimestamp(word: "one",  startMs:  540, endMs:  640, confidence: 0.99),
            WordTimestamp(word: "oh",    startMs:  740, endMs:  840, confidence: 0.99),
            WordTimestamp(word: "five.", startMs:  940, endMs: 1040, confidence: 0.99),
        ]
        let cues = exportService.buildSubtitleCues(from: words)
        XCTAssertLessThanOrEqual(cues.count, 2,
            "Chain of six tiny cues with short gaps should collapse to at most 2 cues, got \(cues.count): \(cues.map(\.text))")
    }

    /// With the total-budget interpretation of `maxCharsPerLine`, two short
    /// cues only pack when their combined text fits within that total budget.
    func testMergeAdjacentCuesForTwoLineRespectsTotalBudget() {
        // Two short sentences (~15 chars each) — combined ≈ 32 chars, well
        // under the configured 65-char total budget.
        let words = [
            WordTimestamp(word: "Let's",   startMs:   0, endMs:  150, confidence: 0.99),
            WordTimestamp(word: "go",      startMs: 160, endMs:  280, confidence: 0.99),
            WordTimestamp(word: "now.",    startMs: 290, endMs:  450, confidence: 0.99),
            // small gap
            WordTimestamp(word: "Hands",   startMs:  800, endMs:  980, confidence: 0.99),
            WordTimestamp(word: "up",      startMs:  990, endMs: 1100, confidence: 0.99),
            WordTimestamp(word: "high.",   startMs: 1110, endMs: 1300, confidence: 0.99),
        ]
        let config = SubtitleExportConfig(maxCharsPerLine: 65, maxLinesPerCue: 2, maxCPS: 0)
        let cues = exportService.buildSubtitleCues(from: words, config: config)
        XCTAssertEqual(cues.count, 1,
            "Two short adjacent sentences within budget should pack into one cue, got \(cues.count): \(cues.map(\.text))")
        if cues.count == 1 {
            XCTAssertLessThanOrEqual(cues[0].text.replacingOccurrences(of: "\n", with: " ").count, 65,
                "Packed cue should still respect the total character budget")
        }
    }

    /// Regression for the "537 cues for a 30-min transcript" fragmentation
    /// pathology. When the sentence-aware path is active (cleanedTranscript
    /// supplied), 200 words across 10 punctuated sentences with realistic
    /// inter-word gaps must NOT explode into hundreds of single-word cues.
    func testSentencePathDoesNotFragmentOnNormalSilences() {
        // Build 10 sentences × 20 words each, with a 600 ms gap after every
        // word (well above the legacy 800 ms... wait, 600 ms is BELOW 800.
        // The crucial test is gaps that are normal-conversation but spaced
        // long enough that the legacy path would create fragments).
        // We use 900 ms gaps mid-sentence: that exceeds the legacy 800 ms
        // gap-flush threshold but is well below the new 3 s hard-pause.
        var ws: [WordTimestamp] = []
        var t = 0
        for s in 0..<10 {
            for w in 0..<20 {
                let isLastWordInSentence = w == 19
                let token = isLastWordInSentence ? "word\(w)." : "word\(w)"
                ws.append(WordTimestamp(word: token, startMs: t, endMs: t + 300, confidence: 0.95))
                // 900 ms mid-sentence gap, 1200 ms inter-sentence gap.
                let gap = isLastWordInSentence ? 1200 : 900
                t = t + 300 + gap
            }
            _ = s
        }
        let cleaned = ws.map(\.word).joined(separator: " ")
        let config = SubtitleExportConfig(
            maxCharsPerLine: 65,
            maxLinesPerCue: 2,
            gapThresholdMs: 800,
            maxCPS: 0  // disable reading-speed splits so this test is purely about boundary detection
        )

        // Legacy path (no cleanedTranscript): every 900 ms gap creates a cue
        // → expect way more cues than there are sentences. We just sanity
        // check this is still the OLD behaviour for back-compat.
        let legacyCues = exportService.buildSubtitleCues(from: ws, config: config)
        XCTAssertGreaterThan(legacyCues.count, 20, "Legacy path still uses gap-flush; should have many cues")

        // New sentence-aware path: dramatic improvement over legacy. The cue
        // count is bounded by char budget, but the FRAGMENTATION (cues with
        // < 3 words) must be eliminated.
        let cues = exportService.buildSubtitleCues(from: ws, cleanedTranscript: cleaned, config: config)
        XCTAssertLessThan(cues.count, legacyCues.count,
            "Sentence path must produce strictly fewer cues than the legacy gap-flush path. Got \(cues.count) vs \(legacyCues.count)")
        // No single-word or two-word orphans created by silence alone.
        for (i, cue) in cues.enumerated() {
            let wordCount = cue.text.replacingOccurrences(of: "\n", with: " ")
                .split(separator: " ").count
            XCTAssertGreaterThanOrEqual(wordCount, 3,
                "Cue \(i) has only \(wordCount) words — sentence path should not produce orphans. Text: \(cue.text)")
        }
    }

    /// When engine-emitted `STTSegment`s are supplied, the cue builder uses
    /// them as authoritative sentence-unit boundaries. With a generous char
    /// budget, two short segments may pack into a single two-line cue (the
    /// `mergeAdjacentCuesForTwoLine` pass is allowed to do this) — but the
    /// total word coverage and ordering must be preserved.
    func testEngineSegmentsDriveCueBoundaries() {
        let words = [
            WordTimestamp(word: "Hello",     startMs:    0, endMs:  500, confidence: 0.99),
            WordTimestamp(word: "there",     startMs:  500, endMs:  900, confidence: 0.99),
            WordTimestamp(word: "friend.",   startMs:  900, endMs: 1300, confidence: 0.99),
            WordTimestamp(word: "Goodbye",   startMs: 1400, endMs: 1800, confidence: 0.99),
            WordTimestamp(word: "and",       startMs: 1800, endMs: 2000, confidence: 0.99),
            WordTimestamp(word: "farewell.", startMs: 2000, endMs: 2500, confidence: 0.99),
        ]
        let segments: [STTSegment] = [
            STTSegment(startMs: 0, endMs: 1300, text: "Hello there friend."),
            STTSegment(startMs: 1400, endMs: 2500, text: "Goodbye and farewell."),
        ]
        // Tight budget so the two-line pack pass can't merge segments —
        // forces strict 1:1 segment→cue mapping.
        let config = SubtitleExportConfig(maxCharsPerLine: 22, maxLinesPerCue: 2, maxCPS: 0)
        let cues = exportService.buildSubtitleCues(
            from: words,
            engineSegments: segments,
            config: config
        )
        XCTAssertEqual(cues.count, 2, "Two engine segments should map to two cues under a tight budget. Got: \(cues.map(\.text))")
        XCTAssertEqual(cues[0].text.replacingOccurrences(of: "\n", with: " "), "Hello there friend.")
        XCTAssertEqual(cues[1].text.replacingOccurrences(of: "\n", with: " "), "Goodbye and farewell.")
    }

    /// Engine segments take priority over a cleaned transcript — if both are
    /// supplied, segments win. This guards against an inadvertent fallback to
    /// NLTokenizer when the STT engine already gave us authoritative
    /// boundaries.
    func testEngineSegmentsPreferredOverCleanedTranscript() {
        let words = [
            WordTimestamp(word: "Hello",  startMs:   0, endMs: 400, confidence: 0.99),
            WordTimestamp(word: "there.", startMs: 400, endMs: 800, confidence: 0.99),
            WordTimestamp(word: "Hi.",    startMs: 900, endMs: 1200, confidence: 0.99),
            WordTimestamp(word: "Yes.",   startMs: 1300, endMs: 1600, confidence: 0.99),
        ]
        // Cleaned transcript matches the words; would yield 3 sentence units
        // via NLTokenizer.
        let cleaned = "Hello there. Hi. Yes."
        // Engine segments group everything into ONE phrase — should win.
        let segments: [STTSegment] = [
            STTSegment(startMs: 0, endMs: 1600, text: "Hello there. Hi. Yes."),
        ]
        let config = SubtitleExportConfig(maxCharsPerLine: 65, maxLinesPerCue: 2, maxCPS: 0)
        let cues = exportService.buildSubtitleCues(
            from: words,
            cleanedTranscript: cleaned,
            engineSegments: segments,
            config: config
        )
        XCTAssertEqual(cues.count, 1,
            "Engine segments must take priority over cleanedTranscript; expected 1 cue but got \(cues.count): \(cues.map(\.text))")
    }

    /// The final `absorbShortNeighbours` pass must coalesce two
    /// medium-but-short adjacent cues whose combined text still fits the
    /// total budget. Regression for the cue-17/18 pattern in SRT (14):
    /// "we'll work on building" (22 chars) + "our cadence and our
    /// resistance" (30 chars) → one 53-char cue, not two.
    func testAbsorbShortNeighboursPacksMediumPairs() {
        // 9 words that the existing builder would Phase-3 split into two
        // medium cues at ~22 chars each. Realistic short-pause gaps.
        let words = [
            WordTimestamp(word: "we'll",      startMs:    0, endMs:  280, confidence: 0.99),
            WordTimestamp(word: "work",       startMs:  290, endMs:  500, confidence: 0.99),
            WordTimestamp(word: "on",         startMs:  510, endMs:  620, confidence: 0.99),
            WordTimestamp(word: "building",   startMs:  630, endMs:  990, confidence: 0.99),
            WordTimestamp(word: "our",        startMs: 1000, endMs: 1100, confidence: 0.99),
            WordTimestamp(word: "cadence",    startMs: 1110, endMs: 1500, confidence: 0.99),
            WordTimestamp(word: "and",        startMs: 1510, endMs: 1650, confidence: 0.99),
            WordTimestamp(word: "our",        startMs: 1660, endMs: 1750, confidence: 0.99),
            WordTimestamp(word: "resistance.", startMs: 1760, endMs: 2200, confidence: 0.99),
        ]
        let cleaned = "we'll work on building our cadence and our resistance."
        let config = SubtitleExportConfig(maxCharsPerLine: 65, maxLinesPerCue: 2, maxCPS: 17.0)
        let cues = exportService.buildSubtitleCues(
            from: words,
            cleanedTranscript: cleaned,
            config: config
        )
        XCTAssertEqual(cues.count, 1,
            "9-word, 53-char sentence within a 65-char budget should be one cue. Got \(cues.count): \(cues.map(\.text))")
    }

    /// The wrap step must never produce more than `maxLinesPerCue` lines, even
    /// when fed a cue that somehow exceeds the budget (e.g. from an
    /// overly-verbose LLM refinement).
    func testWrapNeverExceedsMaxLines() {
        let config = SubtitleExportConfig(maxCharsPerLine: 30, maxLinesPerCue: 2)
        // Long enough to want 3 lines at 10 chars each.
        let long = "alpha bravo charlie delta echo foxtrot golf hotel india"
        let wrapped = ExportService.wrapSubtitleTextStatic(long, config: config)
        let lineCount = wrapped.components(separatedBy: "\n").count
        XCTAssertLessThanOrEqual(lineCount, 2, "Wrap must hard-cap at maxLinesPerCue, got \(lineCount) lines: \(wrapped)")
    }
}
