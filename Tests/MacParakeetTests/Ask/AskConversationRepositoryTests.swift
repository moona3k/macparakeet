import GRDB
import XCTest
@testable import MacParakeetCore

final class AskConversationRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var repository: AskConversationRepository!

    override func setUpWithError() throws {
        manager = try DatabaseManager()
        repository = AskConversationRepository(dbQueue: manager.dbQueue)
    }

    func testIndependentHistoryRoundTripAndRevisionSave() throws {
        let sourceID = UUID()
        let first = AskContextSection(sourceIDs: [sourceID])
        let second = AskContextSection(sourceIDs: [UUID(), sourceID])
        let reference = AskEvidenceReference(
            sourceID: sourceID, sourceRevision: "revision-a", segmentIndex: 2
        )
        var conversation = AskConversation(
            title: "Launch decision",
            sections: [first, second],
            messages: [
                AskMessage(
                    sectionID: first.id, role: .assistant, content: "It changed.",
                    citations: [reference], sourceRevisions: [sourceID: "revision-a"]
                )
            ],
            draft: "Why did it change?"
        )
        try repository.create(conversation)
        XCTAssertEqual(try repository.fetch(id: conversation.id)?.title, "Launch decision")
        XCTAssertEqual(try repository.fetch(id: conversation.id)?.draft, "Why did it change?")

        conversation.draft = "What changed next?"
        conversation = try repository.save(conversation, expectedRevision: 0)
        XCTAssertEqual(conversation.revision, 1)
        XCTAssertEqual(try repository.fetch(id: conversation.id)?.sections, [first, second])
        XCTAssertEqual(try repository.fetch(id: conversation.id)?.messages.first?.citations, [reference])
        XCTAssertEqual(try repository.fetchAll().map(\.id), [conversation.id])
    }

    func testStaleSaveAndLateSaveAfterDeletionNeverRecreate() throws {
        let original = try repository.create(AskConversation())
        var firstWriter = original
        var staleWriter = original
        firstWriter.title = "First writer"
        _ = try repository.save(firstWriter, expectedRevision: 0)
        staleWriter.title = "Stale writer"
        XCTAssertThrowsError(try repository.save(staleWriter, expectedRevision: 0)) {
            XCTAssertEqual($0 as? AskConversationRepositoryError, .conflict)
        }
        XCTAssertEqual(try repository.fetch(id: original.id)?.title, "First writer")

        XCTAssertTrue(try repository.delete(id: original.id))
        staleWriter.revision = 1
        XCTAssertThrowsError(try repository.save(staleWriter, expectedRevision: 1)) {
            XCTAssertEqual($0 as? AskConversationRepositoryError, .missing)
        }
        XCTAssertNil(try repository.fetch(id: original.id))
    }

    func testRunLeaseBlocksCompetingWritesAndRequiresOwnerToken() throws {
        let conversation = try repository.create(AskConversation())
        let token = UUID()
        let otherToken = UUID()
        let until = Date().addingTimeInterval(30)
        XCTAssertTrue(
            try repository.acquireRun(
                id: conversation.id, expectedRevision: 0, token: token, leaseUntil: until
            ))
        XCTAssertFalse(
            try repository.acquireRun(
                id: conversation.id, expectedRevision: 0, token: otherToken, leaseUntil: until
            ))
        XCTAssertThrowsError(try repository.save(conversation, expectedRevision: 0)) {
            XCTAssertEqual($0 as? AskConversationRepositoryError, .runInProgress)
        }
        XCTAssertThrowsError(try repository.save(conversation, expectedRevision: 0, runToken: otherToken)) {
            XCTAssertEqual($0 as? AskConversationRepositoryError, .runLeaseLost)
        }

        var runWrite = conversation
        runWrite.messages = [
            AskMessage(
                sectionID: try XCTUnwrap(conversation.activeSection?.id),
                role: .assistant, content: "Done"
            )
        ]
        let saved = try repository.save(runWrite, expectedRevision: 0, runToken: token)
        XCTAssertEqual(saved.revision, 1)
        XCTAssertFalse(try repository.releaseRun(id: conversation.id, token: otherToken))
        XCTAssertTrue(
            try repository.renewRun(
                id: conversation.id, token: token, leaseUntil: Date().addingTimeInterval(30)
            ))
        XCTAssertTrue(try repository.releaseRun(id: conversation.id, token: token))
        XCTAssertFalse(
            try repository.renewRun(
                id: conversation.id, token: token, leaseUntil: Date().addingTimeInterval(30)
            ))
    }

    func testDeletingSourceDoesNotCascadeConversation() throws {
        let transcription = Transcription(
            fileName: "Meeting", rawTranscript: "A decision", status: .completed,
            sourceType: .meeting
        )
        let transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        try transcriptions.save(transcription)
        let conversation = try repository.create(
            AskConversation(
                sections: [AskContextSection(sourceIDs: [transcription.id])]
            ))

        _ = try transcriptions.delete(id: transcription.id)
        XCTAssertEqual(try repository.fetch(id: conversation.id)?.activeSection?.sourceIDs, [transcription.id])
    }

    func testTerminalSaveRejectsEditedOrDeletedSourceAtomically() throws {
        var source = Transcription(
            fileName: "Planning", rawTranscript: "Launch in June.",
            status: .completed, sourceType: .meeting
        )
        let transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        try transcriptions.save(source)
        let sourceService = AskSourceService(dbQueue: manager.dbQueue)
        let receipt = try XCTUnwrap(sourceService.snapshot(sourceIDs: [source.id]).first)
        let revisions = [source.id: receipt.revision]
        var conversation = try repository.create(
            AskConversation(
                sections: [AskContextSection(sourceIDs: [source.id])]
            ))
        let token = UUID()
        XCTAssertTrue(
            try repository.acquireRun(
                id: conversation.id, expectedRevision: 0, token: token,
                leaseUntil: Date().addingTimeInterval(30)
            ))
        conversation.messages = [
            AskMessage(
                sectionID: try XCTUnwrap(conversation.activeSection?.id),
                role: .assistant, content: "June", sourceRevisions: revisions
            )
        ]

        source.rawTranscript = "Launch in July."
        try transcriptions.save(source)
        XCTAssertThrowsError(
            try repository.save(
                conversation, expectedRevision: 0, runToken: token, sourceRevisions: revisions
            )
        ) {
            XCTAssertEqual($0 as? AskSourceError, .stale)
        }
        XCTAssertEqual(try repository.fetch(id: conversation.id)?.revision, 0)

        _ = try transcriptions.delete(id: source.id)
        XCTAssertThrowsError(
            try repository.save(
                conversation, expectedRevision: 0, runToken: token, sourceRevisions: revisions
            )
        ) {
            XCTAssertEqual($0 as? AskSourceError, .unavailable)
        }
        XCTAssertEqual(try repository.fetch(id: conversation.id)?.messages.count, 0)
    }

    func testIncompleteAssistantAndProviderReceiptSurviveReopen() throws {
        let provider = AskProviderDisclosure(
            id: "configured-model", name: "Local model", model: "fixture",
            endpoint: "On this Mac", requiresRemoteConsent: false
        )
        var conversation = try repository.create(AskConversation())
        let assistantID = UUID()
        conversation.messages = [
            AskMessage(
                id: assistantID,
                sectionID: try XCTUnwrap(conversation.activeSection?.id),
                role: .assistant,
                status: .incomplete,
                content: "",
                failureReason: "The answer was interrupted.",
                provider: provider
            )
        ]
        conversation = try repository.save(conversation, expectedRevision: 0)

        let reopened = try XCTUnwrap(repository.fetch(id: conversation.id))
        XCTAssertEqual(reopened.messages.first?.id, assistantID)
        XCTAssertEqual(reopened.messages.first?.status, .incomplete)
        XCTAssertEqual(reopened.messages.first?.provider, provider)
    }
}
