import XCTest
@testable import MacParakeet

@MainActor
final class AppDelegateMenuBarResolverTests: XCTestCase {
    func testResolveMenuBarStatePrioritizesMeetingRecording() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: true,
            isDictationCapturingAudio: false,
            isTranscribing: true
        )
        XCTAssertEqual(state, .recording)
    }

    func testResolveMenuBarStatePrioritizesDictationRecordingOverTranscribing() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: false,
            isDictationCapturingAudio: true,
            isTranscribing: true
        )
        XCTAssertEqual(state, .recording)
    }

    func testResolveMenuBarStateUsesProcessingWhenOnlyTranscribing() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: false,
            isDictationCapturingAudio: false,
            isTranscribing: true
        )
        XCTAssertEqual(state, .processing)
    }

    func testResolveMenuBarStateFallsBackToIdle() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: false,
            isDictationCapturingAudio: false,
            isTranscribing: false
        )
        XCTAssertEqual(state, .idle)
    }
}
