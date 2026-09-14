import GRDB
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private final class StubSpeakerAttributionReader: SpeakerAttributionReading, @unchecked Sendable {
    private let lock = NSLock()
    private let projection: SpeakerAttributionProjection
    private var storedRequestedIDs: [UUID] = []
    var requestedIDs: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequestedIDs
    }

    init(projection: SpeakerAttributionProjection) {
        self.projection = projection
    }

    func resolve(transcriptionId: UUID) throws -> SpeakerAttributionProjection? {
        lock.lock()
        storedRequestedIDs.append(transcriptionId)
        lock.unlock()
        return projection
    }

    func resolve(transcription: Transcription) throws -> SpeakerAttributionProjection {
        lock.lock()
        storedRequestedIDs.append(transcription.id)
        lock.unlock()
        return projection
    }
}

/// Holds the first read off the main actor until a later snapshot has loaded.
private final class DelayedSpeakerAttributionReader: SpeakerAttributionReading, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var readCount = 0
    let firstReadReturned: XCTestExpectation
    let storedProjection: SpeakerAttributionProjection?

    init(firstReadReturned: XCTestExpectation, projection: SpeakerAttributionProjection? = nil) {
        self.firstReadReturned = firstReadReturned
        self.storedProjection = projection
    }

    func resolve(transcriptionId: UUID) throws -> SpeakerAttributionProjection? {
        XCTFail("Resolve the captured snapshot, not a potentially different database version")
        return nil
    }

    func resolve(transcription: Transcription) throws -> SpeakerAttributionProjection {
        lock.lock()
        readCount += 1
        let isFirst = readCount == 1
        lock.unlock()
        if isFirst {
            started.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        let projection = storedProjection ?? SpeakerAttributionProjection(
            automaticTranscription: transcription,
            attribution: SpeakerAttributionResolver.resolve(transcription: transcription),
            correctionsApplied: false
        )
        if isFirst { firstReadReturned.fulfill() }
        return projection
    }
}

private actor StubSpeakerCorrectionService: SpeakerCorrectionServicing {
    struct ApplyCall: Sendable {
        let transcriptionID: UUID
        let command: SpeakerCorrectionCommand
        let fingerprint: TranscriptFingerprint
        let revision: Int
    }

    private(set) var applyCalls: [ApplyCall] = []
    private(set) var undoCount = 0
    private(set) var redoCount = 0
    let result: SpeakerCorrectionResult
    let applyError: SpeakerCorrectionServiceError?

    init(result: SpeakerCorrectionResult, applyError: SpeakerCorrectionServiceError? = nil) {
        self.result = result
        self.applyError = applyError
    }

    func apply(
        transcriptionId: UUID,
        command: SpeakerCorrectionCommand,
        expectedFingerprint: TranscriptFingerprint,
        expectedRevision: Int
    ) async throws -> SpeakerCorrectionResult {
        if let applyError { throw applyError }
        applyCalls.append(
            ApplyCall(
                transcriptionID: transcriptionId,
                command: command,
                fingerprint: expectedFingerprint,
                revision: expectedRevision
            )
        )
        return result
    }

    func undo(
        transcriptionId _: UUID,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult {
        undoCount += 1
        return result
    }

    func redo(
        transcriptionId _: UUID,
        expectedFingerprint _: TranscriptFingerprint,
        expectedRevision _: Int
    ) async throws -> SpeakerCorrectionResult {
        redoCount += 1
        return result
    }
}

@MainActor
final class TranscriptionSpeakerCorrectionViewModelTests: XCTestCase {
    func testLoadingPublishesEffectiveAttributionAndHistoryAvailability() async throws {
        let transcription = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let reader = StubSpeakerAttributionReader(
            projection: SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: attribution,
                correctionsApplied: true,
                canUndo: true,
                canRedo: true
            )
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader
        )

        viewModel.currentTranscription = transcription

        try await waitUntil { viewModel.speakerAttribution != nil }
        XCTAssertEqual(reader.requestedIDs, [transcription.id])
        XCTAssertTrue(viewModel.speakerCorrectionsApplied)
        XCTAssertTrue(viewModel.canUndoSpeakerCorrection)
        XCTAssertTrue(viewModel.canRedoSpeakerCorrection)
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.wordTimestamps, attribution.words)
    }

    func testApplyingCorrectionUsesLoadedOptimisticVersionAndPublishesResult() async throws {
        let transcription = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let reader = StubSpeakerAttributionReader(
            projection: SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: attribution,
                correctionsApplied: false
            )
        )
        let service = StubSpeakerCorrectionService(
            result: SpeakerCorrectionResult(
                attribution: attribution,
                revision: 1,
                canUndo: true,
                canRedo: false
            )
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader,
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { viewModel.speakerAttribution != nil }

        let command = SpeakerCorrectionCommand.rename(speakerID: "S1", label: "Alice")
        let persisted = await viewModel.applySpeakerCorrectionAndWait(command)

        XCTAssertTrue(persisted)
        let calls = await service.applyCalls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(call.transcriptionID, transcription.id)
        XCTAssertEqual(call.command, command)
        XCTAssertEqual(call.fingerprint, attribution.fingerprint)
        XCTAssertEqual(call.revision, attribution.correctionRevision)
        XCTAssertTrue(viewModel.speakerCorrectionsApplied)
        XCTAssertFalse(viewModel.canRedoSpeakerCorrection)
    }

    func testUndoPublishesRedoAvailability() async throws {
        let transcription = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let reader = StubSpeakerAttributionReader(
            projection: SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: attribution,
                correctionsApplied: true,
                canUndo: true
            )
        )
        let service = StubSpeakerCorrectionService(
            result: SpeakerCorrectionResult(
                attribution: attribution,
                revision: 2,
                canUndo: false,
                canRedo: true
            )
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader,
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { viewModel.speakerAttribution != nil }

        viewModel.undoSpeakerCorrection()

        try await waitUntil { !viewModel.isApplyingSpeakerCorrection && viewModel.canRedoSpeakerCorrection }
        let undoCount = await service.undoCount
        XCTAssertEqual(undoCount, 1)
        XCTAssertFalse(viewModel.canUndoSpeakerCorrection)
        XCTAssertFalse(viewModel.speakerCorrectionsApplied)
    }

    func testConflictReloadsAttributionAndReportsActionableError() async throws {
        let transcription = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: transcription)
        let reader = StubSpeakerAttributionReader(
            projection: SpeakerAttributionProjection(
                automaticTranscription: transcription,
                attribution: attribution,
                correctionsApplied: false
            )
        )
        let service = StubSpeakerCorrectionService(
            result: SpeakerCorrectionResult(
                attribution: attribution,
                revision: 0,
                canUndo: false,
                canRedo: false
            ),
            applyError: SpeakerCorrectionServiceError.conflict
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader,
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { reader.requestedIDs.count == 1 && viewModel.speakerAttribution != nil }

        let persisted = await viewModel.applySpeakerCorrectionAndWait(
            .rename(speakerID: "S1", label: "Alice")
        )

        XCTAssertFalse(persisted)
        try await waitUntil { reader.requestedIDs.count == 2 && !viewModel.isApplyingSpeakerCorrection }
        XCTAssertEqual(
            viewModel.errorMessage,
            "Speaker changes were updated elsewhere. Review and try again."
        )
    }

    func testQueuedMeetingCompletionReloadsAttributionForSameID() async throws {
        let manager = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
        let completed = makeTranscription()
        var processing = completed
        processing.status = .processing
        processing.wordTimestamps = nil
        processing.speakers = nil
        processing.diarizationSegments = nil
        processing.transcriptSegments = nil
        try repository.save(processing)
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: repository,
            speakerAttributionReader: SpeakerAttributionReadService(dbQueue: manager.dbQueue)
        )
        viewModel.currentTranscription = processing
        try await waitUntil { viewModel.speakerAttribution != nil }
        XCTAssertEqual(viewModel.speakerAttribution?.words, [])

        try repository.save(completed)
        viewModel.presentCompletedTranscription(
            completed, autoSave: false, runAutoPrompts: false
        )

        // Old empty attribution must not mask the completed row while its read is pending.
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.wordTimestamps, completed.wordTimestamps)
        try await waitUntil { viewModel.speakerAttribution?.words == completed.wordTimestamps }
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.speakers, completed.speakers)
    }

    func testSameIDReplacementRejectsAnOlderAsyncAttributionRead() async throws {
        let returned = expectation(description: "Older attribution read returned")
        let reader = DelayedSpeakerAttributionReader(firstReadReturned: returned)
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader
        )
        let original = makeTranscription()
        viewModel.currentTranscription = original
        // The gate belongs to a detached reader. Never block MainActor waiting for it.
        let started = await Task.detached {
            reader.started.wait(timeout: .now() + 2) == .success
        }.value
        XCTAssertTrue(started)
        defer { reader.release.signal() }
        var replacement = original
        replacement.wordTimestamps?[0].word = "updated"
        replacement.speakers?[0].label = "Alice"
        viewModel.currentTranscription = replacement
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.wordTimestamps, replacement.wordTimestamps)
        try await waitUntil { viewModel.speakerAttribution?.words == replacement.wordTimestamps }

        reader.release.signal()
        await fulfillment(of: [returned], timeout: 2)
        // Allow the released Task's MainActor continuation to attempt publication.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(viewModel.speakerAttribution?.words, replacement.wordTimestamps)
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.speakers, replacement.speakers)
    }

    func testRenameWhileAttributionLoadsPreservesBaselineAndCanRetryWithUndo() async throws {
        let manager = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
        let original = makeTranscription()
        try repository.save(original)
        let returned = expectation(description: "Attribution read returned")
        let reader = DelayedSpeakerAttributionReader(firstReadReturned: returned)
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: repository,
            speakerAttributionReader: reader,
            speakerCorrectionService: SpeakerCorrectionService(dbQueue: manager.dbQueue)
        )
        viewModel.currentTranscription = original
        let started = await Task.detached {
            reader.started.wait(timeout: .now() + 2) == .success
        }.value
        XCTAssertTrue(started)
        defer { reader.release.signal() }
        XCTAssertNil(viewModel.speakerAttribution)

        XCTAssertFalse(
            viewModel.renameSpeaker(id: "S1", to: "Alice"),
            "A refused rename tells the editor to keep its draft"
        )

        XCTAssertEqual(viewModel.currentTranscription?.speakers, original.speakers)
        XCTAssertEqual(viewModel.currentTranscription?.transcriptSegments, original.transcriptSegments)
        XCTAssertEqual(viewModel.transcriptions.first?.speakers, original.speakers)
        XCTAssertFalse(viewModel.isApplyingSpeakerCorrection)
        XCTAssertEqual(
            viewModel.errorMessage,
            "Speaker corrections are loading. Try the rename again in a moment."
        )
        reader.release.signal()
        await fulfillment(of: [returned], timeout: 2)
        try await waitUntil { viewModel.speakerAttribution != nil }
        XCTAssertEqual(try repository.fetch(id: original.id)?.speakers, original.speakers)

        XCTAssertTrue(viewModel.renameSpeaker(id: "S1", to: "Alice"))

        try await waitUntil { viewModel.canUndoSpeakerCorrection && !viewModel.isApplyingSpeakerCorrection }
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.speakers?.first?.label, "Alice")
        XCTAssertEqual(try repository.fetch(id: original.id)?.speakers, original.speakers)
        XCTAssertEqual(try repository.fetch(id: original.id)?.transcriptSegments, original.transcriptSegments)

        viewModel.undoSpeakerCorrection()

        try await waitUntil { viewModel.canRedoSpeakerCorrection && !viewModel.isApplyingSpeakerCorrection }
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.speakers, original.speakers)
    }

    func testSameIDRefreshReloadsChangedSpeakerCorrections() async throws {
        let manager = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
        let transcription = makeTranscription()
        try repository.save(transcription)
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: repository,
            speakerAttributionReader: SpeakerAttributionReadService(dbQueue: manager.dbQueue)
        )
        viewModel.currentTranscription = transcription
        try await waitUntil { viewModel.speakerAttribution != nil }
        _ = try await SpeakerCorrectionService(dbQueue: manager.dbQueue).apply(
            transcriptionId: transcription.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: SpeakerAttributionResolver.fingerprint(for: transcription),
            expectedRevision: 0
        )

        viewModel.refreshCurrentTranscriptionIfMatching(id: transcription.id)

        try await waitUntil { viewModel.speakerAttribution?.correctionRevision == 1 }
        XCTAssertEqual(viewModel.effectiveCurrentTranscription?.speakers?.first?.label, "Alice")
    }

    func testSpeakerOutputWaitsForPersistedCorrections() async throws {
        let original = makeTranscription()
        var corrected = original
        corrected.speakers = [.init(id: "S1", label: "Alice")]
        let returned = expectation(description: "Attribution returned")
        let reader = DelayedSpeakerAttributionReader(
            firstReadReturned: returned,
            projection: SpeakerAttributionProjection(
                automaticTranscription: original,
                attribution: SpeakerAttributionResolver.resolve(transcription: corrected),
                correctionsApplied: true
            )
        )
        defer { reader.release.signal() }
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader
        )
        viewModel.currentTranscription = original
        let didStart = await Task.detached { reader.started.wait(timeout: .now() + 2) == .success }.value
        XCTAssertTrue(didStart)
        let outputStarted = expectation(description: "Output requested")
        var outputFinished = false
        let output = Task { @MainActor in
            outputStarted.fulfill()
            let result = await viewModel.currentTranscriptionForSpeakerOutput()
            outputFinished = true
            return result
        }
        await fulfillment(of: [outputStarted], timeout: 2)
        XCTAssertFalse(outputFinished, "Do not emit the automatic display fallback")
        reader.release.signal()
        await fulfillment(of: [returned], timeout: 2)

        let prepared = await output.value
        let source = try XCTUnwrap(prepared)
        XCTAssertEqual(source.speakers?.first?.label, "Alice")
        XCTAssertEqual(viewModel.currentTranscription?.speakers, original.speakers)
        XCTAssertTrue(MeetingMarkdownRenderer().renderForClipboard(transcription: source).contains("Alice"))
        XCTAssertTrue(ExportService().formatMarkdown(transcription: source).contains("Alice"))
    }

    func testSpeakerOutputRejectsSelectionChangedDuringAttributionRead() async throws {
        let original = makeTranscription()
        let returned = expectation(description: "Old attribution returned")
        let reader = DelayedSpeakerAttributionReader(firstReadReturned: returned)
        defer { reader.release.signal() }
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerAttributionReader: reader
        )
        viewModel.currentTranscription = original
        let didStart = await Task.detached { reader.started.wait(timeout: .now() + 2) == .success }.value
        XCTAssertTrue(didStart)
        let outputStarted = expectation(description: "Output requested")
        let output = Task { @MainActor in
            outputStarted.fulfill()
            return await viewModel.currentTranscriptionForSpeakerOutput()
        }
        await fulfillment(of: [outputStarted], timeout: 2)
        let replacement = makeTranscription()
        viewModel.currentTranscription = replacement
        reader.release.signal()
        await fulfillment(of: [returned], timeout: 2)

        let source = await output.value
        XCTAssertNil(source)
        XCTAssertEqual(viewModel.currentTranscription?.id, replacement.id)
    }

    func testCorrectionFailureDoesNotAppearOnNewSelection() async throws {
        let original = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: original)
        let service = StubSpeakerCorrectionService(
            result: .init(attribution: attribution, revision: 0, canUndo: false, canRedo: false),
            applyError: .conflict
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = original
        try await waitUntil { viewModel.speakerAttribution != nil }
        viewModel.applySpeakerCorrection(.rename(speakerID: "S1", label: "Alice"))
        let replacement = makeTranscription()
        viewModel.currentTranscription = replacement

        try await waitUntil { !viewModel.isApplyingSpeakerCorrection }

        XCTAssertEqual(viewModel.currentTranscription?.id, replacement.id)
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRenameWhileAnotherCorrectionSavesIsRefusedUntilItFinishes() async throws {
        let original = makeTranscription()
        let attribution = SpeakerAttributionResolver.resolve(transcription: original)
        let service = StubSpeakerCorrectionService(
            result: .init(attribution: attribution, revision: 1, canUndo: true, canRedo: false)
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = original
        try await waitUntil { viewModel.speakerAttribution != nil }

        XCTAssertTrue(viewModel.renameSpeaker(id: "S1", to: "Alice"))
        XCTAssertTrue(viewModel.isApplyingSpeakerCorrection)
        XCTAssertFalse(
            viewModel.renameSpeaker(id: "S1", to: "Alicia"),
            "A rename submitted while the previous one saves must be refused, not dropped silently"
        )
        XCTAssertEqual(viewModel.errorMessage, "Speaker changes are still loading or saving. Please try again.")

        try await waitUntil { !viewModel.isApplyingSpeakerCorrection }
        XCTAssertTrue(viewModel.renameSpeaker(id: "S1", to: "Alicia"))
        try await waitUntil { !viewModel.isApplyingSpeakerCorrection }

        let calls = await service.applyCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.last?.command, .rename(speakerID: "S1", label: "Alicia"))
        XCTAssertNil(viewModel.errorMessage)
    }

    func testCorrectionRequestedBeforeAttributionLoadsReportsRetry() async {
        let original = makeTranscription()
        let service = StubSpeakerCorrectionService(
            result: .init(
                attribution: SpeakerAttributionResolver.resolve(transcription: original),
                revision: 0, canUndo: false, canRedo: false
            )
        )
        let viewModel = TranscriptionViewModel()
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: MockTranscriptionRepository(),
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = original
        viewModel.applySpeakerCorrection(.rename(speakerID: "S1", label: "Alice"))

        XCTAssertEqual(viewModel.errorMessage, "Speaker changes are still loading or saving. Please try again.")
        let calls = await service.applyCalls
        XCTAssertTrue(calls.isEmpty)
    }

    private func makeTranscription() -> Transcription {
        let words = [
            WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S1"),
            WordTimestamp(word: "there", startMs: 450, endMs: 800, confidence: 0.9, speakerId: "S1"),
        ]
        return Transcription(
            fileName: "meeting.wav",
            rawTranscript: "hello there",
            wordTimestamps: words,
            speakerCount: 1,
            speakers: [SpeakerInfo(id: "S1", label: "Speaker 1")],
            diarizationSegments: [.init(speakerId: "S1", startMs: 0, endMs: 800)],
            transcriptSegments: [
                TranscriptSegmentRecord(
                    startMs: 0,
                    endMs: 800,
                    speakerId: "S1",
                    speakerLabel: "Speaker 1",
                    text: "hello there",
                    wordRange: .init(startIndex: 0, endIndexExclusive: 2)
                )
            ],
            status: .completed,
            sourceType: .meeting
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                XCTFail("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
