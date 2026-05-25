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
