import XCTest
import MacParakeetCore
@testable import MacParakeetViewModels

final class MeetingSourceLossNoticePolicyTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testUnavailableMicrophoneNotifiesOnceAfterThreshold() {
        var policy = MeetingSourceLossNoticePolicy(threshold: 10)
        let health = summary(microphone: .unavailable)

        XCTAssertNil(evaluate(&policy, health, at: 0))
        XCTAssertNil(evaluate(&policy, health, at: 9))
        let notice = evaluate(&policy, health, at: 10)
        XCTAssertEqual(notice?.source, .microphone)
        XCTAssertEqual(notice?.title, "This meeting may be missing your side")
        XCTAssertTrue(notice?.body.contains("will add your microphone if it reconnects") == true)
        XCTAssertNil(evaluate(&policy, health, at: 30))
    }

    func testRecoveryBeforeThresholdRestartsTheWait() {
        var policy = MeetingSourceLossNoticePolicy(threshold: 10)

        XCTAssertNil(evaluate(&policy, summary(microphone: .unavailable), at: 0))
        XCTAssertNil(evaluate(&policy, summary(microphone: .live), at: 8))
        XCTAssertNil(evaluate(&policy, summary(microphone: .interrupted), at: 12))
        XCTAssertNil(evaluate(&policy, summary(microphone: .interrupted), at: 21))
        let notice = evaluate(&policy, summary(microphone: .interrupted), at: 22)
        XCTAssertEqual(notice?.source, .microphone)
        XCTAssertTrue(notice?.body.contains("stopped recording") == true)
    }

    func testVisiblePanelDefersTheNoticeUntilItCloses() {
        var policy = MeetingSourceLossNoticePolicy(threshold: 10)
        let health = summary(microphone: .unavailable)

        XCTAssertNil(evaluate(&policy, health, at: 0, panelVisible: true))
        XCTAssertNil(evaluate(&policy, health, at: 15, panelVisible: true))
        XCTAssertEqual(evaluate(&policy, health, at: 16, panelVisible: false)?.source, .microphone)
    }

    func testPausedRecordingDoesNotAccumulateLossTime() {
        var policy = MeetingSourceLossNoticePolicy(threshold: 10)
        let health = summary(microphone: .unavailable)

        XCTAssertNil(evaluate(&policy, health, at: 0, activelyRecording: false))
        XCTAssertNil(evaluate(&policy, health, at: 20, activelyRecording: false))
        XCTAssertNil(evaluate(&policy, health, at: 21))
        XCTAssertNotNil(evaluate(&policy, health, at: 31))
    }

    func testSingleSourceMeetingsNeverNotify() {
        var policy = MeetingSourceLossNoticePolicy(threshold: 0)
        let health = MeetingCaptureHealthSummary(
            sourceMode: .systemOnly,
            microphone: MeetingSourceHealth(source: .microphone, status: .notSelected),
            system: MeetingSourceHealth(source: .system, status: .interrupted)
        )

        XCTAssertNil(evaluate(&policy, health, at: 0))
        XCTAssertNil(evaluate(&policy, health, at: 60))
    }

    func testRoutineStatesNeverNotify() {
        var policy = MeetingSourceLossNoticePolicy(threshold: 0)
        for status: MeetingSourceHealth.Status in [.starting, .live, .muted, .silent, .stalled, .recovering] {
            XCTAssertNil(evaluate(&policy, summary(microphone: status), at: 100), "\(status)")
        }
    }

    func testLostSystemAudioUsesOtherParticipantsCopy() {
        var policy = MeetingSourceLossNoticePolicy(threshold: 0)
        let health = summary(microphone: .live, system: .interrupted)

        let notice = evaluate(&policy, health, at: 0)
        XCTAssertEqual(notice?.source, .system)
        XCTAssertEqual(notice?.title, "This meeting may be missing other participants")
    }

    func testResetAllowsANoticeForTheNextRecording() {
        var policy = MeetingSourceLossNoticePolicy(threshold: 0)
        let health = summary(microphone: .unavailable)

        XCTAssertNotNil(evaluate(&policy, health, at: 0))
        XCTAssertNil(evaluate(&policy, health, at: 1))
        policy.reset()
        XCTAssertNotNil(evaluate(&policy, health, at: 2))
    }

    private func summary(
        microphone: MeetingSourceHealth.Status,
        system: MeetingSourceHealth.Status = .live
    ) -> MeetingCaptureHealthSummary {
        MeetingCaptureHealthSummary(
            sourceMode: .microphoneAndSystem,
            microphone: MeetingSourceHealth(source: .microphone, status: microphone),
            system: MeetingSourceHealth(source: .system, status: system)
        )
    }

    private func evaluate(
        _ policy: inout MeetingSourceLossNoticePolicy,
        _ health: MeetingCaptureHealthSummary,
        at seconds: TimeInterval,
        activelyRecording: Bool = true,
        panelVisible: Bool = false
    ) -> MeetingSourceLossNotice? {
        policy.evaluate(
            health: health,
            isActivelyRecording: activelyRecording,
            isPanelVisible: panelVisible,
            now: start.addingTimeInterval(seconds)
        )
    }
}
