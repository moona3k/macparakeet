import Foundation
import XCTest
@testable import MacParakeetCore

final class MeetingSourceStartupHealthTests: XCTestCase {
    func testPendingMicrophoneDoesNotMakeHealthySystemUnavailable() {
        let health = summary(state: .starting)
        XCTAssertEqual(health.microphone.status, .starting)
        XCTAssertEqual(health.system.status, .live)
    }

    func testUnavailablePendingMicrophoneCanBecomeLiveWithoutInterruptionRecovery() {
        let unavailable = summary(state: .unavailable)
        XCTAssertEqual(unavailable.microphone.status, .unavailable)
        XCTAssertNil(unavailable.microphone.recoveryAction)
        XCTAssertEqual(summary(state: .ready, microphoneDelivered: true).microphone.status, .live)
    }

    func testLateProcessingReportIsNotRequiredToRecognizeMicrophoneFrames() {
        XCTAssertEqual(summary(state: .ready, microphoneDelivered: true).microphone.status, .live)
    }

    func testDefinitiveInterruptionWinsOverStaleStartupState() {
        XCTAssertEqual(summary(state: .starting, interrupted: [.microphone]).microphone.status, .interrupted)
    }

    private func summary(
        state: MeetingAudioCaptureSourceStartupState,
        microphoneDelivered: Bool = false,
        interrupted: Set<AudioSource> = []
    ) -> MeetingCaptureHealthSummary {
        var buffers: [AudioSource: Date] = [.system: Date()]
        if microphoneDelivered { buffers[.microphone] = Date() }
        return MeetingCaptureHealthSummary.reduce(
            sourceMode: .microphoneAndSystem,
            microphoneLevel: 0.5,
            systemLevel: 0.5,
            lastBufferAt: buffers,
            isMicrophoneMuted: false,
            microphoneStarted: false,
            interruptedSources: interrupted,
            activeMicrophoneStall: nil,
            microphoneBufferDeliveryTimedOut: false,
            systemBufferDeliveryTimedOut: false,
            captureFailed: false,
            startupStates: [.microphone: state, .system: .ready]
        )
    }
}
