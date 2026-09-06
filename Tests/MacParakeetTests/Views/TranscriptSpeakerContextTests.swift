import GRDB
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore
@testable import MacParakeetViewModels

private actor SpeakerContextFormattingGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private actor OrderedArtifactStore: MeetingArtifactStoring {
    let firstStarted: XCTestExpectation
    private let gate = SpeakerContextFormattingGate()
    private let store = MeetingArtifactStore()
    private(set) var revisions: [Int] = []
    private var active = 0
    private(set) var maxActive = 0

    init(firstStarted: XCTestExpectation) { self.firstStarted = firstStarted }
    func release() async { await gate.release() }
    func materialize(transcription: Transcription, promptResults: [PromptResult]) async throws -> MeetingArtifactSnapshot {
        XCTFail("Production refresh must supply the projection")
        return try await store.materialize(transcription: transcription, promptResults: promptResults)
    }
    func materialize(projection: SpeakerAttributionProjection, promptResults: [PromptResult]) async throws -> MeetingArtifactSnapshot {
        active += 1
        maxActive = max(maxActive, active)
        defer { active -= 1 }
        if revisions.isEmpty {
            firstStarted.fulfill()
            await gate.wait()
        }
        let snapshot = try await store.materialize(projection: projection, promptResults: promptResults)
        revisions.append(projection.correctionRevision)
        return snapshot
    }
}

private final class BlockingAttributionReader: SpeakerAttributionReading, @unchecked Sendable {
    let delegate: SpeakerAttributionReadService
    let started: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var blocked = false
    func arm() { lock.withLock { blocked = true } }
    init(delegate: SpeakerAttributionReadService, started: XCTestExpectation) {
        self.delegate = delegate
        self.started = started
    }
    func resolve(transcriptionId: UUID) throws -> SpeakerAttributionProjection? {
        try delegate.resolve(transcriptionId: transcriptionId)
    }
    func resolve(transcription: Transcription) throws -> SpeakerAttributionProjection {
        if lock.withLock({ blocked }) {
            started.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        return try delegate.resolve(transcription: transcription)
    }
}

@MainActor
final class TranscriptSpeakerContextTests: XCTestCase {
    func testCorrectionRefreshesCachedChatAndPromptContextWithoutReplacingCanonicalRow() async throws {
        let fixture = try makeFixture()
        let viewModel = fixture.viewModel
        try await waitUntil { viewModel.speakerAttribution != nil }
        let revision = viewModel.currentTranscriptionRevision
        let loader = TranscriptRichContextLoader()
        var chatContext = ""
        await loader.schedule(
            transcription: try XCTUnwrap(viewModel.effectiveCurrentTranscription),
            mode: .richTranscript,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision
        ) { _, text in chatContext = text }.value
        XCTAssertTrue(chatContext.contains("Speaker 1:"))

        viewModel.renameSpeaker(id: "S1", to: "Alice")
        try await waitUntil { viewModel.speakerAttribution?.correctionRevision == 1 }
        XCTAssertEqual(viewModel.currentTranscriptionRevision, revision)
        XCTAssertEqual(try fixture.repository.fetch(id: fixture.transcription.id)?.speakers?.first?.label, "Speaker 1")

        await loader.schedule(
            transcription: try XCTUnwrap(viewModel.effectiveCurrentTranscription),
            mode: .richTranscript,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision
        ) { _, text in chatContext = text }.value
        XCTAssertTrue(chatContext.contains("Alice:"))
        XCTAssertFalse(chatContext.contains("Speaker 1:"))
        var promptContext = ""
        let action = try XCTUnwrap(loader.startPromptAction(
            transcription: try XCTUnwrap(viewModel.effectiveCurrentTranscription),
            mode: .richTranscript,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision,
            isCurrent: { $0.speakerCorrectionRevision == viewModel.speakerAttribution?.correctionRevision },
            onStale: { XCTFail("The corrected snapshot should remain current") },
            action: { promptContext = $0 }
        ))
        await action.value
        XCTAssertEqual(promptContext, chatContext)

        viewModel.undoSpeakerCorrection()
        try await waitUntil { viewModel.speakerAttribution?.correctionRevision == 2 }
        let undone = await loader.prepare(
            transcription: try XCTUnwrap(viewModel.effectiveCurrentTranscription),
            mode: .richTranscript,
            contentRevision: revision,
            speakerCorrectionRevision: viewModel.speakerAttribution?.correctionRevision
        )
        XCTAssertTrue(try XCTUnwrap(undone).text.contains("Speaker 1:"))
    }

    func testLoadingStoredCorrectionsInvalidatesCachedAutomaticContext() async throws {
        let fixture = try makeFixture()
        let loader = TranscriptRichContextLoader()
        let baseline = await loader.prepare(
            transcription: fixture.transcription,
            mode: .richTranscript,
            contentRevision: 1,
            speakerCorrectionRevision: nil
        )
        XCTAssertTrue(try XCTUnwrap(baseline).text.contains("Speaker 1:"))
        _ = try await fixture.service.apply(
            transcriptionId: fixture.transcription.id,
            command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: SpeakerAttributionResolver.fingerprint(for: fixture.transcription),
            expectedRevision: 0
        )
        let stored = try fixture.reader.resolve(transcription: fixture.transcription)
        let loaded = await loader.prepare(
            transcription: stored.effectiveTranscription,
            mode: .richTranscript,
            contentRevision: 1,
            speakerCorrectionRevision: stored.correctionRevision
        )
        XCTAssertTrue(try XCTUnwrap(loaded).text.contains("Alice:"))
    }

    func testSpeakerChangeDuringPreparationCannotSubmitStaleContext() async throws {
        let started = expectation(description: "Formatting started")
        let gate = SpeakerContextFormattingGate()
        let loader = TranscriptRichContextLoader { transcription, mode in
            started.fulfill()
            await gate.wait()
            return TranscriptAIContextFormatter.format(transcription: transcription, mode: mode)
        }
        var speakerRevision: Int? = 0
        var stale = false
        let action = try XCTUnwrap(loader.startPromptAction(
            transcription: makeTranscription(),
            mode: .richTranscript,
            contentRevision: 1,
            speakerCorrectionRevision: speakerRevision,
            isCurrent: { $0.speakerCorrectionRevision == speakerRevision },
            onStale: { stale = true },
            action: { _ in XCTFail("Old speaker attribution must never be submitted") }
        ))
        await fulfillment(of: [started], timeout: 2)
        speakerRevision = 1
        await gate.release()
        await action.value
        XCTAssertTrue(stale)
    }

    func testViewModelRefreshPreservesCorrectionProvenanceWithConfiguredArtifactStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let fixture = try makeFixture(folder: folder)
        let viewModel = fixture.viewModel
        try await waitUntil { viewModel.speakerAttribution != nil }
        let segment = try XCTUnwrap(viewModel.speakerAttribution?.editableSegments.first)
        let manualID = "user:\(UUID().uuidString)"
        viewModel.applySpeakerCorrection(.add(
            speaker: ManualSpeaker(id: manualID, label: "Alice"),
            assigning: [.init(anchorTranscriptSegmentIDs: segment.anchorTranscriptSegmentIDs, wordRange: segment.wordRange)]
        ))
        let manifest = folder.appendingPathComponent(MeetingArtifactStore.manifestFileName)
        try await waitUntil { FileManager.default.fileExists(atPath: manifest.path) }
        let transcript = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: folder.appendingPathComponent(MeetingArtifactStore.transcriptFileName))
        ) as? [String: Any])
        XCTAssertEqual(transcript["speakerCorrectionsApplied"] as? Bool, true)
        XCTAssertEqual(transcript["speakerCorrectionRevision"] as? Int, 1)
        let words = try XCTUnwrap(transcript["wordTimestamps"] as? [[String: Any]])
        XCTAssertEqual(words.compactMap { $0["speakerId"] as? String }, [manualID, manualID])
        let markdown = try String(contentsOf: folder.appendingPathComponent(MeetingArtifactStore.markdownFileName))
        XCTAssertTrue(markdown.contains("speakerCorrectionsApplied: true"))
        XCTAssertTrue(markdown.contains("speakerCorrectionRevision: 1"))
        XCTAssertTrue(markdown.contains("Alice"))
        XCTAssertEqual(try fixture.repository.fetch(id: fixture.transcription.id)?.wordTimestamps, fixture.transcription.wordTimestamps)
    }

    func testNotesFlushWaitsForCorrectedAIContextBeforePromptPreparation() async throws {
        let db = try DatabaseManager()
        let repo = TranscriptionRepository(dbQueue: db.dbQueue)
        let row = makeTranscription()
        try repo.save(row)
        _ = try await SpeakerCorrectionService(dbQueue: db.dbQueue).apply(
            transcriptionId: row.id, command: .rename(speakerID: "S1", label: "Alice"),
            expectedFingerprint: SpeakerAttributionResolver.fingerprint(for: row), expectedRevision: 0
        )
        let started = expectation(description: "DB attribution blocked after notes publication")
        let reader = BlockingAttributionReader(delegate: .init(dbQueue: db.dbQueue), started: started)
        let vm = TranscriptionViewModel()
        vm.configure(transcriptionService: MockTranscriptionService(), transcriptionRepo: repo,
                     speakerAttributionReader: reader)
        vm.currentTranscription = row
        try await waitUntil { vm.speakerAttribution != nil }
        reader.arm()
        let editor = SavedMeetingNotesViewModel()
        editor.configure(meetingID: row.id, text: nil) { text in
            await vm.updateMeetingNotes(for: row, to: text)
        }
        editor.textBinding.wrappedValue = "Fresh notes"
        editor.cancelPendingSave()
        var sentContext: String?
        let action = Task { @MainActor in
            guard await editor.flush(), await vm.waitForCurrentSpeakerAttribution(),
                  let current = vm.effectiveCurrentTranscription else { return }
            sentContext = TranscriptAIContextFormatter.format(transcription: current)
        }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertNil(vm.speakerAttribution)
        XCTAssertNil(sentContext)
        reader.release.signal()
        await action.value
        XCTAssertTrue(try XCTUnwrap(sentContext).contains("Alice:"))
        XCTAssertEqual(vm.currentTranscription?.userNotes, "Fresh notes")
    }

    func testRenameNotesAndSpeakerRefreshesSerializeAndReadLatestState() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstStarted = expectation(description: "Old rename artifact write suspended")
        let store = OrderedArtifactStore(firstStarted: firstStarted)
        let fixture = try makeFixture(folder: folder, artifactStore: store)
        let vm = fixture.viewModel
        try await waitUntil { vm.speakerAttribution != nil }
        vm.renameCurrentTranscription(to: "Renamed meeting")
        await fulfillment(of: [firstStarted], timeout: 3)
        let notesSave = Task { @MainActor in await vm.updateCurrentMeetingNotes(to: "Newest notes") }
        try await waitUntil { vm.currentTranscription?.userNotes == "Newest notes" && vm.speakerAttribution != nil }
        vm.renameSpeaker(id: "S1", to: "Alice")
        try await waitUntil { vm.speakerAttribution?.correctionRevision == 1 }
        await store.release()
        let saved = await notesSave.value
        XCTAssertTrue(saved)
        let deadline = ContinuousClock.now + .seconds(3)
        while await store.revisions.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let revisions = await store.revisions
        let maxActive = await store.maxActive
        XCTAssertEqual(revisions.count, 3)
        XCTAssertEqual(revisions.last, 1)
        XCTAssertEqual(maxActive, 1)
        let data = try Data(contentsOf: folder.appendingPathComponent(MeetingArtifactStore.transcriptFileName))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["title"] as? String, "Renamed meeting")
        XCTAssertEqual(payload["userNotes"] as? String, "Newest notes")
        XCTAssertEqual(payload["speakerCorrectionRevision"] as? Int, 1)
        XCTAssertEqual((payload["speakers"] as? [[String: Any]])?.first?["label"] as? String, "Alice")
    }

    private func makeFixture(folder: URL? = nil, artifactStore: MeetingArtifactStoring? = nil) throws -> (
        viewModel: TranscriptionViewModel, transcription: Transcription,
        repository: TranscriptionRepository, reader: SpeakerAttributionReadService,
        service: SpeakerCorrectionService
    ) {
        let manager = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: manager.dbQueue)
        let reader = SpeakerAttributionReadService(dbQueue: manager.dbQueue)
        let service = SpeakerCorrectionService(dbQueue: manager.dbQueue)
        var transcription = makeTranscription()
        transcription.meetingArtifactFolderPath = folder?.path
        try repository.save(transcription)
        let viewModel = TranscriptionViewModel(meetingArtifactStore: artifactStore ?? MeetingArtifactStore(speakerAttributionReader: reader))
        viewModel.configure(
            transcriptionService: MockTranscriptionService(),
            transcriptionRepo: repository,
            promptResultRepo: PromptResultRepository(dbQueue: manager.dbQueue),
            speakerAttributionReader: reader,
            speakerCorrectionService: service
        )
        viewModel.currentTranscription = transcription
        return (viewModel, transcription, repository, reader, service)
    }

    private func makeTranscription() -> Transcription {
        let words = [
            WordTimestamp(word: "Hello", startMs: 0, endMs: 400, confidence: 1, speakerId: "S1"),
            WordTimestamp(word: "there.", startMs: 450, endMs: 800, confidence: 1, speakerId: "S1"),
        ]
        let speakers = [SpeakerInfo(id: "S1", label: "Speaker 1")]
        return Transcription(
            fileName: "Meeting", rawTranscript: "Hello there.", wordTimestamps: words,
            speakerCount: 1, speakers: speakers,
            transcriptSegments: TranscriptSegmenter.materializeSegments(words: words, speakers: speakers),
            status: .completed, sourceType: .meeting
        )
    }

    private func waitUntil(condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(3)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for speaker projection or artifact")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
