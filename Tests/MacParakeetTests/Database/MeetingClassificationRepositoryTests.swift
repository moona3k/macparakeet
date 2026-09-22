import GRDB
import XCTest
@testable import MacParakeetCore

final class MeetingClassificationRepositoryTests: XCTestCase {
    private var manager: DatabaseManager!
    private var transcriptionRepository: TranscriptionRepository!
    private var typeRepository: MeetingTypeRepository!
    private var labelRepository: MeetingLabelRepository!
    private var joinRepository: TranscriptionMeetingLabelRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        transcriptionRepository = TranscriptionRepository(dbQueue: manager.dbQueue)
        typeRepository = MeetingTypeRepository(dbQueue: manager.dbQueue)
        labelRepository = MeetingLabelRepository(dbQueue: manager.dbQueue)
        joinRepository = TranscriptionMeetingLabelRepository(dbQueue: manager.dbQueue)
    }

    func testTypesAndLabelsNormalizeSortAndArchive() throws {
        var customer = MeetingType(name: "  Customer  ", sortOrder: 2)
        let oneOnOne = MeetingType(name: "1:1", sortOrder: 1)
        try typeRepository.save(customer)
        try typeRepository.save(oneOnOne)

        XCTAssertEqual(try typeRepository.fetchAll().map(\.name), ["1:1", "Customer"])
        customer = try XCTUnwrap(typeRepository.fetch(id: customer.id))
        XCTAssertEqual(customer.name, "Customer")

        try typeRepository.setArchived(id: oneOnOne.id, isArchived: true)
        XCTAssertEqual(try typeRepository.fetchAll().map(\.name), ["Customer"])
        XCTAssertEqual(try typeRepository.fetchAll(includeArchived: true).count, 2)

        let decision = MeetingLabel(name: "  Decision  ", colorToken: " coral ")
        try labelRepository.save(decision)
        XCTAssertEqual(try labelRepository.fetch(id: decision.id)?.name, "Decision")
        XCTAssertEqual(try labelRepository.fetch(id: decision.id)?.colorToken, "coral")
    }

    func testJoinRepositoryReplacesLabelsAtomically() throws {
        let meeting = makeTranscription(fileName: "Weekly", sourceType: .meeting)
        try transcriptionRepository.save(meeting)
        let first = MeetingLabel(name: "First", sortOrder: 1)
        let second = MeetingLabel(name: "Second", sortOrder: 2)
        try labelRepository.save(first)
        try labelRepository.save(second)

        try joinRepository.replaceLabels(for: meeting.id, with: [first.id, second.id])
        XCTAssertEqual(try joinRepository.labels(for: meeting.id).map(\.name), ["First", "Second"])

        try joinRepository.replaceLabels(for: meeting.id, with: [second.id])
        XCTAssertEqual(try joinRepository.labelIDs(for: meeting.id), [second.id])
    }

    func testClassificationServiceUpdatesTypeAndLabelsTogether() async throws {
        let meeting = makeTranscription(fileName: "Customer sync", sourceType: .meeting)
        try transcriptionRepository.save(meeting)
        let customer = MeetingType(name: "Customer")
        let important = MeetingLabel(name: "Important")
        try typeRepository.save(customer)
        try labelRepository.save(important)
        let service = MeetingClassificationService(dbQueue: manager.dbQueue)

        try await service.update(
            meetingTypeId: customer.id,
            labelIds: [important.id],
            for: meeting.id
        )

        let classification = try service.classification(for: meeting.id)
        XCTAssertEqual(classification.meetingType?.id, customer.id)
        XCTAssertEqual(classification.meetingType?.name, "Customer")
        XCTAssertEqual(classification.labels.map(\.id), [important.id])
        XCTAssertEqual(classification.labels.map(\.name), ["Important"])
        XCTAssertEqual(try transcriptionRepository.fetch(id: meeting.id)?.meetingTypeId, customer.id)
    }

    func testClassificationRefreshesArtifactAfterCommittedMutation() async throws {
        let meeting = makeTranscription(fileName: "Customer sync", sourceType: .meeting)
        try transcriptionRepository.save(meeting)
        let customer = MeetingType(name: "Customer")
        try typeRepository.save(customer)
        let refresher = RecordingClassificationArtifactRefresher()
        let service = MeetingClassificationService(
            dbQueue: manager.dbQueue,
            artifactRefresher: refresher
        )

        try await service.setMeetingType(customer.id, for: meeting.id)

        let refreshed = await refresher.transcriptions
        XCTAssertEqual(refreshed.map(\.id), [meeting.id])
        XCTAssertEqual(refreshed.first?.meetingTypeId, customer.id)
    }

    func testArtifactClassificationRefreshUsesCurrentMeetingInsteadOfStaleReceipt() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("classification-artifact-current-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = artifactMeeting(folder: folder)
        try transcriptionRepository.save(meeting)
        let reader = SpeakerAttributionReadService(dbQueue: manager.dbQueue)
        let input = try XCTUnwrap(reader.resolve(transcriptionId: meeting.id))
        _ = try await SpeakerCorrectionService(dbQueue: manager.dbQueue).apply(
            transcriptionId: meeting.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: input.attribution.fingerprint,
            expectedRevision: 0
        )
        XCTAssertNotNil(try transcriptionRepository.updateFileName(id: meeting.id, fileName: "Current title"))
        XCTAssertTrue(try transcriptionRepository.updateUserNotes(id: meeting.id, userNotes: "Current notes"))
        let label = MeetingLabel(name: "Customer")
        let refresher = MeetingArtifactClassificationRefresher(
            promptResultRepository: PromptResultRepository(dbQueue: manager.dbQueue),
            speakerAttributionReader: reader
        )

        try await refresher.refreshArtifact(
            for: meeting,
            classification: MeetingClassification(meetingType: nil, labels: [label])
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent(MeetingArtifactStore.markdownFileName),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("Current title"))
        XCTAssertTrue(markdown.contains("Current notes"))
        XCTAssertTrue(markdown.contains("Alice"))
        XCTAssertTrue(markdown.contains("Customer"))
        XCTAssertFalse(markdown.contains("Original notes"))
        XCTAssertFalse(markdown.contains("Speaker 1"))
    }

    func testArtifactClassificationRefreshDoesNotRecreateDeletedMeeting() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("classification-artifact-deleted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let meeting = artifactMeeting(folder: folder)
        try transcriptionRepository.save(meeting)
        XCTAssertTrue(try transcriptionRepository.delete(id: meeting.id))
        let refresher = MeetingArtifactClassificationRefresher(
            promptResultRepository: PromptResultRepository(dbQueue: manager.dbQueue),
            speakerAttributionReader: SpeakerAttributionReadService(dbQueue: manager.dbQueue)
        )

        try await refresher.refreshArtifact(
            for: meeting,
            classification: MeetingClassification(meetingType: nil, labels: [])
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    private func artifactMeeting(folder: URL) -> Transcription {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 200, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "world.", startMs: 220, endMs: 500, confidence: 1, speakerId: "S1"),
        ]
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        return Transcription(
            fileName: "Original title",
            meetingArtifactFolderPath: folder.path,
            rawTranscript: "Hello world.",
            wordTimestamps: words,
            speakerCount: 1,
            speakers: speakers,
            transcriptSegments: TranscriptSegmenter.materializeSegments(words: words, speakers: speakers),
            status: .completed,
            sourceType: .meeting,
            userNotes: "Original notes"
        )
    }

    func testArtifactRefreshFailureDoesNotReportCommittedMutationAsFailed() async throws {
        let meeting = makeTranscription(fileName: "Customer sync", sourceType: .meeting)
        try transcriptionRepository.save(meeting)
        let customer = MeetingType(name: "Customer")
        try typeRepository.save(customer)
        let service = MeetingClassificationService(
            dbQueue: manager.dbQueue,
            artifactRefresher: FailingClassificationArtifactRefresher()
        )

        try await service.setMeetingType(customer.id, for: meeting.id)

        XCTAssertEqual(try service.classification(for: meeting.id).meetingType?.id, customer.id)
    }

    func testExistingArchivedAssignmentsCanBeRetainedWhileIndependentValuesChange() async throws {
        let meeting = makeTranscription(fileName: "Legacy", sourceType: .meeting)
        try transcriptionRepository.save(meeting)
        let archivedType = MeetingType(name: "Old type")
        let archivedLabel = MeetingLabel(name: "Old label")
        let currentLabel = MeetingLabel(name: "Current label")
        try typeRepository.save(archivedType)
        try labelRepository.save(archivedLabel)
        try labelRepository.save(currentLabel)
        let service = MeetingClassificationService(dbQueue: manager.dbQueue)
        try await service.update(
            meetingTypeId: archivedType.id,
            labelIds: [archivedLabel.id],
            for: meeting.id
        )
        try typeRepository.setArchived(id: archivedType.id, isArchived: true)
        try labelRepository.setArchived(id: archivedLabel.id, isArchived: true)

        try await service.update(
            meetingTypeId: archivedType.id,
            labelIds: [archivedLabel.id, currentLabel.id],
            for: meeting.id
        )

        let classification = try service.classification(for: meeting.id)
        XCTAssertEqual(classification.meetingType?.id, archivedType.id)
        XCTAssertEqual(Set(classification.labels.map(\.id)), [archivedLabel.id, currentLabel.id])
    }

    func testHardDeleteRefusesValuesReferencedByMeetingsOrPolicies() async throws {
        let meeting = makeTranscription(fileName: "Customer", sourceType: .meeting)
        let type = MeetingType(name: "Customer")
        let label = MeetingLabel(name: "Important")
        try transcriptionRepository.save(meeting)
        try typeRepository.save(type)
        try labelRepository.save(label)
        try await MeetingClassificationService(dbQueue: manager.dbQueue).update(
            meetingTypeId: type.id,
            labelIds: [label.id],
            for: meeting.id
        )

        XCTAssertFalse(try typeRepository.delete(id: type.id))
        XCTAssertFalse(try labelRepository.delete(id: label.id))
        XCTAssertNotNil(try typeRepository.fetch(id: type.id))
        XCTAssertNotNil(try labelRepository.fetch(id: label.id))
    }

    func testCompletionSavePreservesTypeChangedAfterStaleMeetingWasLoaded() throws {
        let meeting = makeTranscription(fileName: "Concurrent", sourceType: .meeting)
        let type = MeetingType(name: "Customer")
        try transcriptionRepository.save(meeting)
        try typeRepository.save(type)
        var staleProcessingSnapshot = try XCTUnwrap(transcriptionRepository.fetch(id: meeting.id))

        try transcriptionRepository.updateMeetingType(id: meeting.id, meetingTypeId: type.id)
        staleProcessingSnapshot.status = .completed
        staleProcessingSnapshot.rawTranscript = "Finished after the classification changed."
        try transcriptionRepository.savePreservingMeetingClassification(staleProcessingSnapshot)

        let completed = try XCTUnwrap(transcriptionRepository.fetch(id: meeting.id))
        XCTAssertEqual(completed.meetingTypeId, type.id)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertEqual(completed.rawTranscript, staleProcessingSnapshot.rawTranscript)
    }

    func testClassificationLabelsAnyTranscriptionSourceAndRejectsArchivedValues() async throws {
        let file = makeTranscription(fileName: "audio.m4a", sourceType: .file)
        try transcriptionRepository.save(file)
        let archivedType = MeetingType(name: "Old", isArchived: true)
        let label = MeetingLabel(name: "Keep")
        try typeRepository.save(archivedType)
        try labelRepository.save(label)
        let service = MeetingClassificationService(dbQueue: manager.dbQueue)

        try await service.replaceLabels([label.id], for: file.id)
        XCTAssertEqual(try service.classification(for: file.id).labels.map(\.id), [label.id])

        do {
            try await service.setMeetingType(archivedType.id, for: file.id)
            XCTFail("Expected the archived type to be rejected")
        } catch let error as MeetingClassificationServiceError {
            XCTAssertEqual(error, .meetingTypeUnavailable(archivedType.id))
        }
        XCTAssertNil(try transcriptionRepository.fetch(id: file.id)?.meetingTypeId)
    }

    func testLibraryFiltersTypesLabelsAndUnclassifiedBeforePagination() async throws {
        let customer = MeetingType(name: "Customer")
        let internalType = MeetingType(name: "Internal")
        let important = MeetingLabel(name: "Important")
        try typeRepository.save(customer)
        try typeRepository.save(internalType)
        try labelRepository.save(important)

        let first = makeTranscription(
            fileName: "First", sourceType: .meeting, createdAt: Date(timeIntervalSince1970: 3))
        let second = makeTranscription(
            fileName: "Second", sourceType: .meeting, createdAt: Date(timeIntervalSince1970: 2))
        let third = makeTranscription(
            fileName: "Third", sourceType: .meeting, createdAt: Date(timeIntervalSince1970: 1))
        try transcriptionRepository.save(first)
        try transcriptionRepository.save(second)
        try transcriptionRepository.save(third)
        let service = MeetingClassificationService(dbQueue: manager.dbQueue)
        try await service.update(meetingTypeId: customer.id, labelIds: [important.id], for: first.id)
        try await service.update(meetingTypeId: internalType.id, labelIds: [], for: second.id)

        let customerPage = try transcriptionRepository.fetchLibraryPage(
            query: TranscriptionLibraryQuery(
                sourceType: .meeting,
                meetingTypeIDs: [customer.id],
                limit: 1
            ))
        XCTAssertEqual(customerPage.items.map(\.id), [first.id])
        XCTAssertFalse(customerPage.hasMore)

        let labelPage = try transcriptionRepository.fetchLibraryPage(
            query: TranscriptionLibraryQuery(
                sourceType: .meeting,
                meetingLabelIDs: [important.id],
                limit: 1
            ))
        XCTAssertEqual(labelPage.items.map(\.id), [first.id])

        let unclassifiedPage = try transcriptionRepository.fetchLibraryPage(
            query: TranscriptionLibraryQuery(
                sourceType: .meeting,
                unclassifiedMeetingsOnly: true,
                limit: 1
            ))
        XCTAssertEqual(unclassifiedPage.items.map(\.id), [third.id])
    }

    private func makeTranscription(
        fileName: String,
        sourceType: Transcription.SourceType,
        createdAt: Date = Date()
    ) -> Transcription {
        Transcription(
            createdAt: createdAt,
            fileName: fileName,
            status: .completed,
            sourceType: sourceType
        )
    }
}

private actor RecordingClassificationArtifactRefresher: MeetingClassificationArtifactRefreshing {
    private(set) var transcriptions: [Transcription] = []

    func refreshArtifact(
        for transcription: Transcription,
        classification: MeetingClassification
    ) async throws {
        transcriptions.append(transcription)
    }
}

private struct FailingClassificationArtifactRefresher: MeetingClassificationArtifactRefreshing {
    struct ExpectedFailure: Error {}

    func refreshArtifact(
        for transcription: Transcription,
        classification: MeetingClassification
    ) async throws {
        throw ExpectedFailure()
    }
}
