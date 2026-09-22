import XCTest
@testable import MacParakeet

@MainActor
final class DictationOverlayChromeTests: XCTestCase {
    func testPersistentDictationRecordingUsesCompactSideInset() {
        XCTAssertEqual(
            DictationOverlayChrome.horizontalPadding(
                state: .recording,
                sessionKind: .dictation,
                recordingMode: .persistent,
                isReady: false,
                isIconOnly: false,
                isNoSpeechExpanded: false
            ),
            7
        )
    }

    func testHoldToTalkRecordingKeepsWideSideInset() {
        XCTAssertEqual(
            DictationOverlayChrome.horizontalPadding(
                state: .recording,
                sessionKind: .dictation,
                recordingMode: .holdToTalk,
                isReady: false,
                isIconOnly: false,
                isNoSpeechExpanded: false
            ),
            16
        )
    }

    func testCancelledUndoUsesCompactSideInset() {
        XCTAssertEqual(
            DictationOverlayChrome.horizontalPadding(
                state: .cancelled(timeRemaining: 3),
                sessionKind: .dictation,
                recordingMode: .persistent,
                isReady: false,
                isIconOnly: false,
                isNoSpeechExpanded: false
            ),
            7
        )
    }

    func testCancelledUndoUsesCompactSideInsetForHoldToTalkMode() {
        XCTAssertEqual(
            DictationOverlayChrome.horizontalPadding(
                state: .cancelled(timeRemaining: 3),
                sessionKind: .dictation,
                recordingMode: .holdToTalk,
                isReady: false,
                isIconOnly: false,
                isNoSpeechExpanded: false
            ),
            7
        )
    }

    func testCommandRecordingKeepsWideSideInset() {
        XCTAssertEqual(
            DictationOverlayChrome.horizontalPadding(
                state: .recording,
                sessionKind: .command,
                recordingMode: .persistent,
                isReady: false,
                isIconOnly: false,
                isNoSpeechExpanded: false
            ),
            16
        )
    }
}
