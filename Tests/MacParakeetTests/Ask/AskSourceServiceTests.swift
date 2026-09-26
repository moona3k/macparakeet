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
    func testRankedSearchFindsLateReversalWithPartialQueryMatchAcrossSelectedSources() throws {
        let earlier = Transcription(
            fileName: "Earlier",
            rawTranscript: "On September 1, the team approved the launch for October 10. Ada owns the release.",
            status: .completed, sourceType: .meeting)
        let later = Transcription(
            fileName: "Later",
            rawTranscript:
                "On September 8, the team discussed the launch. The previous October 10 date was provisional. "
                + String(repeating: "The team reviewed documentation, packaging, and support readiness. ", count: 160)
                + "Final decision: the launch moved to October 24; Bea now owns the release.",
            status: .completed, sourceType: .meeting)
        let excluded = Transcription(
            fileName: "Excluded", rawTranscript: "Launch date change: December 20. Cora owns the release.",
            status: .completed, sourceType: .meeting)
        for source in [earlier, later, excluded] { try transcriptions.save(source) }
        let receipts = try service.snapshot(sourceIDs: [earlier.id, later.id])
        let revisions = Dictionary(uniqueKeysWithValues: receipts.map { ($0.descriptor.id, $0.revision) })
        // These were the actual unsuccessful queries used by local models.
        for query in ["launch date", "launch date change", "LAUNCH, date?", "release owner"] {
            let hits = try service.search(query: query, sourceRevisions: revisions, limit: 8)
            XCTAssertTrue(
                hits.contains { $0.text.contains("October 10") && $0.reference.sourceID == earlier.id }, query)
            let final = try XCTUnwrap(hits.first { $0.text.contains("October 24") && $0.text.contains("Bea") }, query)
            XCTAssertGreaterThan(final.reference.segmentIndex, 10)
            XCTAssertEqual(try service.read(reference: final.reference, sourceRevisions: revisions), final)
            XCTAssertFalse(hits.contains { $0.reference.sourceID == excluded.id })
        }
        let narrowed = try service.search(
            query: "launch date", sourceRevisions: [earlier.id: revisions[earlier.id]!], limit: 8)
        XCTAssertEqual(Set(narrowed.map(\.reference.sourceID)), [earlier.id])
    }

    func testSearchRanksRelevantLatePassageAheadOfEarlyPartialMatches() throws {
        let text =
            String(repeating: "Budget discussion covered general costs and routine administration. ", count: 160)
            + "Approved budget: 4800 for the telescope."
        let source = Transcription(fileName: "Budget", rawTranscript: text, status: .completed, sourceType: .meeting)
        try transcriptions.save(source)
        let receipt = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
        let hits = try service.search(
            query: "telescope budget", sourceRevisions: [source.id: receipt.revision], limit: 1)
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].text.contains("4800"))
        XCTAssertGreaterThan(hits[0].reference.segmentIndex, 10)
    }

    func testSearchNormalizesTokensWithoutSubstringFalsePositivesOrQuerySyntax() throws {
        let source = Transcription(
            fileName: "Unicode", rawTranscript: "CAFÉ launch: approved. Update the packaging. 출시 확정.",
            status: .completed, sourceType: .meeting)
        try transcriptions.save(source)
        let receipt = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
        let scope = [source.id: receipt.revision]
        for query in ["cafe", "CAFÉ!", "출시", "\"launch\"", "launch launch"] {
            XCTAssertFalse(try service.search(query: query, sourceRevisions: scope, limit: 8).isEmpty, query)
        }
        for query in ["date", "unrelated", "text:*", "OR NOT NEAR"] {
            XCTAssertTrue(try service.search(query: query, sourceRevisions: scope, limit: 8).isEmpty, query)
        }
        XCTAssertTrue(try service.search(query: "?!*", sourceRevisions: scope, limit: 8).isEmpty)
    }

    func testSearchRechecksRevisionsAfterAnEarlierSearch() throws {
        var source = Transcription(
            fileName: "Changes", rawTranscript: "Launch June.", status: .completed, sourceType: .meeting)
        try transcriptions.save(source)
        let old = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
        XCTAssertFalse(try service.search(query: "June", sourceRevisions: [source.id: old.revision], limit: 8).isEmpty)
        source.rawTranscript = "Launch July."
        try transcriptions.save(source)
        XCTAssertThrowsError(try service.search(query: "June", sourceRevisions: [source.id: old.revision], limit: 8)) {
            XCTAssertEqual($0 as? AskSourceError, .stale)
        }
        let current = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
        XCTAssertTrue(
            try service.search(query: "June", sourceRevisions: [source.id: current.revision], limit: 8).isEmpty)
        XCTAssertFalse(
            try service.search(query: "July", sourceRevisions: [source.id: current.revision], limit: 8).isEmpty)
    }

    func testSearchPreservesDiscoveryInsideUnspacedScripts() throws {
        let source = Transcription(
            fileName: "Languages", rawTranscript: "我們確認發布日期。発売日を変更しました。วันเปิดตัวได้รับการยืนยันแล้ว",
            status: .completed, sourceType: .meeting)
        try transcriptions.save(source)
        let receipt = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
        for query in ["發布", "発売日", "เปิดตัว", "ยืนยัน", "發布 missing"] {
            XCTAssertFalse(
                try service.search(query: query, sourceRevisions: [source.id: receipt.revision], limit: 8).isEmpty,
                query)
        }
    }

    func testSearchContinuationPreservesRankedInterleavingWithoutDuplicates() throws {
        let first = Transcription(
            fileName: "First", rawTranscript: String(repeating: "Launch planning covers packaging. ", count: 80),
            status: .completed, sourceType: .meeting)
        let second = Transcription(
            fileName: "Second", rawTranscript: String(repeating: "Launch date pending. ", count: 50),
            status: .completed, sourceType: .meeting)
        for source in [first, second] { try transcriptions.save(source) }
        let receipts = try service.snapshot(sourceIDs: [first.id, second.id])
        let scope = Dictionary(uniqueKeysWithValues: receipts.map { ($0.descriptor.id, $0.revision) })
        let whole = try service.search(query: "launch date", sourceRevisions: scope, limit: 25)
        XCTAssertGreaterThan(whole.count, 6)
        var paged: [AskPassage] = []
        for start in stride(from: 0, to: whole.count, by: 3) {
            paged += try service.search(query: "launch date", sourceRevisions: scope, limit: 3, start: start)
        }
        XCTAssertEqual(paged, whole)
        XCTAssertTrue(
            try service.search(query: "launch date", sourceRevisions: scope, limit: 3, start: whole.count).isEmpty)
        XCTAssertThrowsError(try service.search(query: "launch", sourceRevisions: scope, limit: 3, start: -1))
    }

    func testMixedScriptSearchDoesNotTurnLatinWordsIntoSubstrings() throws {
        let source = Transcription(
            fileName: "Unrelated", rawTranscript: "Update the package. 無關內容。", status: .completed, sourceType: .meeting)
        try transcriptions.save(source)
        let receipt = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
        XCTAssertTrue(
            try service.search(query: "date 發布", sourceRevisions: [source.id: receipt.revision], limit: 8).isEmpty)
    }

    func testOversizedStoredTranscriptIsRejectedBeforeDecoding() throws {
        let source = Transcription(
            fileName: "Oversized", rawTranscript: "Launch June.", status: .completed, sourceType: .meeting)
        try transcriptions.save(source)
        try manager.dbQueue.write { db in
            // Invalid text payload deliberately proves the size gate precedes decoding.
            try db.execute(
                sql: "UPDATE transcriptions SET rawTranscript = zeroblob(?) WHERE id = ?",
                arguments: [64 * 1_024 * 1_024 + 1, source.id])
        }
        XCTAssertThrowsError(try service.snapshot(sourceIDs: [source.id])) {
            XCTAssertEqual($0 as? AskSourceError, .retrievalLimitExceeded)
        }
    }

    func testCancelledSearchDoesNotReturnEvidence() async throws {
        let source = Transcription(
            fileName: "Cancelled", rawTranscript: "Launch June.", status: .completed, sourceType: .meeting)
        try transcriptions.save(source)
        let receipt = try XCTUnwrap(service.snapshot(sourceIDs: [source.id]).first)
        let service = try XCTUnwrap(service)
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try service.search(query: "launch", sourceRevisions: [source.id: receipt.revision], limit: 8)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled retrieval returned evidence")
        } catch is CancellationError {}
    }

    func testSearchPagesReachAll32SourcesAndMoreThan25Matches() throws {
        var ids: [UUID] = []
        for index in 0..<32 {
            let source = Transcription(
                fileName: "Source \(index)",
                rawTranscript: String(repeating: "Launch plan. ", count: index < 3 ? 45 : 1),
                status: .completed, sourceType: .meeting)
            try transcriptions.save(source)
            ids.append(source.id)
        }
        let receipts = try service.snapshot(sourceIDs: ids)
        let scope = Dictionary(uniqueKeysWithValues: receipts.map { ($0.descriptor.id, $0.revision) })
        let expectedCount = receipts.reduce(0) { $0 + $1.passageCount }
        var baseline: [AskPassage] = []
        for size in [5, 12, 25] {
            var found: [AskPassage] = []
            while true {
                let page = try service.search(query: "launch", sourceRevisions: scope, limit: size, start: found.count)
                if page.isEmpty { break }
                found += page
                guard found.count <= expectedCount else { XCTFail("Duplicate continuation"); break }
            }
            XCTAssertEqual(found.count, expectedCount)
            XCTAssertEqual(Set(found.map(\.reference)).count, expectedCount)
            XCTAssertEqual(Set(found.prefix(32).map(\.reference.sourceID)), Set(ids))
            if baseline.isEmpty { baseline = found } else { XCTAssertEqual(found, baseline) }
        }
    }

}
