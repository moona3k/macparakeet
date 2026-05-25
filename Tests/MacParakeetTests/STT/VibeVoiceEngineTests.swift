import XCTest
@testable import MacParakeetCore
import VibeVoiceCore

final class VibeVoiceEngineTests: XCTestCase {

    private var modelDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MacParakeet")
            .appendingPathComponent("models")
            .appendingPathComponent("stt")
            .appendingPathComponent("vibevoice")
    }

    private func skipIfModelMissing() throws {
        let model = modelDir.appendingPathComponent("vibevoice-asr-q4_k.gguf")
        let tok = modelDir.appendingPathComponent("tokenizer.gguf")
        guard FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: tok.path) else {
            throw XCTSkip("VibeVoice model not installed at \(modelDir.path)")
        }
    }

    /// Returns a path to a 15-second 24 kHz mono WAV fixture. The Phase 2.1
    /// `VibeVoiceCoreTests` target bundles `tiny_ted.wav` — we look for it
    /// in the test bundle, otherwise skip (Task 16 can wire it up properly).
    private func fixtureURL() throws -> URL {
        if let url = Bundle(for: Self.self).url(forResource: "tiny_ted", withExtension: "wav") {
            return url
        }
        throw XCTSkip("tiny_ted.wav fixture not bundled in this test target")
    }

    func testWarmUpThrowsWhenModelMissing() async {
        let engine = VibeVoiceEngine(modelDirectory: URL(fileURLWithPath: "/tmp/nonexistent-vibevoice-\(UUID().uuidString)"))
        do {
            try await engine.warmUp()
            XCTFail("Expected an error; got success")
        } catch {
            // expected — any error type is OK as long as we throw
        }
    }

    func testTranscribeReturnsSegmentsAndVibeVoiceEngineTag() async throws {
        try skipIfModelMissing()
        let audio = try fixtureURL()

        let engine = VibeVoiceEngine(modelDirectory: modelDir)
        let result = try await engine.transcribe(audioPath: audio.path, job: .fileTranscription)

        XCTAssertEqual(result.engine, .vibevoice)
        XCTAssertNotNil(result.segments)
        XCTAssertFalse(result.segments!.isEmpty)
        // VibeVoice doesn't expose word-level timing — words list is empty.
        XCTAssertTrue(result.words.isEmpty)
        // Diarized — at least one segment should carry a speakerId.
        XCTAssertTrue(result.segments!.contains { $0.speakerId != nil })
        // engineVariant identifies the GGUF.
        XCTAssertEqual(result.engineVariant, "vibevoice-asr-q4_k")
    }

    func testTextIsJoinedFromSegments() async throws {
        try skipIfModelMissing()
        let audio = try fixtureURL()

        let engine = VibeVoiceEngine(modelDirectory: modelDir)
        let result = try await engine.transcribe(audioPath: audio.path, job: .fileTranscription)

        // text should be a non-empty join of the segments' text fields.
        XCTAssertFalse(result.text.isEmpty)
        for seg in result.segments ?? [] {
            XCTAssertTrue(result.text.contains(seg.text))
        }
    }
}
