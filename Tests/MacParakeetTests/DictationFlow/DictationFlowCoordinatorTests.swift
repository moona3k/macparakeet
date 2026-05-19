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

    func testPasteFailureMessagePreservesAccessibilityCauseWhenCopied() {
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.accessibilityPermissionRequired,
            copiedToClipboard: true
        )

        XCTAssertEqual(
            message,
            "Accessibility permission is required for auto-paste. Copied to clipboard. Press Cmd+V."
        )
    }

    func testPasteFailureMessagePreservesAccessibilityCauseWhenNotCopied() {
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.accessibilityPermissionRequired,
            copiedToClipboard: false
        )

        XCTAssertEqual(
            message,
            "Accessibility permission is required for auto-paste, but the clipboard could not be updated."
        )
    }

    func testPasteFailureMessageReportsClipboardWriteFailureWhenNotCopied() {
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.pasteboardWriteFailed,
            copiedToClipboard: false
        )

        XCTAssertEqual(message, "Paste failed and the clipboard could not be updated.")
    }

    func testPasteFailureMessageStaysGenericWhenCopiedWithoutAccessibilityCause() {
        // A non-permission paste failure (e.g. CGEvent infrastructure) that still
        // landed on the clipboard must keep the generic copy - it must NOT claim
        // an Accessibility cause it cannot attribute.
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.eventSourceUnavailable,
            copiedToClipboard: true
        )

        XCTAssertEqual(message, "Copied to clipboard. Press Cmd+V.")
    }

    func testPasteFailureMessageDoesNotSuggestPasteWhenNotCopied() {
        let message = DictationFlowCoordinator.pasteFailureMessage(
            for: ClipboardServiceError.eventCreationFailed,
            copiedToClipboard: false
        )

        XCTAssertEqual(
            message,
            "Paste failed and the clipboard could not be updated."
        )
    }

    func testCommandFailureBucketSplitsClipboardPermissionFailure() {
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: ClipboardServiceError.accessibilityPermissionRequired),
            "paste_accessibility_permission"
        )
    }

    func testCommandFailureBucketSplitsClipboardInfrastructureFailures() {
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: ClipboardServiceError.eventSourceUnavailable),
            "paste_event_source_unavailable"
        )
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: ClipboardServiceError.eventCreationFailed),
            "paste_event_creation_failed"
        )
        XCTAssertEqual(
            DictationFlowCoordinator.commandFailureBucket(for: ClipboardServiceError.pasteboardWriteFailed),
            "pasteboard_write_failed"
        )
    }
}
