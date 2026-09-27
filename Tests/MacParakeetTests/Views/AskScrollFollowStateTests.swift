import Foundation
@testable import MacParakeet
import XCTest

final class AskScrollFollowStateTests: XCTestCase {
    func testGrowingAnswerKeepsFollowingUntilReaderScrollsUp() {
        var state = AskScrollFollowState()
        XCTAssertFalse(state.update(content: CGRect(x: 0, y: -400, width: 600, height: 1000), viewportHeight: 600))
        XCTAssertTrue(state.update(content: CGRect(x: 0, y: -400, width: 600, height: 1100), viewportHeight: 600))
        XCTAssertFalse(state.update(content: CGRect(x: 0, y: -500, width: 600, height: 1100), viewportHeight: 600))
        XCTAssertFalse(state.update(content: CGRect(x: 0, y: -250, width: 600, height: 1100), viewportHeight: 600))
        XCTAssertFalse(state.followsLatest)
        // A further tool result/Markdown layout must not move a reader reviewing earlier text.
        XCTAssertFalse(state.update(content: CGRect(x: 0, y: -250, width: 600, height: 1400), viewportHeight: 600))
        state.resume()
        XCTAssertTrue(state.update(content: CGRect(x: 0, y: -250, width: 600, height: 1400), viewportHeight: 600))
    }

    func testSmallUpwardGesturesEscapeBottomFollowing() {
        for distance: CGFloat in [2, 10, 30] {
            var state = AskScrollFollowState()
            _ = state.update(content: CGRect(x: 0, y: -500, width: 600, height: 1100), viewportHeight: 600)
            XCTAssertFalse(
                state.update(content: CGRect(x: 0, y: -500 + distance, width: 600, height: 1100), viewportHeight: 600))
            XCTAssertFalse(state.followsLatest)
            XCTAssertFalse(
                state.update(content: CGRect(x: 0, y: -500 + distance, width: 600, height: 1120), viewportHeight: 600))
        }
    }

    func testOpeningActivityDoesNotResumeOnContentGrowth() {
        var state = AskScrollFollowState()
        _ = state.update(content: CGRect(x: 0, y: -500, width: 600, height: 1100), viewportHeight: 600)
        state.pause()
        XCTAssertFalse(state.update(content: CGRect(x: 0, y: -500, width: 600, height: 1130), viewportHeight: 600))
        XCTAssertFalse(state.followsLatest)
    }

    func testReturningToBottomResumesAndNewConversationStartsFresh() {
        var state = AskScrollFollowState()
        _ = state.update(content: CGRect(x: 0, y: -500, width: 600, height: 1100), viewportHeight: 600)
        _ = state.update(content: CGRect(x: 0, y: -100, width: 600, height: 1100), viewportHeight: 600)
        XCTAssertFalse(state.followsLatest)
        _ = state.update(content: CGRect(x: 0, y: -480, width: 600, height: 1100), viewportHeight: 600)
        XCTAssertTrue(state.followsLatest)
        state.resume()
        XCTAssertFalse(state.update(content: CGRect(x: 0, y: 0, width: 600, height: 200), viewportHeight: 600))
        XCTAssertTrue(state.followsLatest)
    }
}
