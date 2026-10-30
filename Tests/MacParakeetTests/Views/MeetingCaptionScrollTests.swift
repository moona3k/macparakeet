import Foundation
import XCTest
@testable import MacParakeet

final class MeetingCaptionScrollTests: XCTestCase {
    func testRetainedRowTranslationGrowthPreservesManualReadingPosition() {
        var follow = AskScrollFollowState()
        _ = follow.update(content: CGRect(x: 0, y: -500, width: 800, height: 900), viewportHeight: 400)
        _ = follow.update(content: CGRect(x: 0, y: -200, width: 800, height: 900), viewportHeight: 400)
        XCTAssertFalse(follow.followsLatest)
        // A translation arrives for an existing retained row and adds three lines.
        XCTAssertFalse(follow.update(content: CGRect(x: 0, y: -200, width: 800, height: 980), viewportHeight: 400))
        XCTAssertFalse(follow.followsLatest)
        // Explicit scrolling back to the live edge resumes following future growth.
        _ = follow.update(content: CGRect(x: 0, y: -580, width: 800, height: 980), viewportHeight: 400)
        XCTAssertTrue(follow.update(content: CGRect(x: 0, y: -580, width: 800, height: 1020), viewportHeight: 400))
    }
}
