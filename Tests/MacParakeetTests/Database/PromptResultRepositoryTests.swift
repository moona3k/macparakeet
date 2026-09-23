import XCTest
@testable import MacParakeetCore

final class PromptResultRepositoryTests: XCTestCase {
    var manager: DatabaseManager!
    var repo: PromptResultRepository!
    var transcriptionRepo: TranscriptionRepository!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = PromptResultRepository(dbQueue: manager.dbQueue)
        transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
    }

    private func makeTranscription() throws -> Transcription {
        let transcription = Transcription(fileName: "test.mp3", status: .completed)
        try transcriptionRepo.save(transcription)
        return transcription
    }

    func testLegacyProtocolConformerRefusesUnsafeReplacement() {
        let legacy: any PromptResultRepositoryProtocol = LegacyPromptResultRepository()
        let result = PromptResult(
            transcriptionId: UUID(),
            promptName: "Summary",
            promptContent: "Summarize.",
            content: "Replacement"
        )

        XCTAssertThrowsError(
            try legacy.replaceIfUnchanged(
                result,
                deletingExistingID: UUID(),
                expectedContent: "Original",
                expectedContentEditedAt: nil
            )
        ) { error in
            XCTAssertEqual(error as? PromptResultRepositoryError, .conditionalReplacementUnavailable)
        }
    }

    func testSaveAndFetchAllOrdersNewestFirst() throws {
        let transcription = try makeTranscription()
        let older = PromptResult(
            transcriptionId: transcription.id,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Older",
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Action Items",
            promptContent: "Action items only.",
            content: "Newer",
            createdAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        try repo.save(older)
        try repo.save(newer)

        let fetched = try repo.fetchAll(transcriptionId: transcription.id)
        XCTAssertEqual(fetched.map(\.content), ["Newer", "Older"])
    }

    func testInvalidReceiptCannotSaveOrReplacePreviousResult() throws {
        let transcription = try makeTranscription()
        let original = PromptResult(
            transcriptionId: transcription.id, promptName: "Summary",
            promptContent: "Summarize", content: "Original output",
            inferenceSettingsSnapshot: PromptInferenceSettings(temperature: 0.2)
        )
        try repo.save(original)
        let invalid = PromptResult(
            transcriptionId: transcription.id, promptName: "Replacement",
            promptContent: "Summarize", content: "Do not save",
            inferenceSettingsSnapshot: PromptInferenceSettings(maxTokens: -1)
        )
        XCTAssertThrowsError(try repo.save(invalid)) { error in
            XCTAssertEqual(
                error as? PromptInferenceSettings.ValidationError,
                .outOfRange(field: .maxTokens, minimum: 1, maximum: 131_072)
            )
        }
        XCTAssertThrowsError(try repo.replace(invalid, deletingExistingID: original.id))
        let saved = try repo.fetchAll(transcriptionId: transcription.id)
        XCTAssertEqual(saved.map(\.id), [original.id])
        XCTAssertEqual(saved.first?.content, original.content)
        XCTAssertEqual(saved.first?.inferenceSettingsSnapshot, original.inferenceSettingsSnapshot)
    }

    func testReplaceIfUnchangedPreservesEditedOriginalAndDoesNotInsertOnMismatch() throws {
        let transcription = try makeTranscription()
        let editDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Summary",
            promptContent: "Summarize",
            content: "User's saved edit",
            contentEditedAt: editDate
        )
        try repo.save(original)
        let replacement = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Regenerated summary",
            promptContent: "Summarize",
            content: "Regenerated output"
        )

        let didReplace = try repo.replaceIfUnchanged(
            replacement,
            deletingExistingID: original.id,
            expectedContent: "Original output",
            expectedContentEditedAt: nil
        )

        XCTAssertFalse(didReplace)
        let saved = try repo.fetchAll(transcriptionId: transcription.id)
        XCTAssertEqual(saved.map(\.id), [original.id])
        XCTAssertEqual(saved.first?.content, "User's saved edit")
        XCTAssertEqual(saved.first?.contentEditedAt, editDate)
    }

    func testReplaceIfUnchangedAtomicallyReplacesAnAlreadyEditedBaseline() throws {
        let transcription = try makeTranscription()
        let editDate = Date(timeIntervalSince1970: 1_700_000_000)
        let original = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Summary",
            promptContent: "Summarize",
            content: "User's saved edit",
            contentEditedAt: editDate
        )
        try repo.save(original)
        let replacement = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Regenerated summary",
            promptContent: "Summarize",
            content: "Regenerated output"
        )

        let didReplace = try repo.replaceIfUnchanged(
            replacement,
            deletingExistingID: original.id,
            expectedContent: original.content,
            expectedContentEditedAt: editDate
        )

        XCTAssertTrue(didReplace)
        let saved = try repo.fetchAll(transcriptionId: transcription.id)
        XCTAssertEqual(saved.map(\.id), [replacement.id])
        XCTAssertEqual(saved.first?.content, "Regenerated output")
    }

    func testReplaceIfUnchangedRejectsCandidateForDifferentTranscription() throws {
        let transcription = try makeTranscription()
        let otherTranscription = try makeTranscription()
        let original = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Summary",
            promptContent: "Summarize",
            content: "Original output"
        )
        try repo.save(original)
        let replacement = PromptResult(
            transcriptionId: otherTranscription.id,
            promptName: "Regenerated summary",
            promptContent: "Summarize",
            content: "Regenerated output"
        )

        let didReplace = try repo.replaceIfUnchanged(
            replacement,
            deletingExistingID: original.id,
            expectedContent: original.content,
            expectedContentEditedAt: original.contentEditedAt
        )

        XCTAssertFalse(didReplace)
        XCTAssertEqual(try repo.fetchAll(transcriptionId: transcription.id).map(\.id), [original.id])
        XCTAssertTrue(try repo.fetchAll(transcriptionId: otherTranscription.id).isEmpty)
    }

    func testPromptExecutionProvenanceRoundTrips() throws {
        let transcription = try makeTranscription()
        let promptRepo = PromptRepository(dbQueue: manager.dbQueue)
        let prompt = Prompt(
            name: "Provenance \(UUID().uuidString)",
            content: "Summarize this.",
            modelOverride: "requested-model"
        )
        try promptRepo.save(prompt)
        let storedPrompt = try XCTUnwrap(promptRepo.fetch(id: prompt.id))
        let versionID = try XCTUnwrap(storedPrompt.activeVersionId)
        let result = PromptResult(
            transcriptionId: transcription.id,
            promptId: storedPrompt.id,
            promptVersionId: versionID,
            promptName: storedPrompt.name,
            promptContent: storedPrompt.content,
            content: "Summary",
            providerSnapshot: "openai",
            modelSnapshot: "gpt-test"
        )

        try repo.save(result)

        let fetched = try XCTUnwrap(repo.fetchAll(transcriptionId: transcription.id).first)
        XCTAssertEqual(fetched.promptId, storedPrompt.id)
        XCTAssertEqual(fetched.promptVersionId, versionID)
        XCTAssertEqual(fetched.providerSnapshot, "openai")
        XCTAssertEqual(fetched.modelSnapshot, "gpt-test")
    }

    func testOutputLanguagePolicySnapshotRoundTrips() throws {
        let transcription = try makeTranscription()
        let result = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Summary",
            promptContent: "Summarize this.",
            content: "Summary",
            outputLanguagePolicySnapshot: "follow-transcript"
        )
        try repo.save(result)

        let fetched = try XCTUnwrap(repo.fetchAll(transcriptionId: transcription.id).first)
        XCTAssertEqual(fetched.outputLanguagePolicySnapshot, "follow-transcript")
    }

    func testContentEditedAtRoundTripsWithoutChangingPromptSnapshots() throws {
        let transcription = try makeTranscription()
        let editedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let result = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Summary",
            promptContent: "Summarize this.",
            content: "User corrected typo",
            contentEditedAt: editedAt
        )
        try repo.save(result)

        let fetched = try XCTUnwrap(repo.fetchAll(transcriptionId: transcription.id).first)
        XCTAssertEqual(fetched.content, "User corrected typo")
        XCTAssertEqual(fetched.contentEditedAt, editedAt)
        XCTAssertEqual(fetched.promptContent, "Summarize this.")
        XCTAssertTrue(fetched.isContentUserEdited)
    }

    func testUpdateContentPreservesReceiptsAndNeverRecreatesReplacedResult() throws {
        let transcription = try makeTranscription()
        let original = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Summary",
            promptContent: "Summarize this.",
            content: "Original",
            providerSnapshot: "openai",
            outputLanguagePolicySnapshot: "follow-transcript",
            sourceCorrectionRevision: 2
        )
        try repo.save(original)
        let editedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let edited = try XCTUnwrap(
            repo.updateContent(
                id: original.id,
                expectedContent: "Original",
                content: "Corrected",
                editedAt: editedAt
            ))
        XCTAssertEqual(edited.content, "Corrected")
        XCTAssertEqual(edited.contentEditedAt, editedAt)
        XCTAssertEqual(edited.promptContent, original.promptContent)
        XCTAssertEqual(edited.providerSnapshot, original.providerSnapshot)
        XCTAssertEqual(edited.outputLanguagePolicySnapshot, original.outputLanguagePolicySnapshot)
        XCTAssertEqual(edited.sourceCorrectionRevision, original.sourceCorrectionRevision)
        XCTAssertNil(
            try repo.updateContent(
                id: original.id,
                expectedContent: "Original",
                content: "Stale draft",
                editedAt: editedAt
            ))

        _ = try repo.delete(id: original.id)
        XCTAssertNil(
            try repo.updateContent(
                id: original.id,
                expectedContent: "Corrected",
                content: "Resurrected",
                editedAt: editedAt
            ))
        XCTAssertTrue(try repo.fetchAll(transcriptionId: transcription.id).isEmpty)
    }

    func testInferenceSettingsSnapshotRoundTripAndDefaultNormalization() throws {
        let transcription = try makeTranscription()
        var result = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Configured Summary",
            promptContent: "Summarize this.",
            content: "Summary",
            inferenceSettingsSnapshot: PromptInferenceSettings(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .enabled,
                reasoningEffort: .medium
            )
        )
        try repo.save(result)
        XCTAssertEqual(
            try repo.fetchAll(transcriptionId: transcription.id).first?.inferenceSettingsSnapshot,
            result.inferenceSettingsSnapshot
        )

        result.inferenceSettingsSnapshot = PromptInferenceSettings()
        try repo.save(result)
        XCTAssertNil(
            try repo.fetchAll(transcriptionId: transcription.id).first?.inferenceSettingsSnapshot
        )
        let storedJSON = try manager.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT inferenceSettingsSnapshot FROM summaries WHERE id = ?",
                arguments: [result.id]
            )
        }
        XCTAssertNil(storedJSON)
    }

    func testMalformedInferenceSettingsSnapshotIsAVisibleFetchError() throws {
        let transcription = try makeTranscription()
        let result = PromptResult(
            transcriptionId: transcription.id,
            promptName: "Malformed Settings",
            promptContent: "Summarize this.",
            content: "Summary"
        )
        try repo.save(result)

        try manager.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE summaries SET inferenceSettingsSnapshot = ? WHERE id = ?",
                arguments: ["{not-json", result.id]
            )
        }

        XCTAssertThrowsError(try repo.fetchAll(transcriptionId: transcription.id))
    }

    func testMultiplePromptResultsPerTranscription() throws {
        let transcription = try makeTranscription()
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "General Summary",
                promptContent: Prompt.defaultPrompt.content,
                content: "One"
            )
        )
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "Action Items",
                promptContent: "Action items only.",
                content: "Two"
            )
        )

        XCTAssertEqual(try repo.fetchAll(transcriptionId: transcription.id).count, 2)
        XCTAssertEqual(try repo.count(transcriptionId: transcription.id), 2)
        XCTAssertEqual(try repo.counts(transcriptionIds: [transcription.id])[transcription.id], 2)
        XCTAssertTrue(try repo.hasPromptResults(transcriptionId: transcription.id))
    }

    func testDeleteSinglePromptResult() throws {
        let transcription = try makeTranscription()
        let promptResult = PromptResult(
            transcriptionId: transcription.id,
            promptName: "General Summary",
            promptContent: Prompt.defaultPrompt.content,
            content: "Delete me"
        )
        try repo.save(promptResult)

        XCTAssertTrue(try repo.delete(id: promptResult.id))
        XCTAssertTrue(try repo.fetchAll(transcriptionId: transcription.id).isEmpty)
    }

    func testDeleteAllForTranscription() throws {
        let transcription = try makeTranscription()
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "General Summary",
                promptContent: Prompt.defaultPrompt.content,
                content: "One"
            )
        )
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "Action Items",
                promptContent: "Action items only.",
                content: "Two"
            )
        )

        try repo.deleteAll(transcriptionId: transcription.id)

        XCTAssertFalse(try repo.hasPromptResults(transcriptionId: transcription.id))
    }

    func testCascadeDeleteOnTranscriptionRemoval() throws {
        let transcription = try makeTranscription()
        try repo.save(
            PromptResult(
                transcriptionId: transcription.id,
                promptName: "General Summary",
                promptContent: Prompt.defaultPrompt.content,
                content: "One"
            )
        )

        _ = try transcriptionRepo.delete(id: transcription.id)

        XCTAssertFalse(try repo.hasPromptResults(transcriptionId: transcription.id))
        XCTAssertEqual(try repo.count(transcriptionId: transcription.id), 0)
        XCTAssertEqual(try repo.counts(transcriptionIds: [transcription.id])[transcription.id] ?? 0, 0)
    }
}

private struct LegacyPromptResultRepository: PromptResultRepositoryProtocol {
    func save(_ promptResult: PromptResult) throws {}
    func updateContent(id: UUID, expectedContent: String, content: String, editedAt: Date) throws -> PromptResult? {
        nil
    }
    func fetchAll(transcriptionId: UUID) throws -> [PromptResult] { [] }
    func delete(id: UUID) throws -> Bool { false }
    func deleteAll(transcriptionId: UUID) throws {}
    func hasPromptResults(transcriptionId: UUID) throws -> Bool { false }
    func count(transcriptionId: UUID) throws -> Int { 0 }
}
