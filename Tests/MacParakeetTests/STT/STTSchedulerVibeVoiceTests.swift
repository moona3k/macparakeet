import XCTest
@testable import MacParakeetCore

final class STTSchedulerVibeVoiceTests: XCTestCase {

    func testEngineResolutionFollowsPreferences() {
        // Sanity check that preferences resolve correctly — the scheduler
        // delegates to this resolution.
        var prefs = SpeechEnginePreferences()
        prefs.global = .whisper
        prefs.dictation = .specific(.parakeet)

        XCTAssertEqual(prefs.engine(for: .dictation), .parakeet)
        XCTAssertEqual(prefs.engine(for: .fileTranscription), .whisper)
    }

    func testVibeVoiceDictationRoutesToBackgroundSlot() {
        // When dictation is configured with VibeVoice, the scheduler must
        // demote the job to the background slot — never claim the
        // reserved interactive slot. This is the guardrail that prevents
        // a 13s VibeVoice load from blocking dictation latency.
        let slot = STTScheduler.preferredSlot(for: .dictation, engine: .vibevoice)
        XCTAssertEqual(slot, .background)
    }

    func testParakeetDictationKeepsInteractiveSlot() {
        let slot = STTScheduler.preferredSlot(for: .dictation, engine: .parakeet)
        XCTAssertEqual(slot, .interactive)
    }

    func testWhisperDictationKeepsInteractiveSlot() {
        // Whisper is fast enough for dictation; only VibeVoice gets demoted.
        let slot = STTScheduler.preferredSlot(for: .dictation, engine: .whisper)
        XCTAssertEqual(slot, .interactive)
    }

    func testFileTranscriptionAlwaysGoesToBackgroundSlot() {
        XCTAssertEqual(STTScheduler.preferredSlot(for: .fileTranscription, engine: .parakeet), .background)
        XCTAssertEqual(STTScheduler.preferredSlot(for: .fileTranscription, engine: .whisper), .background)
        XCTAssertEqual(STTScheduler.preferredSlot(for: .fileTranscription, engine: .vibevoice), .background)
    }

    func testMeetingJobsAlwaysGoToBackgroundSlot() {
        for kind: STTJobKind in [.meetingFinalize, .meetingLiveChunk] {
            for engine: SpeechEnginePreference in [.parakeet, .whisper, .vibevoice] {
                XCTAssertEqual(
                    STTScheduler.preferredSlot(for: kind, engine: engine),
                    .background,
                    "\(kind) with \(engine) should be background"
                )
            }
        }
    }
}
