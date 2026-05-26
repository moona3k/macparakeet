import XCTest
@testable import MacParakeetCore

final class STTRuntimeVibeVoiceTests: XCTestCase {

    func testVibeVoiceEngineIsLazyInitiallyAbsent() async {
        let runtime = STTRuntime()
        let present = await runtime.hasLoadedVibeVoiceEngine
        XCTAssertFalse(present, "VibeVoice engine should not be loaded until ensureVibeVoiceLoaded() is called")
    }

    func testEnsureVibeVoiceMakesEnginePresent() async throws {
        let runtime = STTRuntime()
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacParakeet/models/stt/vibevoice")
        // Skip if model isn't installed — same pattern as VibeVoiceEngineTests
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("vibevoice-asr-q4_k.gguf").path) else {
            throw XCTSkip("VibeVoice model missing; can't test ensureVibeVoiceLoaded end-to-end")
        }

        try await runtime.ensureVibeVoiceLoaded()
        let present = await runtime.hasLoadedVibeVoiceEngine
        XCTAssertTrue(present)
    }

    func testVibeVoiceMethodThrowsBeforeWarmUp() async {
        let runtime = STTRuntime()
        do {
            _ = try await runtime.vibevoice()
            XCTFail("Expected error when calling vibevoice() before warm-up")
        } catch {
            // expected — should throw modelNotLoaded or similar
        }
    }
}

final class STTRuntimeVibeVoiceChunkingTests: XCTestCase {

    /// Audio shorter than the threshold goes through the single-shot engine
    /// path and tags engineVariant accordingly.
    func testShortAudioUsesSingleShotPath() async throws {
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath:
                VibeVoiceEngine.defaultModelDirectory()
                    .appendingPathComponent("vibevoice-asr-q4_k.gguf").path),
            "VibeVoice model not installed"
        )

        // tiny_ted.wav is 15 s — well under the 450 s threshold.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VibeVoiceCoreTests/Resources/tiny_ted.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path),
                          "tiny_ted.wav not present")

        // Runtime lazily constructs the VibeVoice engine inside
        // transcribeWithVibeVoice, so no explicit warmUp() is needed and
        // we avoid touching the Parakeet path that the default engine
        // preference would otherwise warm.
        let runtime = STTRuntime()
        let selection = SpeechEngineSelection(engine: .vibevoice, language: nil)
        let result = try await runtime.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            speechEngine: selection,
            onProgress: nil
        )
        XCTAssertEqual(result.engineVariant, "vibevoice-asr-q4_k",
                       "15-s audio should NOT be routed through the chunker")
    }
}
