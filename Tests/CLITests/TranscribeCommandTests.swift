import ArgumentParser
import XCTest
@testable import CLI
@testable import MacParakeetCore

final class TranscribeCommandTests: XCTestCase {
    func testResolveProcessingModeUsesRawForAppDefaultWhenUnset() {
        let mode = TranscribeCommand.resolveProcessingMode(.appDefault, storedMode: nil)
        XCTAssertEqual(mode, .raw)
    }

    func testResolveProcessingModeUsesRawForAppDefaultWhenStoredModeInvalid() {
        let mode = TranscribeCommand.resolveProcessingMode(.appDefault, storedMode: "not-a-mode")
        XCTAssertEqual(mode, .raw)
    }

    func testResolveProcessingModeUsesStoredModeForAppDefaultWhenValid() {
        let mode = TranscribeCommand.resolveProcessingMode(.appDefault, storedMode: Dictation.ProcessingMode.clean.rawValue)
        XCTAssertEqual(mode, .clean)
    }

    func testResolveProcessingModeRespectsExplicitMode() {
        let mode = TranscribeCommand.resolveProcessingMode(.clean, storedMode: Dictation.ProcessingMode.raw.rawValue)
        XCTAssertEqual(mode, .clean)
    }

    func testResolveParakeetModelVariantFollowsStoredForAppDefault() {
        XCTAssertEqual(
            TranscribeCommand.resolveParakeetModelVariant(.appDefault, storedVariant: .v2),
            .v2
        )
        XCTAssertEqual(
            TranscribeCommand.resolveParakeetModelVariant(.appDefault, storedVariant: .v3),
            .v3
        )
    }

    func testResolveParakeetModelVariantRespectsExplicitOverride() {
        XCTAssertEqual(
            TranscribeCommand.resolveParakeetModelVariant(.v2, storedVariant: .v3),
            .v2
        )
        XCTAssertEqual(
            TranscribeCommand.resolveParakeetModelVariant(.v3, storedVariant: .v2),
            .v3
        )
    }

    func testResolveYouTubeAudioQualityUsesM4AForAppDefaultWhenUnset() {
        let quality = TranscribeCommand.resolveYouTubeAudioQuality(.appDefault, storedQuality: nil)
        XCTAssertEqual(quality, .m4a)
    }

    func testResolveYouTubeAudioQualityUsesM4AForAppDefaultWhenStoredQualityInvalid() {
        let quality = TranscribeCommand.resolveYouTubeAudioQuality(.appDefault, storedQuality: "not-a-quality")
        XCTAssertEqual(quality, .m4a)
    }

    func testResolveYouTubeAudioQualityUsesStoredQualityForAppDefaultWhenValid() {
        let quality = TranscribeCommand.resolveYouTubeAudioQuality(
            .appDefault,
            storedQuality: YouTubeAudioQuality.bestAvailable.rawValue
        )
        XCTAssertEqual(quality, .bestAvailable)
    }

    func testResolveYouTubeAudioQualityRespectsExplicitQuality() {
        let quality = TranscribeCommand.resolveYouTubeAudioQuality(
            .bestAvailable,
            storedQuality: YouTubeAudioQuality.m4a.rawValue
        )
        XCTAssertEqual(quality, .bestAvailable)
    }

    func testResolveSpeechEngineUsesStoredDefaultWhenRequested() {
        let selection = TranscribeCommand.resolveSpeechEngine(
            .appDefault,
            storedEngine: SpeechEnginePreference.whisper.rawValue,
            storedLanguage: "ko",
            explicitLanguage: nil
        )

        XCTAssertEqual(selection.engine, .whisper)
        XCTAssertEqual(selection.language, "ko")
    }

    func testResolveSpeechEngineExplicitLanguageOverridesStoredDefault() {
        let selection = TranscribeCommand.resolveSpeechEngine(
            .appDefault,
            storedEngine: SpeechEnginePreference.whisper.rawValue,
            storedLanguage: "ko",
            explicitLanguage: "ja"
        )

        XCTAssertEqual(selection.engine, .whisper)
        XCTAssertEqual(selection.language, "ja")
    }

    func testResolveSpeechEngineFallsBackToParakeetForInvalidStoredDefault() {
        let selection = TranscribeCommand.resolveSpeechEngine(
            .appDefault,
            storedEngine: "bogus",
            storedLanguage: "ko",
            explicitLanguage: nil
        )

        XCTAssertEqual(selection.engine, .parakeet)
        XCTAssertNil(selection.language)
    }

    func testResolveSpeechEngineFallsBackToParakeetWhenStoredEngineUnset() {
        // Fresh-install case: CLI-only user with no .app present, no key ever
        // written to the shared UserDefaults suite. Agents should be able to
        // install the CLI without the .app and still call `--engine app-default`.
        let selection = TranscribeCommand.resolveSpeechEngine(
            .appDefault,
            storedEngine: nil,
            storedLanguage: nil,
            explicitLanguage: nil
        )

        XCTAssertEqual(selection.engine, .parakeet)
        XCTAssertNil(selection.language)
    }

    func testResolveSpeechEngineExplicitWhisperUsesExplicitLanguageOnly() {
        let selection = TranscribeCommand.resolveSpeechEngine(
            .whisper,
            storedEngine: SpeechEnginePreference.parakeet.rawValue,
            storedLanguage: "ko",
            explicitLanguage: nil
        )

        XCTAssertEqual(selection.engine, .whisper)
        XCTAssertNil(selection.language)
    }

    func testResolveSpeechEngineExplicitParakeetDropsLanguage() {
        let selection = TranscribeCommand.resolveSpeechEngine(
            .parakeet,
            storedEngine: SpeechEnginePreference.whisper.rawValue,
            storedLanguage: "ko",
            explicitLanguage: "ja"
        )

        XCTAssertEqual(selection.engine, .parakeet)
        XCTAssertNil(selection.language)
    }

    func testResolveSpeakerDetectionUsesStoredDefaultWhenRequested() {
        XCTAssertTrue(TranscribeCommand.resolveSpeakerDetection(.appDefault, storedEnabled: true, noDiarize: false))
        XCTAssertFalse(TranscribeCommand.resolveSpeakerDetection(.appDefault, storedEnabled: nil, noDiarize: false))
    }

    func testResolveSpeakerDetectionRespectsExplicitAndLegacyDisableFlag() {
        XCTAssertTrue(TranscribeCommand.resolveSpeakerDetection(.on, storedEnabled: false, noDiarize: false))
        XCTAssertFalse(TranscribeCommand.resolveSpeakerDetection(.off, storedEnabled: true, noDiarize: false))
        XCTAssertFalse(TranscribeCommand.resolveSpeakerDetection(.on, storedEnabled: true, noDiarize: true))
    }

    func testParsesWhisperEngineAndLanguage() throws {
        let command = try TranscribeCommand.parse([
            "sample.wav",
            "--engine", "whisper",
            "--language", "ko",
        ])

        XCTAssertEqual(command.engine, .whisper)
        XCTAssertEqual(command.language, "ko")
    }

    func testParsesAppDefaultEngineAndSpeakerDetection() throws {
        let command = try TranscribeCommand.parse([
            "sample.wav",
            "--engine", "app-default",
            "--speaker-detection", "app-default",
        ])

        XCTAssertEqual(command.engine, .appDefault)
        XCTAssertEqual(command.speakerDetection, .appDefault)
    }

    func testParsesYouTubeAudioQuality() throws {
        let command = try TranscribeCommand.parse([
            "https://www.youtube.com/watch?v=abc",
            "--youtube-audio-quality", "best-available",
        ])

        XCTAssertEqual(command.youtubeAudioQuality, .bestAvailable)
    }

    func testParsesTranscriptFormatAndNoHistory() throws {
        let command = try TranscribeCommand.parse([
            "sample.wav",
            "--format", "transcript",
            "--no-history",
        ])

        XCTAssertEqual(command.format, .transcript)
        XCTAssertTrue(command.noHistory)
    }

    func testNoHistoryRejectsRetainedDownloadedAudio() throws {
        XCTAssertThrowsError(try TranscribeCommand.parse([
            "sample.wav",
            "--no-history",
            "--downloaded-audio", "keep",
        ])) { error in
            XCTAssertTrue(String(describing: error).contains("--no-history cannot be combined"))
        }
    }

    func testNoFlagDefaultsKeepParakeetAndUseAppDefaultSpeakerDetection() throws {
        let command = try TranscribeCommand.parse(["sample.wav"])
        XCTAssertEqual(command.engine, .parakeet)
        XCTAssertNil(command.language)
        XCTAssertEqual(command.speakerDetection, .appDefault)
        XCTAssertEqual(command.youtubeAudioQuality, .appDefault)
    }

    func testLocalFileURLExpandsTilde() {
        let url = TranscribeCommand.localFileURL(for: "~/sample.wav")
        XCTAssertEqual(
            url.path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("sample.wav").path
        )
    }

    func testTranscriptOutputPrefersCleanTranscriptAndTrims() {
        let transcription = Transcription(
            fileName: "sample.wav",
            rawTranscript: " raw text ",
            cleanTranscript: " clean text ",
            status: .completed
        )

        XCTAssertEqual(TranscribeCommand.transcriptOutput(for: transcription), "clean text")
    }

    func testTranscriptOutputFallsBackToRawTranscript() {
        let transcription = Transcription(
            fileName: "sample.wav",
            rawTranscript: " raw text ",
            cleanTranscript: "   ",
            status: .completed
        )

        XCTAssertEqual(TranscribeCommand.transcriptOutput(for: transcription), "raw text")
    }

    func testJSONFormatEmitsFailureEnvelopeForMissingFile() async throws {
        let dbURL = temporaryDatabaseURL()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-missing-\(UUID().uuidString).wav")
        let command = try TranscribeCommand.parse([
            missingURL.path,
            "--format", "json",
            "--database", dbURL.path,
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
        XCTAssertTrue((object["error"] as? String)?.contains("File not found") == true)
    }

    // MARK: - Batch (Phase C)

    func testParsesMultipleInputsAndOutputDir() throws {
        let command = try TranscribeCommand.parse([
            "a.wav", "b.m4a", "c.mp3",
            "--output-dir", "/tmp/out",
            "--format", "transcript",
        ])
        XCTAssertEqual(command.inputs, ["a.wav", "b.m4a", "c.mp3"])
        XCTAssertEqual(command.outputDir, "/tmp/out")
        XCTAssertEqual(command.format, .transcript)
    }

    func testSingleInputParsesAsOneElement() throws {
        let command = try TranscribeCommand.parse(["sample.wav"])
        XCTAssertEqual(command.inputs, ["sample.wav"])
        XCTAssertNil(command.outputDir)
    }

    func testRejectsEmptyInputs() {
        // A variadic positional argument requires at least one value — the
        // parser rejects an empty argument list before `run()`.
        XCTAssertThrowsError(try TranscribeCommand.parse([]))
    }

    func testExpandInputsDeduplicatesAndExpandsFolders() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-expand-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["lecture02.mp3", "lecture01.m4a", "notes.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let youtube = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"

        let resolved = TranscribeCommand.expandInputs([dir.path, youtube, youtube])

        // Folder expands to its supported files (name-sorted), txt excluded,
        // YouTube URL passes through once.
        XCTAssertEqual(resolved.count, 3)
        XCTAssertTrue(resolved[0].hasSuffix("lecture01.m4a"))
        XCTAssertTrue(resolved[1].hasSuffix("lecture02.mp3"))
        XCTAssertEqual(resolved.last, youtube)
    }

    func testExpandInputsDeduplicatesStandardizedLooseFilesAgainstFolders() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-expand-standardized-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("lecture01.mp3")
        try Data("x".utf8).write(to: file)

        let resolved = TranscribeCommand.expandInputs([dir.path, file.path])

        XCTAssertEqual(resolved, [file.standardizedFileURL.path])
    }

    func testSanitizedBasenameStripsExtensionAndInvalidCharacters() {
        XCTAssertEqual(TranscribeCommand.sanitizedBasename("lecture01.m4a"), "lecture01")
        XCTAssertEqual(TranscribeCommand.sanitizedBasename("a/b:c?.mp4"), "a_b_c_")
        XCTAssertEqual(TranscribeCommand.sanitizedBasename("bad\nname\t.mp3"), "bad_name_")
        XCTAssertEqual(TranscribeCommand.sanitizedBasename(""), "transcript")
    }

    func testSanitizedBasenameKeepsDotsInNonMediaTitles() {
        // Metadata-derived titles (e.g. YouTube) with a natural dot must not be
        // truncated by extension-stripping — only known media extensions strip.
        XCTAssertEqual(TranscribeCommand.sanitizedBasename("Dr. Smith Lecture 1"), "Dr. Smith Lecture 1")
        XCTAssertEqual(TranscribeCommand.sanitizedBasename("Q3 2026 review.final"), "Q3 2026 review.final")
    }

    func testWriteOutputWritesTranscriptAndAvoidsOverwrite() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-write-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcription = Transcription(
            fileName: "lecture01.m4a",
            rawTranscript: "hello world",
            status: .completed
        )

        let first = try TranscribeCommand.writeOutput(transcription, to: dir, format: .transcript)
        XCTAssertEqual(first.lastPathComponent, "lecture01.txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "hello world")

        // A second write of the same name must not clobber the first.
        let second = try TranscribeCommand.writeOutput(transcription, to: dir, format: .transcript)
        XCTAssertEqual(second.lastPathComponent, "lecture01-2.txt")
    }

    func testWriteOutputJSONIsParseable() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-write-json-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let transcription = Transcription(
            fileName: "clip.mp3",
            rawTranscript: "hi",
            status: .completed
        )
        let url = try TranscribeCommand.writeOutput(transcription, to: dir, format: .json)
        XCTAssertEqual(url.pathExtension, "json")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNotNil(object)
    }

    func testPlainTextOutputToleratesDuplicateSpeakerIDs() {
        let transcription = Transcription(
            fileName: "dupe-speakers.mp3",
            rawTranscript: "hello world",
            wordTimestamps: [
                WordTimestamp(word: "hello", startMs: 0, endMs: 400, confidence: 0.9, speakerId: "S1"),
                WordTimestamp(word: "world", startMs: 500, endMs: 900, confidence: 0.9, speakerId: "S1"),
            ],
            speakers: [
                SpeakerInfo(id: "S1", label: "Speaker 1"),
                SpeakerInfo(id: "S1", label: "Duplicate Speaker 1"),
            ],
            status: .completed
        )

        let output = TranscribeCommand.plainTextOutput(for: transcription)

        XCTAssertTrue(output.contains("Speaker 1:"))
        XCTAssertFalse(output.contains("Duplicate Speaker 1:"))
        XCTAssertTrue(output.contains("hello world"))
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-\(UUID().uuidString).db")
    }
}
