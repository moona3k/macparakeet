import XCTest
@testable import MacParakeetCore

final class ShareProjectionTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_789_084_800)

    private let summaries = [ShareSummary(title: "Selected result", markdown: "The team reviewed Q3 goals.")]

    /// A transcription with every field the projection must never emit set to
    /// a unique, greppable sentinel value.
    private func makeKitchenSinkMeeting() -> Transcription {
        let words = ["Selected", "transcript", "words."].enumerated().map { index, word in
            WordTimestamp(word: word, startMs: index * 500, endMs: index * 500 + 400, confidence: 1, speakerId: "S1")
        }
        return Transcription(
            fileName: "sentinel-file-name.wav",
            filePath: "/private/sentinel/local/path.wav",
            meetingArtifactFolderPath: "/private/sentinel/artifacts",
            wordTimestamps: words,
            speakers: [SpeakerInfo(id: "S1", label: "sentinel-speaker-label")],
            status: .completed,
            exportPath: "/private/sentinel/export.txt",
            sourceURL: "https://sentinel-source.example/meeting",
            thumbnailURL: "https://sentinel-thumbnail.example/thumb.png",
            channelName: "sentinel-channel",
            videoDescription: "sentinel-video-description",
            sourceType: .meeting,
            userNotes: "Selected notes content.",
            engine: "sentinel-engine",
            engineVariant: "sentinel-engine-variant"
        )
    }

    // MARK: - Meeting default: summary + notes only

    func testMeetingSelectionProjectsOnlySummaryAndNotes() throws {
        let transcription = makeKitchenSinkMeeting()
        let selection = ShareSelection(includeSummary: true, includeNotes: true, includeTranscript: false)

        let bundle = try ShareProjection.project(
            transcription: transcription, summaries: summaries, selection: selection, publishedAt: fixedDate
        )

        let kinds = bundle.sections.map(sectionKind)
        XCTAssertFalse(kinds.contains("transcript"))
        XCTAssertTrue(kinds.contains("notes"))
        XCTAssertTrue(kinds.contains("summary"))

        guard case .notes(_, let notesMarkdown) = try XCTUnwrap(bundle.sections.first { sectionKind($0) == "notes" })
        else { return XCTFail() }
        XCTAssertEqual(notesMarkdown, "Selected notes content.")
    }

    // MARK: - Privacy allowlist

    func testProjectionNeverEmitsUnselectedSensitiveFields() throws {
        let transcription = makeKitchenSinkMeeting()
        let selection = ShareSelection(
            includeSummary: true, includeNotes: true, includeTranscript: true,
            transcriptOptions: TranscriptExportOptions(
                includeTimestamps: true, includeSpeakerLabels: true, includeMetadata: true)
        )

        let bundle = try ShareProjection.project(
            transcription: transcription, summaries: summaries, selection: selection, publishedAt: fixedDate
        )
        let json = String(data: try bundle.encodedJSON(), encoding: .utf8)!

        let excludedSentinels = [
            transcription.filePath!,
            transcription.meetingArtifactFolderPath!,
            transcription.exportPath!,
            transcription.sourceURL!,
            transcription.thumbnailURL!,
            transcription.channelName!,
            transcription.videoDescription!,
            transcription.engine!,
            transcription.engineVariant!,
            transcription.id.uuidString,
        ]
        for sentinel in excludedSentinels {
            XCTAssertFalse(json.contains(sentinel), "Bundle leaked excluded field: \(sentinel)")
        }

        // Selected content, by contrast, must be present.
        XCTAssertTrue(json.contains("Selected notes content."))
        XCTAssertTrue(json.contains("The team reviewed Q3 goals."))
        XCTAssertTrue(json.contains("Selected transcript words."))
        XCTAssertTrue(json.contains("sentinel-speaker-label"))
    }

    // MARK: - Transcript-only selection

    func testTranscriptOnlySelectionOmitsUnavailableTimestampsAndSpeakers() throws {
        let transcription = Transcription(
            fileName: "plain.wav",
            rawTranscript: "First paragraph of untimed text.\n\nSecond paragraph, still untimed.",
            status: .completed,
            sourceType: .file
        )
        let selection = ShareSelection(includeSummary: false, includeNotes: false, includeTranscript: true)

        let bundle = try ShareProjection.project(
            transcription: transcription, selection: selection, publishedAt: fixedDate
        )

        XCTAssertEqual(bundle.sections.count, 1)
        guard case .transcript(_, let segments) = bundle.sections[0] else { return XCTFail() }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "First paragraph of untimed text.")
        XCTAssertEqual(segments[1].text, "Second paragraph, still untimed.")
        for segment in segments {
            XCTAssertNil(segment.startMs)
            XCTAssertNil(segment.endMs)
            XCTAssertNil(segment.speaker)
        }
    }

    func testTranscriptSelectionRespectsExplicitlyDisabledOptionsEvenWhenAvailable() throws {
        let words = ["Alice", "speaks."].enumerated().map { index, word in
            WordTimestamp(word: word, startMs: index * 300, endMs: index * 300 + 250, confidence: 1, speakerId: "S1")
        }
        let transcription = Transcription(
            fileName: "timed.wav",
            wordTimestamps: words,
            speakers: [SpeakerInfo(id: "S1", label: "Alice")],
            status: .completed,
            sourceType: .file
        )
        let selection = ShareSelection(
            includeSummary: false, includeNotes: false, includeTranscript: true,
            transcriptOptions: TranscriptExportOptions(
                includeTimestamps: false, includeSpeakerLabels: false, includeMetadata: true)
        )

        let bundle = try ShareProjection.project(
            transcription: transcription, selection: selection, publishedAt: fixedDate
        )

        guard case .transcript(_, let segments) = bundle.sections[0] else { return XCTFail() }
        XCTAssertEqual(segments.count, 1)
        XCTAssertNil(segments[0].startMs)
        XCTAssertNil(segments[0].endMs)
        XCTAssertNil(segments[0].speaker)
    }

    // MARK: - Highlighted passage

    func testHighlightedPassageProjectsOnlyThatPassage() throws {
        let bundle = try ShareProjection.projectPassage(
            text: "Only this excerpt.", startMs: 1_000, endMs: 2_000, speaker: "Jordan",
            publishedAt: fixedDate
        )

        XCTAssertEqual(bundle.sections.count, 1)
        guard case .transcript(_, let segments) = bundle.sections[0] else { return XCTFail() }
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Only this excerpt.")
        XCTAssertEqual(segments[0].startMs, 1_000)
        XCTAssertEqual(segments[0].endMs, 2_000)
        XCTAssertEqual(segments[0].speaker, "Jordan")
        XCTAssertNil(bundle.title)
    }

    // MARK: - Failure before network I/O

    func testNothingSelectedFailsBeforeAnyEncryptionOrUpload() {
        let transcription = Transcription(fileName: "empty.wav", status: .completed, sourceType: .file)
        let selection = ShareSelection(includeSummary: false, includeNotes: false, includeTranscript: false)

        XCTAssertThrowsError(
            try ShareProjection.project(transcription: transcription, selection: selection)
        ) { error in
            XCTAssertEqual(error as? ShareProjectionError, .nothingSelected)
        }
    }

    func testEmptyPassageTextFailsBeforeAnyEncryptionOrUpload() {
        XCTAssertThrowsError(try ShareProjection.projectPassage(text: "   ")) { error in
            XCTAssertEqual(error as? ShareProjectionError, .nothingSelected)
        }
    }

    // MARK: - Helpers

    private func sectionKind(_ section: ShareBundle.Section) -> String {
        switch section {
        case .summary: return "summary"
        case .notes: return "notes"
        case .transcript: return "transcript"
        }
    }
}
