import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class DictationFlowCoordinatorTests: XCTestCase {
    func testMenuBarPreferenceMatchesStateMachineIntent() {
        XCTAssertEqual(DictationFlowCoordinator.menuBarPreference(for: .startingService(mode: .persistent)), .recording)
        XCTAssertEqual(DictationFlowCoordinator.menuBarPreference(for: .recording(mode: .holdToTalk)), .recording)
        XCTAssertEqual(DictationFlowCoordinator.menuBarPreference(for: .pendingStop(mode: .persistent)), .recording)
        XCTAssertEqual(DictationFlowCoordinator.menuBarPreference(for: .processing), .processing)
    }

    func testMenuBarPreferenceIsNilOutsideActiveStates() {
        let states: [DictationFlowState] = [
            .idle,
            .ready,
            .checkingEntitlements(mode: .persistent),
            .cancelCountdown,
            .finishing(outcome: .success),
            .finishing(outcome: .noSpeech),
            .finishing(outcome: .error("boom")),
            .finishing(outcome: .pasteFailedCopied("Copied to clipboard. Press Cmd+V.")),
        ]

        for state in states {
            XCTAssertNil(DictationFlowCoordinator.menuBarPreference(for: state), "Expected nil for \(state)")
        }
    }

    func testIsCapturingAudioTrueForCaptureAndProcessingStates() {
        XCTAssertTrue(DictationFlowCoordinator.isCapturingAudio(for: .startingService(mode: .persistent)))
        XCTAssertTrue(DictationFlowCoordinator.isCapturingAudio(for: .recording(mode: .holdToTalk)))
        XCTAssertTrue(DictationFlowCoordinator.isCapturingAudio(for: .pendingStop(mode: .persistent)))
        XCTAssertTrue(DictationFlowCoordinator.isCapturingAudio(for: .processing))
    }

    func testIsCapturingAudioFalseForNonCaptureStatesIncludingFinishing() {
        let states: [DictationFlowState] = [
            .idle,
            .ready,
            .checkingEntitlements(mode: .persistent),
            .cancelCountdown,
            .finishing(outcome: .success),
            .finishing(outcome: .noSpeech),
            .finishing(outcome: .error("boom")),
            .finishing(outcome: .pasteFailedCopied("Copied to clipboard. Press Cmd+V.")),
        ]

        for state in states {
            XCTAssertFalse(DictationFlowCoordinator.isCapturingAudio(for: state), "Expected false for \(state)")
        }
    }
}
