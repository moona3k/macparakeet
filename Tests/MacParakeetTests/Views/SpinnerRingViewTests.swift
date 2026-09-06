import AppKit
import XCTest
@testable import MacParakeet

@MainActor
final class SpinnerRingViewTests: XCTestCase {
    func testStaticMerkabaShapeRetainsExpectedBounds() {
        let path = MerkabaShape().path(in: CGRect(x: 0, y: 0, width: 100, height: 100))

        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingRect.minX, 8, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.minY, 8, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxX, 92, accuracy: 0.001)
        XCTAssertEqual(path.boundingRect.maxY, 92, accuracy: 0.001)
    }

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
