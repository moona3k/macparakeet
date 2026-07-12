import GRDB
import XCTest
@testable import MacParakeetCore

final class CardRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var transcriptions: TranscriptionRepository!
    private var cards: CardRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager()
        transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        cards = CardRepository(dbQueue: manager.dbQueue)
    }

    func testSaveRoundTripsJSONFieldsAndStalenessTuple() throws {
        let transcription = makeTranscription(source: .meeting)
        try transcriptions.save(transcription)
        let card = try makeCard(transcriptionId: transcription.id)

        try cards.save(card)

        XCTAssertEqual(try cards.fetch(transcriptionId: transcription.id), card)
        XCTAssertFalse(
            try cards.isStale(
                transcriptionId: transcription.id,
                current: card.provenance
            ))
        XCTAssertTrue(
            try cards.isStale(
                transcriptionId: transcription.id,
                current: CardProvenance(
                    transcriptHash: "changed",
                    segmenterVersion: card.segmenterVersion,
                    promptVersion: card.promptVersion,
                    cardSchemaVersion: card.cardSchemaVersion
                )
            ))
        let staleTuples = [
            CardProvenance(
                transcriptHash: card.transcriptHash,
                segmenterVersion: 99,
                promptVersion: card.promptVersion,
                cardSchemaVersion: card.cardSchemaVersion
            ),
            CardProvenance(
                transcriptHash: card.transcriptHash,
                segmenterVersion: card.segmenterVersion,
                promptVersion: "changed-prompt",
                cardSchemaVersion: card.cardSchemaVersion
            ),
            CardProvenance(
                transcriptHash: card.transcriptHash,
                segmenterVersion: card.segmenterVersion,
                promptVersion: card.promptVersion,
                cardSchemaVersion: 99
            ),
        ]
        for provenance in staleTuples {
            XCTAssertTrue(
                try cards.isStale(
                    transcriptionId: transcription.id,
                    current: provenance
                ))
        }
        XCTAssertTrue(
            try cards.isStale(
                transcriptionId: UUID(),
                current: card.provenance
            ))
    }

    func testConditionalSaveRejectsChangedSegmentSnapshot() throws {
        let transcription = makeTranscription(source: .meeting)
        try transcriptions.save(transcription)
        let segments = SegmentRepository(dbQueue: manager.dbQueue)
        try segments.replaceSegments(for: transcription)
        let originalSegments = try segments.fetch(transcriptionId: transcription.id)
        let expected = CardGenerationSnapshot(
            transcriptHash: CardContentFingerprint.transcriptHash(for: transcription),
            segmentsHash: CardContentFingerprint.segmentsHash(originalSegments)
        )
        var changed = try XCTUnwrap(originalSegments.first)
        changed.text = "Mutated citation target."
        try manager.dbQueue.write { db in try changed.update(db) }

        let saved = try cards.saveIfCurrent(
            try makeCard(transcriptionId: transcription.id),
            expected: expected
        )

        XCTAssertNil(saved)
        XCTAssertNil(try cards.fetch(transcriptionId: transcription.id))
    }

    func testSaveEnforcesCardTextBudgetAtRepositoryBoundary() throws {
        let transcription = makeTranscription(source: .file)
        try transcriptions.save(transcription)
        var card = try makeCard(transcriptionId: transcription.id)
        card.topics = (0..<500).map { "topic\($0)" }

        try cards.save(card)

        let stored = try XCTUnwrap(cards.fetch(transcriptionId: transcription.id))
        XCTAssertLessThan(stored.topics.count, card.topics.count)
        XCTAssertLessThanOrEqual(
            CardTextBudget.estimatedTokenCount(stored),
            CardTextBudget.maximumTokens
        )
    }

    func testBudgetPreservesSynopsisWhenCandidateFieldsAloneAreTooLarge() throws {
        let transcription = makeTranscription(source: .meeting)
        try transcriptions.save(transcription)
        var card = try makeCard(transcriptionId: transcription.id)
        card.actions = (0..<100).map { index in
            CardAction(
                text: String(repeating: "oversized action \(index) ", count: 20),
                owner: nil,
                seqStart: index,
                seqEnd: index,
                startMs: nil,
                endMs: nil
            )
        }

        try cards.save(card)

        let stored = try XCTUnwrap(cards.fetch(transcriptionId: transcription.id))
        XCTAssertFalse(stored.synopsis.isEmpty)
        XCTAssertLessThan(stored.actions.count, card.actions.count)
        XCTAssertLessThanOrEqual(
            CardTextBudget.estimatedTokenCount(stored),
            CardTextBudget.maximumTokens
        )
    }

    func testListJoinsDeterministicFieldsAndSourceConditionalAttendees() throws {
        let attendee = MeetingCalendarPerson(name: "Dana", email: "dana@example.com")
        let calendar = MeetingCalendarSnapshot(
            confidence: .confirmed,
            eventIdentifier: "event",
            title: "Planning",
            scheduledStartAt: Date(timeIntervalSince1970: 1_800_000_000),
            scheduledEndAt: Date(timeIntervalSince1970: 1_800_003_600),
            attendees: [attendee]
        )
        let meeting = makeTranscription(
            source: .meeting,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            durationMs: 3_600_000,
            calendar: calendar
        )
        let file = makeTranscription(
            source: .file,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMs: nil
        )
        try transcriptions.save(meeting)
        try transcriptions.save(file)
        try cards.save(try makeCard(transcriptionId: meeting.id))
        try cards.save(try makeCard(transcriptionId: file.id, decisions: [], actions: []))

        let rows = try cards.list(CardListQuery(limit: 10))

        XCTAssertEqual(rows.map(\.transcriptionId), [meeting.id, file.id])
        XCTAssertEqual(rows[0].title, meeting.fileName)
        XCTAssertEqual(rows[0].date, meeting.createdAt)
        XCTAssertEqual(rows[0].durationMs, 3_600_000)
        XCTAssertEqual(rows[0].source, .meeting)
        XCTAssertEqual(rows[0].attendees, [CardAttendee(name: attendee.name, email: attendee.email)])
        XCTAssertEqual(rows[1].source, .file)
        XCTAssertNil(rows[1].attendees)
        XCTAssertTrue(rows[1].decisions.isEmpty)
        XCTAssertTrue(rows[1].actions.isEmpty)
    }

    func testListTimeFiltersComposeWithSourcePredicate() throws {
        let oldMeeting = makeTranscription(
            source: .meeting,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let recentMeeting = makeTranscription(
            source: .meeting,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        let recentFile = makeTranscription(
            source: .file,
            createdAt: Date(timeIntervalSince1970: 300)
        )
        for transcription in [oldMeeting, recentMeeting, recentFile] {
            try transcriptions.save(transcription)
            try cards.save(try makeCard(transcriptionId: transcription.id))
        }

        let rows = try cards.list(
            CardListQuery(
                since: Date(timeIntervalSince1970: 200),
                until: Date(timeIntervalSince1970: 400),
                source: .meeting,
                limit: 10
            ))

        XCTAssertEqual(rows.map(\.transcriptionId), [recentMeeting.id])
    }

    func testListFetchesAcrossBoundedJoinBatchesLargerThanBatchSize() throws {
        let batchedCards = CardRepository(dbQueue: manager.dbQueue, listBatchSize: 2)
        var transcriptionsToSave: [Transcription] = []
        for index in 0..<5 {
            transcriptionsToSave.append(
                makeTranscription(
                    source: .meeting,
                    createdAt: Date(timeIntervalSince1970: TimeInterval(500 - index))
                ))
        }
        for transcription in transcriptionsToSave {
            try transcriptions.save(transcription)
            try cards.save(try makeCard(transcriptionId: transcription.id))
        }
        for transcription in transcriptionsToSave.prefix(2) {
            var changed = transcription
            changed.rawTranscript = "Changed after card generation."
            try transcriptions.save(changed)
        }

        let rows = try batchedCards.list(CardListQuery(limit: 2))

        let expectedIDs = transcriptionsToSave.dropFirst(2).prefix(2).map(\.id)
        XCTAssertEqual(rows.map(\.transcriptionId), expectedIDs)
    }

    func testListPushesLimitIntoJoinedSQLQuery() throws {
        let transcription = makeTranscription(source: .meeting)
        try transcriptions.save(transcription)
        try cards.save(try makeCard(transcriptionId: transcription.id))
        let trace = SQLTraceRecorder()
        manager.dbQueue.writeWithoutTransaction { db in
            db.trace { event in
                guard case .statement(let statement) = event else { return }
                trace.append(statement.sql)
            }
        }
        defer {
            manager.dbQueue.writeWithoutTransaction { db in
                db.trace(options: [])
            }
        }

        _ = try cards.list(CardListQuery(limit: 1))

        let listStatements = trace.statements.filter {
            $0.contains("FROM cards c JOIN transcriptions t")
        }
        XCTAssertFalse(listStatements.isEmpty)
        XCTAssertTrue(listStatements.allSatisfy { $0.contains("LIMIT ? OFFSET ?") })
        XCTAssertTrue(listStatements.allSatisfy { $0.hasPrefix("SELECT c.*, t.*") })
    }

    func testCompletedTranscriptionIDsExcludeInProgressRows() throws {
        let completed = makeTranscription(source: .meeting)
        var processing = makeTranscription(source: .file)
        processing.status = .processing
        try transcriptions.save(completed)
        try transcriptions.save(processing)

        XCTAssertEqual(try cards.completedTranscriptionIDs(), [completed.id])
    }

    func testListSuppressesTranscriptStaleCardsAndStaleSelectionReturnsOnlySubset() throws {
        var changed = makeTranscription(source: .meeting)
        let fresh = makeTranscription(source: .file)
        try transcriptions.save(changed)
        try transcriptions.save(fresh)
        try cards.save(try makeCard(transcriptionId: changed.id))
        try cards.save(try makeCard(transcriptionId: fresh.id))

        changed.rawTranscript = "The canonical transcript was replaced."
        changed.updatedAt = Date(timeIntervalSince1970: 1_800_000_500)
        try transcriptions.save(changed)

        let listed = try cards.list(CardListQuery(limit: 10))
        XCTAssertEqual(listed.map(\.transcriptionId), [fresh.id])
        XCTAssertEqual(try cards.staleCompletedTranscriptionIDs(), [changed.id])
    }

    func testURLSourceFilterIncludesYouTubeAndPodcast() throws {
        let meeting = makeTranscription(source: .meeting)
        let youtube = makeTranscription(source: .youtube)
        let podcast = makeTranscription(source: .podcast)
        for transcription in [meeting, youtube, podcast] {
            try transcriptions.save(transcription)
            try cards.save(try makeCard(transcriptionId: transcription.id))
        }

        let rows = try cards.list(CardListQuery(source: .url, limit: 10))

        XCTAssertEqual(Set(rows.map(\.transcriptionId)), [youtube.id, podcast.id])
        XCTAssertTrue(rows.allSatisfy { $0.source == .url })
        XCTAssertTrue(rows.allSatisfy { $0.decisions.isEmpty && $0.actions.isEmpty })
    }

    func testCardsFTSStaysSynchronizedAcrossInsertUpdateDelete() throws {
        let transcription = makeTranscription(source: .meeting)
        try transcriptions.save(transcription)
        var card = try makeCard(transcriptionId: transcription.id)
        try cards.save(card)
        XCTAssertEqual(try ftsCount(matching: "sparkle"), 1)
        let indexedTopics: String? = try manager.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT topics FROM cards_fts WHERE rowid = (SELECT rowid FROM cards WHERE transcriptionId = ?)",
                arguments: [transcription.id]
            )
        }
        XCTAssertEqual(indexedTopics, "Sparkle cache invalidation")

        card.synopsis = "Discussed release notarization."
        card.topics = ["distribution"]
        try cards.save(card)
        XCTAssertEqual(try ftsCount(matching: "sparkle"), 0)
        XCTAssertEqual(try ftsCount(matching: "notarization"), 1)

        try cards.delete(transcriptionId: transcription.id)
        XCTAssertEqual(try ftsCount(matching: "notarization"), 0)
    }

    func testCardsFTSRebuildRestoresTriggerDerivedPlainTopicIndex() throws {
        let transcription = makeTranscription(source: .meeting)
        try transcriptions.save(transcription)
        let card = try makeCard(transcriptionId: transcription.id)
        try cards.save(card)
        try manager.dbQueue.write { db in
            let rowID = try Int64.fetchOne(
                db,
                sql: "SELECT rowid FROM cards WHERE transcriptionId = ?",
                arguments: [transcription.id]
            )
            try db.execute(
                sql: """
                    INSERT INTO cards_fts(cards_fts, rowid, synopsis, topics)
                    VALUES ('delete', ?, ?, ?)
                    """,
                arguments: [rowID, card.synopsis, card.topics.joined(separator: " ")]
            )
        }
        XCTAssertEqual(try ftsCount(matching: "sparkle"), 0)

        try cards.rebuildFTS()

        XCTAssertEqual(try ftsCount(matching: "sparkle"), 1)
        let indexedTopics: String? = try manager.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT topics FROM cards_fts WHERE rowid = (SELECT rowid FROM cards WHERE transcriptionId = ?)",
                arguments: [transcription.id]
            )
        }
        XCTAssertEqual(indexedTopics, "Sparkle cache invalidation")
    }

    private func makeTranscription(
        source: Transcription.SourceType,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000),
        durationMs: Int? = 1_000,
        calendar: MeetingCalendarSnapshot? = nil
    ) -> Transcription {
        Transcription(
            createdAt: createdAt,
            fileName: source == .meeting ? "Knowledge Review" : "notes.m4a",
            durationMs: durationMs,
            rawTranscript: "Discussed Sparkle cache busting.",
            status: .completed,
            sourceType: source,
            calendarEventSnapshot: calendar,
            updatedAt: createdAt
        )
    }

    private func makeCard(
        transcriptionId: UUID,
        decisions: [CardDecision] = [
            CardDecision(text: "Ship cache busting", seqStart: 0, seqEnd: 0, startMs: 100, endMs: 200)
        ],
        actions: [CardAction] = [
            CardAction(text: "Verify appcast", owner: "Dana", seqStart: 1, seqEnd: 1, startMs: nil, endMs: nil)
        ]
    ) throws -> Card {
        let transcription = try XCTUnwrap(transcriptions.fetch(id: transcriptionId))
        return Card(
            transcriptionId: transcriptionId,
            cardSchemaVersion: 1,
            transcriptHash: CardContentFingerprint.transcriptHash(for: transcription),
            segmenterVersion: 2,
            promptVersion: "knowledge-card-v1",
            model: "stub-model",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_100),
            synopsis: "Discussed Sparkle cache busting.",
            topics: ["Sparkle", "cache invalidation"],
            decisions: decisions,
            actions: actions
        )
    }

    private func ftsCount(matching query: String) throws -> Int {
        try manager.dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT count(*) FROM cards_fts WHERE cards_fts MATCH ?",
                arguments: [query]
            ) ?? 0
        }
    }
}

private final class SQLTraceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var statements: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ statement: String) {
        lock.lock()
        storage.append(statement)
        lock.unlock()
    }
}
