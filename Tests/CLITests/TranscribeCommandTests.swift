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

    func testParsesWhisperEngineAndLanguage() throws {
        let command = try TranscribeCommand.parse([
            "sample.wav",
            "--engine", "whisper",
            "--language", "ko",
        ])

        XCTAssertEqual(command.engine, .whisper)
        XCTAssertEqual(command.language, "ko")
    }

    func testParsesYouTubeAudioQuality() throws {
        let command = try TranscribeCommand.parse([
            "https://www.youtube.com/watch?v=abc",
            "--youtube-audio-quality", "best-available",
        ])

        XCTAssertEqual(command.youtubeAudioQuality, .bestAvailable)
    }

    func testParakeetRemainsDefaultEngine() throws {
        let command = try TranscribeCommand.parse(["sample.wav"])
        XCTAssertEqual(command.engine, .parakeet)
        XCTAssertNil(command.language)
        XCTAssertEqual(command.youtubeAudioQuality, .appDefault)
    }

    func testLocalFileURLExpandsTilde() {
        let url = TranscribeCommand.localFileURL(for: "~/sample.wav")
        XCTAssertEqual(
            url.path,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("sample.wav").path
        )
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

        let exit = try XCTUnwrap(thrownError as? ExitCode)
        XCTAssertEqual(exit, .failure)
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
