import GRDB
import XCTest
@testable import MacParakeetCore

final class AskSourceServiceTests: XCTestCase {
    private var manager: DatabaseManager!
    private var transcriptions: TranscriptionRepository!
    private var service: AskSourceService!

    override func setUpWithError() throws {
        manager = try DatabaseManager()
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        service = AskSourceService(dbQueue: manager.dbQueue)
    }

    func testPickerFiltersMetadataByTitleKindDateAndExistingLabel() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let earlier = Date(timeIntervalSince1970: 1_600_000_000)
        let first = Transcription(
            createdAt: date, fileName: "Weekly sync", rawTranscript: "Current launch plan.",
            status: .completed, sourceType: .meeting
        )
        let second = Transcription(
            createdAt: earlier, fileName: "Weekly sync", rawTranscript: "Older plan.",
            status: .completed, sourceType: .meeting
        )
        let unrelated = Transcription(
            createdAt: date, fileName: "Workshop", rawTranscript: "A separate topic.",
            status: .completed, sourceType: .file
        )
        for source in [first, second, unrelated] { try transcriptions.save(source) }
        let label = MeetingLabel(name: "Launch")
        try MeetingLabelRepository(dbQueue: manager.dbQueue).save(label)
        try TranscriptionMeetingLabelRepository(dbQueue: manager.dbQueue).add(
            labelId: label.id, to: first.id
        )

        let rows = try service.listSources(
            filter: AskSourceFilter(
                searchText: "Weekly", sourceType: .meeting,
                since: date.addingTimeInterval(-60),
                labelIDs: [label.id]
            ))
        XCTAssertEqual(rows.map(\.id), [first.id])
        XCTAssertEqual(rows.first?.recordedAt, date)
        XCTAssertEqual(rows.first?.labelIDs, [label.id])
        XCTAssertEqual(rows.first?.title, "Weekly sync")
    }

    func testPickerAvailabilityMatchesUsableCanonicalSourceKindsAndLegacyEditPrecedence() throws {
        let words = [WordTimestamp(word: "Decision", startMs: 0, endMs: 200, confidence: 1)]
        let segment = TranscriptSegmentRecord(
            startMs: 0, endMs: 200, speakerId: nil, speakerLabel: "Unknown Speaker", text: "Decision",
            wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1))
        var blankSegment = segment
        blankSegment.text = " \t\n"
        let cases: [(Transcription, Bool)] = [
            (Transcription(fileName: "Missing", status: .completed), false),
            (Transcription(fileName: "Empty", rawTranscript: "", cleanTranscript: "", status: .completed), false),
            (Transcription(fileName: "Whitespace", rawTranscript: " \t\n\u{00A0}\u{2009}", status: .completed), false),
            (
                Transcription(
                    fileName: "Raw fallback", rawTranscript: "Decision", cleanTranscript: " ", status: .completed), true
            ),
            (Transcription(fileName: "Clean", cleanTranscript: "Decision", status: .completed), true),
            (Transcription(fileName: "Words only", wordTimestamps: words, status: .completed), true),
            (Transcription(fileName: "Segments only", transcriptSegments: [segment], status: .completed), true),
            (
                Transcription(fileName: "Empty arrays", wordTimestamps: [], transcriptSegments: [], status: .completed),
                false
            ),
            (Transcription(fileName: "Blank segments", transcriptSegments: [blankSegment], status: .completed), false),
            (
                Transcription(
                    fileName: "Edited empty", rawTranscript: "Old", cleanTranscript: " \n",
                    wordTimestamps: words, transcriptSegments: [segment], status: .completed,
                    isTranscriptEdited: true), false
            ),
            (
                Transcription(
                    fileName: "Edited available", cleanTranscript: "Corrected", status: .completed,
                    isTranscriptEdited: true), true
            ),
        ]
        for (source, _) in cases { try transcriptions.save(source) }
        let picker = Dictionary(uniqueKeysWithValues: try service.listSources().map { ($0.id, $0.isAvailable) })
        for (source, expected) in cases {
            XCTAssertEqual(picker[source.id], expected, source.fileName)
            let snapshot = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
            XCTAssertEqual(snapshot.status == .available, expected, source.fileName)
        }
    }

    func testMalformedLegacyTimingJSONDoesNotBreakMetadataPicker() throws {
        let source = Transcription(fileName: "Malformed legacy row", status: .completed)
        try transcriptions.save(source)
        try manager.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE transcriptions SET transcriptSegments = ?, wordTimestamps = ? WHERE id = ?",
                arguments: ["{invalid", "[\"not an object\"]", source.id])
        }
        let rows = try service.listSources()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, source.id)
        XCTAssertEqual(rows.first?.isAvailable, false)
    }

    func testPickerSearchTreatsWildcardsAndEscapeCharacterLiterallyInEveryTitleField() throws {
        for field in 0..<3 {
            for (index, literal) in ["%", "_", "!", "!_%"].enumerated() {
                let prefix = "Title-\(field)-\(index)-"
                var matching = Transcription(fileName: "Recording", rawTranscript: "Text", status: .completed)
                var other = Transcription(fileName: "Recording", rawTranscript: "Text", status: .completed)
                switch field {
                case 0:
                    matching.fileName = prefix + literal
                    other.fileName = prefix + "other"
                case 1:
                    matching.titleOverride = prefix + literal
                    other.titleOverride = prefix + "other"
                default:
                    matching.derivedTitle = prefix + literal
                    other.derivedTitle = prefix + "other"
                }
                try transcriptions.save(matching)
                try transcriptions.save(other)
                let rows = try service.listSources(filter: AskSourceFilter(searchText: prefix + literal))
                XCTAssertEqual(rows.map(\.id), [matching.id], "field \(field), literal \(literal)")
            }
        }
    }

    func testScopeBoundSearchReadAndDeletedEvidenceStatus() throws {
        let first = Transcription(
            fileName: "First", rawTranscript: "Launch date moved to June.",
            status: .completed, sourceType: .meeting
        )
        let second = Transcription(
            fileName: "Second", rawTranscript: "Launch date moved to July.",
            status: .completed, sourceType: .meeting
        )
        try transcriptions.save(first)
        try transcriptions.save(second)
        let snapshot = try XCTUnwrap(service.snapshot(sourceIDs: [first.id]).first)
        XCTAssertEqual(
            try service.snapshot(sourceIDs: [first.id]).first?.revision,
            snapshot.revision
        )
        let revisions = [first.id: snapshot.revision]
        let matches = try service.search(query: "June", sourceRevisions: revisions, limit: 5)
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.reference.sourceID, first.id)
        XCTAssertTrue(try service.search(query: "July", sourceRevisions: revisions, limit: 5).isEmpty)
        let passage = try XCTUnwrap(matches.first)
        XCTAssertEqual(try service.read(reference: passage.reference, sourceRevisions: revisions), passage)
        XCTAssertEqual(
            try service.passages(
                sourceID: first.id, start: 0, limit: 5, sourceRevisions: revisions
            ), [passage])
        let forbidden = AskEvidenceReference(
            sourceID: second.id, sourceRevision: snapshot.revision, segmentIndex: 0
        )
        XCTAssertEqual(try service.validate(reference: forbidden, sourceRevisions: revisions), .outOfScope)
        XCTAssertThrowsError(try service.read(reference: forbidden, sourceRevisions: revisions)) {
            XCTAssertEqual($0 as? AskSourceError, .outOfScope)
        }

        _ = try transcriptions.delete(id: first.id)
        XCTAssertEqual(try service.validate(reference: passage.reference, sourceRevisions: revisions), .unavailable)
        let afterDelete = try XCTUnwrap(service.snapshot(sourceIDs: [first.id]).first)
        XCTAssertEqual(afterDelete.status, .unavailable)
        XCTAssertEqual(afterDelete.descriptor.id, first.id)
    }

    func testLegacyWholeTextEditExcludesOldTimedWordsAndRevisionChangesOnEdit() throws {
        let original = Transcription(
            fileName: "Imported interview",
            rawTranscript: "Old false launch date.",
            cleanTranscript: "Corrected June decision.",
            wordTimestamps: [
                WordTimestamp(
                    word: "Old", startMs: 1_000, endMs: 1_200, confidence: 1
                )
            ],
            status: .completed,
            sourceType: .file,
            isTranscriptEdited: true
        )
        try transcriptions.save(original)
        let snapshot = try XCTUnwrap(service.snapshot(sourceIDs: [original.id]).first)
        let revisions = [original.id: snapshot.revision]
        let passage = try XCTUnwrap(
            service.passages(
                sourceID: original.id, start: 0, limit: 1, sourceRevisions: revisions
            ).first)
        XCTAssertEqual(passage.text, "Corrected June decision.")
        XCTAssertNil(passage.startMs)
        XCTAssertNil(passage.endMs)
        XCTAssertTrue(try service.search(query: "Old", sourceRevisions: revisions, limit: 5).isEmpty)

        var edited = original
        edited.cleanTranscript = "Corrected July decision."
        try transcriptions.save(edited)
        XCTAssertEqual(try service.validate(reference: passage.reference, sourceRevisions: revisions), .stale)
        XCTAssertThrowsError(try service.read(reference: passage.reference, sourceRevisions: revisions)) {
            XCTAssertEqual($0 as? AskSourceError, .stale)
        }
        let newSnapshot = try XCTUnwrap(service.snapshot(sourceIDs: [original.id]).first)
        XCTAssertNotEqual(newSnapshot.revision, snapshot.revision)
    }

    func testSummaryRequiresCurrentTranscriptAndCorrectionReceipts() throws {
        let original = Transcription(
            fileName: "Planning", rawTranscript: "The deadline is June.",
            status: .completed, sourceType: .meeting
        )
        try transcriptions.save(original)
        let summaryPrompt = Prompt(name: "Ask source summary", content: "Summarize", category: .result)
        let transformPrompt = Prompt(name: "Ask source transform", content: "Rewrite", category: .transform)
        let prompts = PromptRepository(dbQueue: manager.dbQueue)
        try prompts.save(summaryPrompt)
        try prompts.save(transformPrompt)
        let staleLegacy = PromptResult(
            transcriptionId: original.id, promptName: "Notes", promptContent: "Summarize",
            content: "Unverified old summary"
        )
        let current = PromptResult(
            transcriptionId: original.id, promptId: summaryPrompt.id,
            promptName: "Summary", promptContent: "Summarize",
            content: "June was discussed.",
            sourceCorrectionRevision: 0,
            sourceTranscriptHash: PromptResultFreshness.sourceTranscriptHash(for: original)
        )
        let unsafeTransform = PromptResult(
            transcriptionId: original.id, promptId: transformPrompt.id,
            promptName: "Transform", promptContent: "Rewrite",
            content: "A rewritten output with valid transcript receipts.",
            sourceCorrectionRevision: 0,
            sourceTranscriptHash: PromptResultFreshness.sourceTranscriptHash(for: original)
        )
        let summaries = PromptResultRepository(dbQueue: manager.dbQueue)
        try summaries.save(staleLegacy)
        try summaries.save(current)
        try summaries.save(unsafeTransform)
        let receipt = try XCTUnwrap(service.snapshot(sourceIDs: [original.id]).first)
        XCTAssertEqual(
            try service.summaries(
                sourceID: original.id, sourceRevisions: [original.id: receipt.revision]
            ).map(\.id), [current.id])

        var changed = original
        changed.rawTranscript = "The deadline is July."
        try transcriptions.save(changed)
        let newReceipt = try XCTUnwrap(service.snapshot(sourceIDs: [original.id]).first)
        XCTAssertTrue(
            try service.summaries(
                sourceID: original.id, sourceRevisions: [original.id: newReceipt.revision]
            ).isEmpty)
    }

    func testSearchDistributesHitsAcrossRecordingsAndRespectsFileRename() throws {
        let first = Transcription(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            fileName: "Long meeting", rawTranscript: String(repeating: "Launch details changed. ", count: 1_000),
            status: .completed, sourceType: .meeting
        )
        var second = Transcription(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            fileName: "import.txt", rawTranscript: "Launch is delayed.", status: .completed, sourceType: .file
        )
        second.titleOverride = "Customer decisions"
        try transcriptions.save(first)
        try transcriptions.save(second)
        let snapshots = try service.snapshot(sourceIDs: [first.id, second.id])
        let versions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.descriptor.id, $0.revision) })
        let results = try service.search(query: "launch", sourceRevisions: versions, limit: 2)
        XCTAssertEqual(Set(results.map(\.reference.sourceID)), [first.id, second.id])
        let picker = try service.listSources(filter: AskSourceFilter(searchText: "Customer decisions"))
        XCTAssertEqual(picker.first?.title, "Customer decisions")
    }

    func testOversizedTimedSegmentExposesLateDecisionWithoutInventingChunkTiming() throws {
        let longPreamble = Array(repeating: "We discussed the launch options.", count: 80)
            .joined(separator: " ")
        let text = longPreamble + " The final decision moved launch to November."
        let source = Transcription(
            fileName: "Long meeting", cleanTranscript: text,
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 1_000, endMs: 60_000,
                    speakerId: nil, speakerLabel: "Unknown Speaker", text: text,
                    wordRange: TranscriptSegmentWordRange(startIndex: 0, endIndexExclusive: 1)
                )
            ],
            status: .completed, sourceType: .meeting
        )
        try transcriptions.save(source)
        let snapshot = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
        XCTAssertGreaterThan(snapshot.passageCount, 1)
        let revisions = [source.id: snapshot.revision]
        let matches = try service.search(query: "November", sourceRevisions: revisions, limit: 5)
        let late = try XCTUnwrap(matches.first)
        XCTAssertGreaterThan(late.reference.segmentIndex, 0)
        XCTAssertTrue(late.text.contains("final decision moved launch to November"))
        XCTAssertLessThanOrEqual(late.text.unicodeScalars.count, 500)
        XCTAssertNil(late.startMs)
        XCTAssertEqual(try service.read(reference: late.reference, sourceRevisions: revisions), late)
        XCTAssertEqual(
            try service.snapshot(sourceIDs: [source.id]).first?.revision,
            snapshot.revision
        )
    }
}
