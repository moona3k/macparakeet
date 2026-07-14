import AppKit
import XCTest
@testable import MacParakeet

@MainActor
final class SpinnerRingViewTests: XCTestCase {
    func testAnimatedSpinnerUsesCoreAnimationLayers() {
        let view = SpinnerRingNSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))

        view.update(size: 14, revolutionDuration: 2, tint: .labelColor, animate: true)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.testHook_hasRenderableGeometry)
        XCTAssertEqual(
            view.testHook_activeAnimationKeys,
            ["center.pulse", "clockwise.spin", "counterclockwise.spin", "vertices.pulse"]
        )
    }

    func testStaticSpinnerKeepsGeometryWithoutActiveAnimations() {
        let view = SpinnerRingNSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        view.update(size: 14, revolutionDuration: 2, tint: .labelColor, animate: true)

        view.update(size: 14, revolutionDuration: 2, tint: .labelColor, animate: false)
        view.layoutSubtreeIfNeeded()

        XCTAssertTrue(view.testHook_hasRenderableGeometry)
        XCTAssertEqual(view.testHook_activeAnimationKeys, [])
    }

    func testDismantledSpinnerRemovesInfiniteAnimations() {
        let view = SpinnerRingNSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        view.update(size: 14, revolutionDuration: 2, tint: .labelColor, animate: true)

        view.dismantle()

        XCTAssertEqual(view.testHook_activeAnimationKeys, [])
    }

    func testChangingRevolutionDurationRetimesOnlyRotations() {
        let view = SpinnerRingNSView(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        view.update(size: 14, revolutionDuration: 2, tint: .labelColor, animate: true)

        view.update(size: 14, revolutionDuration: 3.2, tint: .labelColor, animate: true)

        XCTAssertEqual(
            view.testHook_animationDurations,
            [
                "center.pulse": 1.4,
                "clockwise.spin": 3.2,
                "counterclockwise.spin": 3.2,
                "vertices.pulse": 1.0,
            ]
        )
    }
}
