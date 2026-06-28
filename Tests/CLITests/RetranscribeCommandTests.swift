import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class RetranscribeCommandTests: XCTestCase {
    func testRequiresExplicitUpdateConfirmation() {
        XCTAssertThrowsError(try RetranscribeCommand.parse(["abcd"])) { error in
            XCTAssertTrue(String(describing: error).contains("Pass --update"), String(describing: error))
        }
    }

    func testParsesEngineModelLanguageAndEnvelopeOptions() throws {
        let command = try RetranscribeCommand.parse([
            "abcd",
            "--update",
            "--kind", "meeting",
            "--engine", "cohere",
            "--language", "ja",
            "--parakeet-model", "unified",
            "--nemotron-model", "english-1120ms",
            "--speaker-count", "2",
            "--envelope",
        ])

        XCTAssertEqual(command.kind, .meeting)
        XCTAssertEqual(command.engine, .cohere)
        XCTAssertEqual(command.language, "ja")
        XCTAssertEqual(command.parakeetModel, .unified)
        XCTAssertEqual(command.nemotronModel, .english)
        XCTAssertEqual(command.speakerCount, 2)
        XCTAssertTrue(command.envelope)
    }

    func testRejectsJSONAndEnvelopeTogether() {
        XCTAssertThrowsError(try RetranscribeCommand.parse([
            "abcd",
            "--update",
            "--json",
            "--envelope",
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("--json and --envelope cannot be combined"))
        }
    }

    func testResolveAutoFindsTranscriptionByExactTitle() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let id = UUID(uuidString: "A1111111-1111-1111-1111-111111111111")!
        try harness.transcriptions.save(Transcription(
            id: id,
            fileName: "Client Review.m4a",
            filePath: "/tmp/client-review.m4a",
            rawTranscript: "old",
            status: .completed,
            sourceType: .file
        ))

        let target = try RetranscribeCommand.resolveTarget(
            "Client Review.m4a",
            kind: .auto,
            transcriptionRepo: harness.transcriptions,
            dictationRepo: harness.dictations
        )

        guard case .transcription(let transcription) = target else {
            return XCTFail("Expected transcription target, got \(target.kind)")
        }
        XCTAssertEqual(transcription.id, id)
    }

    func testResolveAutoClassifiesMeetingRowsSeparately() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let id = UUID(uuidString: "B2222222-2222-2222-2222-222222222222")!
        try harness.transcriptions.save(Transcription(
            id: id,
            fileName: "Weekly Sync",
            filePath: "/tmp/weekly-sync.m4a",
            rawTranscript: "old",
            status: .completed,
            sourceType: .meeting
        ))

        let target = try RetranscribeCommand.resolveTarget(
            "Weekly Sync",
            kind: .auto,
            transcriptionRepo: harness.transcriptions,
            dictationRepo: harness.dictations
        )

        guard case .meeting(let transcription) = target else {
            return XCTFail("Expected meeting target, got \(target.kind)")
        }
        XCTAssertEqual(transcription.id, id)
    }

    func testResolveAutoFindsDictationByPrefix() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let id = UUID(uuidString: "C3333333-3333-3333-3333-333333333333")!
        try harness.dictations.save(Dictation(
            id: id,
            durationMs: 1_000,
            rawTranscript: "old dictation",
            audioPath: "/tmp/dictation.wav",
            wordCount: 2
        ))

        let target = try RetranscribeCommand.resolveTarget(
            "c333",
            kind: .auto,
            transcriptionRepo: harness.transcriptions,
            dictationRepo: harness.dictations
        )

        guard case .dictation(let dictation) = target else {
            return XCTFail("Expected dictation target, got \(target.kind)")
        }
        XCTAssertEqual(dictation.id, id)
    }

    func testResolveAutoRejectsCrossTablePrefixAmbiguity() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        try harness.transcriptions.save(Transcription(
            id: UUID(uuidString: "D4440000-1111-1111-1111-111111111111")!,
            fileName: "Ambiguous.m4a",
            filePath: "/tmp/ambiguous.m4a",
            rawTranscript: "old",
            status: .completed
        ))
        try harness.dictations.save(Dictation(
            id: UUID(uuidString: "D4449999-2222-2222-2222-222222222222")!,
            durationMs: 1_000,
            rawTranscript: "old dictation",
            audioPath: "/tmp/dictation.wav",
            wordCount: 2
        ))

        XCTAssertThrowsError(try RetranscribeCommand.resolveTarget(
            "d444",
            kind: .auto,
            transcriptionRepo: harness.transcriptions,
            dictationRepo: harness.dictations
        )) { error in
            guard case CLIRetranscribeError.ambiguousRecord = error else {
                return XCTFail("Expected ambiguousRecord, got \(error)")
            }
        }
    }

    func testResolveAutoPreservesShortUUIDPrefixError() throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }

        XCTAssertThrowsError(try RetranscribeCommand.resolveTarget(
            "abc",
            kind: .auto,
            transcriptionRepo: harness.transcriptions,
            dictationRepo: harness.dictations
        )) { error in
            guard case CLILookupError.shortUUIDPrefix(let minimumLength) = error else {
                return XCTFail("Expected shortUUIDPrefix, got \(error)")
            }
            XCTAssertEqual(minimumLength, 4)
        }
    }

    func testRetainedAudioURLRequiresStoredPathAndExistingFile() throws {
        let id = UUID(uuidString: "E5555555-5555-5555-5555-555555555555")!
        XCTAssertThrowsError(try RetranscribeCommand.retainedAudioURL(path: nil, kind: "transcription", id: id)) { error in
            guard case CLIRetranscribeError.noRetainedAudio = error else {
                return XCTFail("Expected noRetainedAudio, got \(error)")
            }
        }

        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).wav")
        XCTAssertThrowsError(try RetranscribeCommand.retainedAudioURL(path: missing.path, kind: "transcription", id: id)) { error in
            guard case CLIRetranscribeError.missingAudio = error else {
                return XCTFail("Expected missingAudio, got \(error)")
            }
        }

        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("existing-\(UUID().uuidString).wav")
        FileManager.default.createFile(atPath: existing.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: existing) }
        XCTAssertEqual(
            try RetranscribeCommand.retainedAudioURL(path: existing.path, kind: "transcription", id: id),
            existing
        )
    }

    func testPreservesOriginalTranscriptionMetadataWhileKeepingNewTranscriptFields() {
        let id = UUID(uuidString: "F6666666-6666-6666-6666-666666666666")!
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let original = Transcription(
            id: id,
            createdAt: createdAt,
            fileName: "Original Title",
            filePath: "/tmp/original.m4a",
            meetingArtifactFolderPath: "/tmp/artifact",
            rawTranscript: "old",
            status: .completed,
            sourceURL: "https://example.com/source",
            thumbnailURL: "https://example.com/thumb.jpg",
            channelName: "Channel",
            videoDescription: "Description",
            isFavorite: true,
            sourceType: .meeting,
            recoveredFromCrash: true,
            userNotes: "keep notes",
            engine: "parakeet"
        )
        let result = Transcription(
            id: UUID(),
            createdAt: Date(),
            fileName: "Generated Title",
            filePath: "/tmp/new.m4a",
            durationMs: 2_000,
            rawTranscript: "new raw",
            cleanTranscript: "new clean",
            status: .completed,
            sourceType: .file,
            engine: "cohere",
            engineVariant: "ane",
            derivedTitle: "New",
            derivedSnippet: "Snippet"
        )

        let preserved = RetranscribeCommand.preserveOriginalTranscriptionMetadata(result, original: original)

        XCTAssertEqual(preserved.id, id)
        XCTAssertEqual(preserved.createdAt, createdAt)
        XCTAssertEqual(preserved.fileName, "Original Title")
        XCTAssertEqual(preserved.filePath, "/tmp/original.m4a")
        XCTAssertEqual(preserved.meetingArtifactFolderPath, "/tmp/artifact")
        XCTAssertEqual(preserved.sourceURL, "https://example.com/source")
        XCTAssertEqual(preserved.thumbnailURL, "https://example.com/thumb.jpg")
        XCTAssertEqual(preserved.channelName, "Channel")
        XCTAssertEqual(preserved.videoDescription, "Description")
        XCTAssertTrue(preserved.isFavorite)
        XCTAssertEqual(preserved.sourceType, .meeting)
        XCTAssertTrue(preserved.recoveredFromCrash)
        XCTAssertEqual(preserved.userNotes, "keep notes")
        XCTAssertEqual(preserved.rawTranscript, "new raw")
        XCTAssertEqual(preserved.cleanTranscript, "new clean")
        XCTAssertEqual(preserved.engine, "cohere")
        XCTAssertEqual(preserved.engineVariant, "ane")
    }

    func testClearsDictationFormatterAttributionForLocalRerun() {
        let dictation = Dictation(
            id: UUID(),
            durationMs: 1_000,
            rawTranscript: "old",
            cleanTranscript: "formatted old",
            audioPath: "/tmp/dictation.wav",
            wordCount: 2,
            aiFormatterProfileID: UUID(),
            aiFormatterProfileName: "Profile",
            aiFormatterProfileMatchKind: .global
        )

        let updated = RetranscribeCommand.clearingDictationFormatterMetadata(dictation)

        XCTAssertNil(updated.aiFormatterProfileID)
        XCTAssertNil(updated.aiFormatterProfileName)
        XCTAssertNil(updated.aiFormatterProfileMatchKind)
        XCTAssertEqual(updated.id, dictation.id)
        XCTAssertEqual(updated.audioPath, dictation.audioPath)
        XCTAssertEqual(updated.rawTranscript, dictation.rawTranscript)
    }

    func testJSONFailureEnvelopeForMissingRetainedAudio() async throws {
        let harness = try makeHarness()
        defer { harness.cleanup() }
        let id = UUID(uuidString: "A7777777-7777-7777-7777-777777777777")!
        try harness.transcriptions.save(Transcription(
            id: id,
            fileName: "No Audio",
            rawTranscript: "old",
            status: .completed
        ))
        let command = try RetranscribeCommand.parse([
            id.uuidString,
            "--kind", "transcription",
            "--update",
            "--json",
            "--database", harness.dbURL.path,
        ])

        var thrownError: Error?
        let output = try await captureStandardOutput {
            do {
                try await command.run()
            } catch {
                thrownError = error
            }
        }

        let error = try XCTUnwrap(thrownError)
        XCTAssertTrue(error is CLIJSONEnvelopeExit)
        XCTAssertEqual(CLI.normalizedExitCode(for: error), .failure)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["ok"] as? Bool, false)
        XCTAssertEqual(object["errorType"] as? String, "input_missing")
        XCTAssertTrue((object["error"] as? String)?.contains("no retained source audio") == true)
    }

    private func makeHarness() throws -> Harness {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-retranscribe-\(UUID().uuidString).db")
        let manager = try DatabaseManager(path: dbURL.path)
        return Harness(
            dbURL: dbURL,
            transcriptions: TranscriptionRepository(dbQueue: manager.dbQueue),
            dictations: DictationRepository(dbQueue: manager.dbQueue)
        )
    }

    private struct Harness {
        let dbURL: URL
        let transcriptions: TranscriptionRepository
        let dictations: DictationRepository

        func cleanup() {
            try? FileManager.default.removeItem(at: dbURL)
            try? FileManager.default.removeItem(atPath: dbURL.path + ".migration.lock")
        }
    }
}
