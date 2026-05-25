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

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-cli-\(UUID().uuidString).db")
    }
}
