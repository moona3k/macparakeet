import XCTest
@testable import MacParakeet

@MainActor
final class MerkabaPillIconViewTests: XCTestCase {
    func testRecordingReentryClearsHeldCompletionAnimations() {
        let view = MerkabaPillIconView(frame: NSRect(x: 0, y: 0, width: 30, height: 74))
        view.layoutSubtreeIfNeeded()

        view.playCompletion(reduceMotion: false) {}
        view.showMetatron(animated: true)
        XCTAssertFalse(view.testHook_rosetteCompletionAnimationKeys.isEmpty)

        view.update(isAnimating: true, audioLevel: 0)

        XCTAssertEqual(view.testHook_rosetteCompletionAnimationKeys, [])
        XCTAssertTrue(view.testHook_hasRecordingRotationAnimation)
    }

    func testRecordingUpdateRestartsMissingRotationAnimation() {
        let view = MerkabaPillIconView(frame: NSRect(x: 0, y: 0, width: 30, height: 74))
        view.layoutSubtreeIfNeeded()

        view.update(isAnimating: true, audioLevel: 0)
        XCTAssertTrue(view.testHook_hasRecordingRotationAnimation)

        view.testHook_removeRecordingRotationAnimation()
        XCTAssertFalse(view.testHook_hasRecordingRotationAnimation)

        view.update(isAnimating: true, audioLevel: 0)

        XCTAssertTrue(view.testHook_hasRecordingRotationAnimation)
    }
}
