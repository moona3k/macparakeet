import XCTest

@testable import MacParakeetCore

final class MeetingSystemAudioSignalVerdictTests: XCTestCase {
    private typealias Verdict = MeetingSystemAudioSignalVerdict

    // MARK: - evaluate

    func testMicrophoneOnlyRecordingIsNotCaptured() {
        XCTAssertEqual(
            Verdict.evaluate(
                capturesSystemAudio: false,
                systemFirstBufferSeen: false,
                systemPeakLevel: 0
            ),
            .notCaptured
        )
    }

    func testStreamThatNeverDeliveredABufferIsNotCaptured() {
        XCTAssertEqual(
            Verdict.evaluate(
                capturesSystemAudio: true,
                systemFirstBufferSeen: false,
                systemPeakLevel: 0
            ),
            .notCaptured
        )
    }

    func testStreamWithSignalIsPresent() {
        XCTAssertEqual(
            Verdict.evaluate(
                capturesSystemAudio: true,
                systemFirstBufferSeen: true,
                systemPeakLevel: 0.42
            ),
            .present
        )
    }

    func testVeryQuietButNonZeroSignalIsStillPresent() {
        XCTAssertEqual(
            Verdict.evaluate(
                capturesSystemAudio: true,
                systemFirstBufferSeen: true,
                systemPeakLevel: .leastNormalMagnitude
            ),
            .present
        )
    }

    func testStreamThatDeliveredOnlyZeroSamplesIsSilent() {
        XCTAssertEqual(
            Verdict.evaluate(
                capturesSystemAudio: true,
                systemFirstBufferSeen: true,
                systemPeakLevel: 0
            ),
            .silent
        )
    }

    // MARK: - shouldWarn

    func testWarnsOnALongSilentMeetingWhereTheMicrophoneHadSignal() {
        XCTAssertTrue(
            Verdict.shouldWarn(
                verdict: .silent,
                microphonePeakLevel: 0.3,
                durationSeconds: 2_400
            )
        )
    }

    func testDoesNotWarnWhenTheSystemTrackHadSignal() {
        XCTAssertFalse(
            Verdict.shouldWarn(
                verdict: .present,
                microphonePeakLevel: 0.3,
                durationSeconds: 2_400
            )
        )
    }

    func testDoesNotWarnWhenSystemAudioWasNotPartOfTheRecording() {
        XCTAssertFalse(
            Verdict.shouldWarn(
                verdict: .notCaptured,
                microphonePeakLevel: 0.3,
                durationSeconds: 2_400
            )
        )
    }

    func testDoesNotWarnWhenNothingWasAudibleOnEitherSide() {
        XCTAssertFalse(
            Verdict.shouldWarn(
                verdict: .silent,
                microphonePeakLevel: 0,
                durationSeconds: 2_400
            )
        )
    }

    func testDoesNotWarnOnAShortClip() {
        XCTAssertFalse(
            Verdict.shouldWarn(
                verdict: .silent,
                microphonePeakLevel: 0.3,
                durationSeconds: 5
            )
        )
    }

    func testWarnsExactlyAtTheMinimumDuration() {
        XCTAssertTrue(
            Verdict.shouldWarn(
                verdict: .silent,
                microphonePeakLevel: 0.3,
                durationSeconds: Verdict.defaultMinimumWarningDurationSeconds
            )
        )
    }
}
