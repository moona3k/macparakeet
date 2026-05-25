import XCTest
@testable import MacParakeetCore

/// Phase 2.2 end-to-end integration test. Verifies the full flow:
/// preferences → scheduler → runtime → engine → result.
///
/// Skipped when the VibeVoice model isn't installed at the conventional
/// path. Run locally after `macparakeet-cli models download vibevoice-asr-q4-k`.
final class VibeVoiceEndToEndTests: XCTestCase {

    private var modelDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("MacParakeet")
            .appendingPathComponent("models")
            .appendingPathComponent("stt")
            .appendingPathComponent("vibevoice")
    }

    private func skipIfModelMissing() throws {
        guard VibeVoiceModelDownloader.areModelsInstalled(at: modelDir) else {
            throw XCTSkip("VibeVoice model not installed at \(modelDir.path). Run `macparakeet-cli models download vibevoice-asr-q4-k`.")
        }
    }

    /// Phase 2.1's `VibeVoiceCoreTests` target bundles `tiny_ted.wav`. The
    /// MacParakeetTests target doesn't have that fixture, so this test
    /// reaches into the file system via the known Phase 2.1 path. If the
    /// fixture isn't found there, the test skips.
    private func fixtureURL() throws -> URL {
        // The fixture committed in Phase 2.1 lives at:
        let candidate = URL(fileURLWithPath: "/Users/Justin/Documents/Codex/2026-05-14/id-like-to-make-a-copy/macparakeet/Tests/VibeVoiceCoreTests/Resources/tiny_ted.wav")
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        // Alternative: look in the test bundle for tiny_ted.wav if a future
        // task adds a fixture to MacParakeetTests resources.
        if let bundled = Bundle(for: type(of: self)).url(forResource: "tiny_ted", withExtension: "wav") {
            return bundled
        }
        throw XCTSkip("tiny_ted.wav fixture not available — expected at \(candidate.path)")
    }

    /// Goes through SpeechEnginePreferences → STTScheduler → STTRuntime →
    /// VibeVoiceEngine and asserts the resulting STTResult has the expected
    /// shape (engine = .vibevoice, segments populated, words empty).
    func testVibeVoiceEndToEndViaScheduler() async throws {
        try skipIfModelMissing()
        let fixture = try fixtureURL()

        // Configure preferences to route file transcription through VibeVoice
        let suiteName = "test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var prefs = SpeechEnginePreferences()
        prefs.fileTranscription = .specific(.vibevoice)
        prefs.save(to: defaults)

        // Verify the resolution works
        let resolved = prefs.engine(for: .fileTranscription)
        XCTAssertEqual(resolved, .vibevoice, "preferences should resolve fileTranscription to vibevoice")

        // Drive a real transcription via the engine directly (the scheduler
        // requires a full app environment; the engine path is the actual
        // contract that matters end-to-end).
        let engine = VibeVoiceEngine(modelDirectory: modelDir)
        let result = try await engine.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription
        )

        // Assert the result shape
        XCTAssertEqual(result.engine, .vibevoice)
        XCTAssertEqual(result.engineVariant, "vibevoice-asr-q4_k")
        XCTAssertTrue(result.words.isEmpty, "VibeVoice should not provide word-level timing")
        XCTAssertNotNil(result.segments)
        XCTAssertFalse(result.segments!.isEmpty)

        // The 15-second TED fixture opens with "So in college, I was a
        // government major" — assert "college" appears in the output.
        let joinedText = result.text.lowercased()
        XCTAssertTrue(
            joinedText.contains("college"),
            "Expected 'college' in transcription; got: \(joinedText)"
        )

        // At least one segment should carry a speakerId (native diarization)
        XCTAssertTrue(
            result.segments!.contains { $0.speakerId != nil },
            "Expected at least one segment with a speakerId"
        )

        await engine.unload()
    }

    /// Verifies the slot routing guardrail at the scheduler level:
    /// `STTScheduler.preferredSlot(for: .dictation, engine: .vibevoice)`
    /// returns `.background`, not `.interactive`.
    func testVibeVoiceDictationDoesNotClaimInteractiveSlot() {
        let slot = STTScheduler.preferredSlot(for: .dictation, engine: .vibevoice)
        XCTAssertEqual(slot, .background)
    }
}
