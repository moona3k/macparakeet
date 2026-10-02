import Observation
import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

/// Exercise GUI completion with real Core and SQLite persistence. Recognition,
/// conversion and artifact output are substitutes; no model or device is used.
@MainActor
final class GUIRetranscriptionPersistenceTests: XCTestCase {
    func testCompletionDoesNotOverwriteTranscriptEditedAfterCoreCommit() async throws {
        let fixture = try Fixture(source: .meeting)
        defer { fixture.cleanup() }
        let repository = fixture.repository
        let artifactStore = AfterCommitArtifactStore { committed in
            XCTAssertEqual(try repository.fetch(id: committed.id)?.rawTranscript, "Fresh recognition")
            _ = try repository.updateTranscriptText(
                "Correction saved after recognition",
                expected: repository.transcriptEditSnapshot(for: committed)
            )
        }

        let viewModel = try await run(fixture, artifactStore: artifactStore)

        XCTAssertNil(viewModel.errorMessage)
        let stored = try XCTUnwrap(repository.fetch(id: fixture.original.id))
        XCTAssertEqual(stored.rawTranscript, "Fresh recognition")
        XCTAssertEqual(stored.cleanTranscript, "Correction saved after recognition")
        XCTAssertTrue(stored.isTranscriptEdited)
    }

    func testCompletionPreservesConcurrentMetadataAndExplicitClears() async throws {
        for source in [Transcription.SourceType.file, .youtube, .podcast, .meeting] {
            let fixture = try Fixture(source: source)
            defer { fixture.cleanup() }
            let repository = fixture.repository
            let id = fixture.original.id
            let viewModel = try await run(fixture) {
                _ = try repository.updateFileName(id: id, fileName: "Renamed during recognition")
                try repository.updateFavorite(id: id, isFavorite: true)
                try repository.updateUserNotes(id: id, userNotes: nil)
                try repository.updateChatMessages(id: id, chatMessages: nil)
                try repository.updateFilePath(id: id, filePath: nil)
            }

            XCTAssertNil(viewModel.errorMessage)
            let published = try XCTUnwrap(viewModel.currentTranscription)
            let stored = try XCTUnwrap(repository.fetch(id: id))
            for value in [published, stored] {
                XCTAssertEqual(value.id, id)
                XCTAssertEqual(value.createdAt, fixture.original.createdAt)
                XCTAssertEqual(value.fileName, "Renamed during recognition")
                XCTAssertTrue(value.isFavorite)
                XCTAssertNil(value.userNotes)
                XCTAssertNil(value.chatMessages)
                XCTAssertNil(value.filePath)
                XCTAssertEqual(value.rawTranscript, "Fresh recognition")
                XCTAssertEqual(value.sourceType, source)
            }
        }
    }

    private func run(
        _ fixture: Fixture,
        artifactStore: (any MeetingArtifactStoring)? = nil,
        duringRecognition: @escaping @Sendable () throws -> Void = {}
    ) async throws -> TranscriptionViewModel {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: makeIsolatedDefaultsSuite("GUI-retranscribe-race-")))
        let service = TranscriptionService(
            audioProcessor: PassthroughAudio(), sttTranscriber: MutationSTT(duringRecognition: duringRecognition),
            transcriptionRepo: fixture.repository,
            segmentRepo: SegmentRepository(dbQueue: fixture.database.dbQueue),
            knowledgeLayerMutator: KnowledgeLayerMutationService(dbQueue: fixture.database.dbQueue),
            processingMode: { .raw }, removeUmFiller: { false },
            shouldUseAIFormatter: { false }, shouldAutoGenerateMeetingTitles: { false },
            shouldDiarize: { false }, shouldDiarizeMeetings: { false },
            meetingArtifactStore: artifactStore, meetingAutomationHookRunner: nil
        )
        let viewModel = TranscriptionViewModel(defaults: defaults)
        viewModel.configure(transcriptionService: service, transcriptionRepo: fixture.repository)
        viewModel.retranscribe(fixture.original)
        XCTAssertTrue(viewModel.isTranscribing)
        let finished = expectation(description: "GUI retranscription completed")
        withObservationTracking {
            _ = viewModel.isTranscribing
        } onChange: {
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 5)
        XCTAssertFalse(viewModel.isTranscribing)
        return viewModel
    }

    private struct Fixture {
        let root: URL
        let database: DatabaseManager
        let repository: TranscriptionRepository
        let original: Transcription

        init(source: Transcription.SourceType) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let audio = root.appendingPathComponent("source.wav")
            try Data("synthetic path fixture".utf8).write(to: audio)
            database = try DatabaseManager()
            repository = TranscriptionRepository(dbQueue: database.dbQueue)
            original = Transcription(
                createdAt: Date(timeIntervalSince1970: 1_000), fileName: "Original title",
                filePath: audio.path, rawTranscript: "Old recognition",
                chatMessages: [ChatMessage(role: .user, content: "Old chat")], status: .completed,
                sourceURL: source == .youtube || source == .podcast ? "https://example.invalid/media" : nil,
                sourceType: source, userNotes: "Old notes"
            )
            try repository.save(original)
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private struct MutationSTT: STTTranscribing {
    let duringRecognition: @Sendable () throws -> Void

    func transcribe(
        audioPath: String, job: STTJobKind, onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        try duringRecognition()
        return STTResult(text: "Fresh recognition")
    }
}

private struct PassthroughAudio: AudioProcessorProtocol {
    var audioLevel: Float { 0 }
    var isRecording: Bool { false }
    var recordingDeviceInfo: RecordingDeviceInfo? { nil }
    func convert(fileURL: URL) async throws -> URL { fileURL }
    func startCapture() async throws { throw CocoaError(.featureUnsupported) }
    func stopCapture() async throws -> URL { throw CocoaError(.featureUnsupported) }
}

private struct AfterCommitArtifactStore: MeetingArtifactStoring {
    let afterCommit: @Sendable (Transcription) throws -> Void

    func materialize(
        transcription: Transcription, promptResults: [PromptResult]
    ) async throws -> MeetingArtifactSnapshot {
        try afterCommit(transcription)
        // Artifact failure is nonfatal after Core durably completes the row.
        throw CocoaError(.fileNoSuchFile)
    }
}
