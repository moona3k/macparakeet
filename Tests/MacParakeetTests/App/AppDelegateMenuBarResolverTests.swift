import XCTest
@testable import MacParakeet

@MainActor
final class AppDelegateMenuBarResolverTests: XCTestCase {
    func testResolveMenuBarStatePrioritizesMeetingRecording() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: true,
            dictationMenuBarPreference: .processing,
            isTranscribing: true
        )
        XCTAssertEqual(state, .recording)
    }

    func testResolveMenuBarStatePrioritizesDictationRecordingOverTranscribing() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: false,
            dictationMenuBarPreference: .recording,
            isTranscribing: true
        )
        XCTAssertEqual(state, .recording)
    }

    func testResolveMenuBarStateUsesDictationProcessingWhenPreferred() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: false,
            dictationMenuBarPreference: .processing,
            isTranscribing: false
        )
        XCTAssertEqual(state, .processing)
    }

    func testResolveMenuBarStateUsesProcessingWhenOnlyTranscribing() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: false,
            dictationMenuBarPreference: nil,
            isTranscribing: true
        )
        XCTAssertEqual(state, .processing)
    }

    func testResolveMenuBarStateFallsBackToIdle() {
        let state = AppDelegate.resolveMenuBarState(
            isMeetingRecordingActive: false,
            dictationMenuBarPreference: nil,
            isTranscribing: false
        )
        XCTAssertEqual(state, .idle)
    }
}
