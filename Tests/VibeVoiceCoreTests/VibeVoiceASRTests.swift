import XCTest
@testable import VibeVoiceCore

/// Integration tests for `VibeVoiceASR`. Skipped when the model isn't
/// present at the expected path (~10 GB download, not committed).
/// Run locally after `scripts/dev/download_vibevoice_model.sh`.
final class VibeVoiceASRTests: XCTestCase {

    /// Where we expect the user to have placed the model. Same path
    /// the Phase 2.2 engine plumbing will use.
    private var modelDir: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("MacParakeet")
            .appendingPathComponent("models")
            .appendingPathComponent("vibevoice")
    }

    private var modelPath: URL { modelDir.appendingPathComponent("vibevoice-asr-q4_k.gguf") }
    private var tokenizerPath: URL { modelDir.appendingPathComponent("tokenizer.gguf") }

    private func skipIfModelMissing() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: modelPath.path),
              fm.fileExists(atPath: tokenizerPath.path) else {
            throw XCTSkip("VibeVoice model not installed at \(modelDir.path). Run scripts/dev/download_vibevoice_model.sh.")
        }
    }

    private func fixtureURL() throws -> URL {
        let url = Bundle.module.url(forResource: "tiny_ted", withExtension: "wav")
        guard let url else {
            throw XCTSkip("tiny_ted.wav not bundled in test resources")
        }
        return url
    }

    func testTranscribesShortClip() async throws {
        try skipIfModelMissing()
        let audio = try fixtureURL()

        let asr = VibeVoiceASR()
        try await asr.loadModel(modelPath: modelPath, tokenizerPath: tokenizerPath)
        let segments = try await asr.transcribe(wavPath: audio)
        await asr.unload()

        // The 5-second TED excerpt opens with "So in college, I was a
        // government major". We assert non-empty + at least one segment
        // mentions "college" — looser than asserting exact text since
        // quantized inference is non-deterministic at the token level.
        XCTAssertFalse(segments.isEmpty)
        let joinedText = segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(
            joinedText.contains("college"),
            "Expected 'college' in transcription; got: \(joinedText)"
        )
    }

    func testTranscribeWithoutLoadThrows() async throws {
        let audio = try fixtureURL()
        let asr = VibeVoiceASR()
        do {
            _ = try await asr.transcribe(wavPath: audio)
            XCTFail("Expected modelNotLoaded; got success")
        } catch VibeVoiceASRError.modelNotLoaded {
            // expected
        } catch {
            XCTFail("Expected modelNotLoaded; got: \(error)")
        }
    }

    func testTranscribeWithMissingAudioThrows() async throws {
        try skipIfModelMissing()
        let asr = VibeVoiceASR()
        try await asr.loadModel(modelPath: modelPath, tokenizerPath: tokenizerPath)
        defer { Task { await asr.unload() } }

        let bogusURL = URL(fileURLWithPath: "/tmp/does-not-exist.wav")
        do {
            _ = try await asr.transcribe(wavPath: bogusURL)
            XCTFail("Expected fileNotFound; got success")
        } catch VibeVoiceASRError.fileNotFound(let url) {
            XCTAssertEqual(url, bogusURL)
        } catch {
            XCTFail("Expected fileNotFound; got: \(error)")
        }
    }
}
