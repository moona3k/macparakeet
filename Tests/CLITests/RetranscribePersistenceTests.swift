import XCTest
@testable import CLI
@testable import MacParakeetCore

/// Exercise the CLI's post-processing boundary with real Core persistence.
/// Audio conversion and recognition are deterministic substitutes; no model,
/// helper binary, microphone, provider, or user's preferences are accessed.
final class RetranscribePersistenceTests: XCTestCase {
    func testCLICompletionPreservesConcurrentMetadataForEveryRetainedSource() async throws {
        for source in [Transcription.SourceType.file, .youtube, .podcast, .meeting] {
            let fixture = try Fixture(source: source)
            defer { fixture.cleanup() }
            let repository = fixture.repository
            let id = fixture.original.id
            let result = try await run(fixture) {
                _ = try repository.updateFileName(id: id, fileName: "Renamed during recognition")
                try repository.updateFavorite(id: id, isFavorite: true)
                try repository.updateUserNotes(id: id, userNotes: "Notes saved during recognition")
                try repository.updateChatMessages(id: id, chatMessages: [ChatMessage(role: .user, content: "New chat")])
                try repository.updateFilePath(id: id, filePath: nil)
            }
            guard case .transcription(let returned) = result.record else {
                return XCTFail("Expected a transcription")
            }
            let stored = try XCTUnwrap(repository.fetch(id: id))
            for value in [returned, stored] {
                XCTAssertEqual(value.id, id, "\(source)")
                XCTAssertEqual(value.createdAt, fixture.original.createdAt, "\(source)")
                XCTAssertEqual(value.fileName, "Renamed during recognition", "\(source)")
                XCTAssertTrue(value.isFavorite, "\(source)")
                XCTAssertEqual(value.userNotes, "Notes saved during recognition", "\(source)")
                XCTAssertEqual(value.chatMessages, [ChatMessage(role: .user, content: "New chat")], "\(source)")
                XCTAssertNil(value.filePath, "An explicit audio detach must survive: \(source)")
                XCTAssertEqual(value.rawTranscript, "Fresh recognition", "\(source)")
                XCTAssertEqual(value.sourceURL, fixture.original.sourceURL, "\(source)")
                XCTAssertEqual(value.sourceType, source)
            }
        }
    }

    func testCLICompletionPreservesExplicitNotesAndChatClears() async throws {
        let fixture = try Fixture(source: .meeting)
        defer { fixture.cleanup() }
        let repository = fixture.repository
        let id = fixture.original.id
        let result = try await run(fixture) {
            try repository.updateUserNotes(id: id, userNotes: nil)
            try repository.updateChatMessages(id: id, chatMessages: nil)
        }
        guard case .transcription(let returned) = result.record else {
            return XCTFail("Expected a transcription")
        }
        let stored = try XCTUnwrap(repository.fetch(id: id))
        XCTAssertNil(returned.userNotes)
        XCTAssertNil(returned.chatMessages)
        XCTAssertNil(stored.userNotes)
        XCTAssertNil(stored.chatMessages)
    }

    func testCLICompletionDoesNotRecreateMeetingDeletedAfterCoreCommit() async throws {
        let fixture = try Fixture(source: .meeting)
        defer { fixture.cleanup() }
        let result = try await run(
            fixture,
            artifactStore: DeleteAfterCommitArtifactStore(repository: fixture.repository)
        ) {}
        XCTAssertEqual(result.id, fixture.original.id)
        XCTAssertNil(
            try fixture.repository.fetch(id: fixture.original.id),
            "A delete between Core completion and CLI output must not be undone by a second save"
        )
    }

    func testCLIPropagatesDeletionDuringRecognitionWithoutRecreatingSource() async throws {
        let fixture = try Fixture(source: .file)
        defer { fixture.cleanup() }
        let repository = fixture.repository
        let id = fixture.original.id
        do {
            _ = try await run(fixture) { _ = try repository.delete(id: id) }
            XCTFail("Deletion before completion must fail")
        } catch {
            XCTAssertEqual(error as? TranscriptionCompletionError, .recordingDeleted)
        }
        XCTAssertNil(try repository.fetch(id: id))
    }

    private func run(
        _ fixture: Fixture,
        artifactStore: (any MeetingArtifactStoring)? = nil,
        duringRecognition: @escaping @Sendable () throws -> Void
    ) async throws -> RetranscribeResult {
        let command = try RetranscribeCommand.parse([
            fixture.original.id.uuidString, "--update", "--speaker-detection", "off", "--mode", "raw",
        ])
        let defaults = UserDefaults(suiteName: makeIsolatedDefaultsSuite("CLI-retranscribe-race-"))!
        let stt = MutationSTT(duringRecognition: duringRecognition)
        let segments = SegmentRepository(dbQueue: fixture.database.dbQueue)
        let mutator = KnowledgeLayerMutationService(dbQueue: fixture.database.dbQueue)
        let prompts = PromptResultRepository(dbQueue: fixture.database.dbQueue)
        let words = CustomWordRepository(dbQueue: fixture.database.dbQueue)
        let snippets = TextSnippetRepository(dbQueue: fixture.database.dbQueue)
        let service = TranscriptionService(
            audioProcessor: PassthroughAudio(), sttTranscriber: stt,
            transcriptionRepo: fixture.repository, segmentRepo: segments, knowledgeLayerMutator: mutator,
            processingMode: { .raw }, removeUmFiller: { false },
            shouldUseAIFormatter: { false }, shouldAutoGenerateMeetingTitles: { false },
            shouldDiarize: { false }, shouldDiarizeMeetings: { false },
            meetingArtifactStore: artifactStore, meetingAutomationHookRunner: nil
        )
        if fixture.original.sourceType == .meeting {
            return try await command.retranscribeMeeting(
                fixture.original, speechEngine: SpeechEngineSelection(engine: .parakeet),
                transcriptionRepo: fixture.repository, segmentRepo: segments,
                knowledgeLayerMutator: mutator, promptResultRepo: prompts,
                customWordRepo: words, snippetRepo: snippets, defaults: defaults,
                sttTranscriber: stt, service: service
            )
        }
        return try await command.retranscribeTranscription(
            fixture.original, speechEngine: SpeechEngineSelection(engine: .parakeet),
            transcriptionRepo: fixture.repository, segmentRepo: segments,
            knowledgeLayerMutator: mutator, promptResultRepo: prompts,
            customWordRepo: words, snippetRepo: snippets, defaults: defaults,
            sttTranscriber: stt, service: service
        )
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

private struct MutationSTT: SpeechEngineRoutedTranscribing {
    let duringRecognition: @Sendable () throws -> Void

    func transcribe(
        audioPath: String, job: STTJobKind, onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        try duringRecognition()
        return STTResult(text: "Fresh recognition")
    }

    func transcribe(
        audioPath: String, job: STTJobKind, speechEngine: SpeechEngineSelection,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        XCTAssertEqual(speechEngine.engine, .parakeet)
        return try await transcribe(audioPath: audioPath, job: job, onProgress: onProgress)
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

private struct DeleteAfterCommitArtifactStore: MeetingArtifactStoring {
    let repository: TranscriptionRepository

    func materialize(
        transcription: Transcription, promptResults: [PromptResult]
    ) async throws -> MeetingArtifactSnapshot {
        XCTAssertEqual(try repository.fetch(id: transcription.id)?.rawTranscript, "Fresh recognition")
        XCTAssertTrue(try repository.delete(id: transcription.id))
        // Artifact failure is nonfatal after Core has durably completed the row.
        throw CocoaError(.fileNoSuchFile)
    }
}
