import XCTest

@testable import MacParakeetCore

final class DictationOverlayLayoutTests: XCTestCase {
    private let visible = CGRect(x: 100, y: 50, width: 1000, height: 700)
    private let panel = CGSize(width: 300, height: 160)

    func testBottomMatchesTheShippedBottomCenterPosition() {
        let origin = DictationOverlayLayout.origin(in: visible, panelSize: panel, placement: .bottom)

        XCTAssertEqual(origin.x, visible.midX - panel.width / 2)
        XCTAssertEqual(origin.y, visible.minY + 12)
    }

    func testTopCentersBelowTheUsableTopEdge() {
        let origin = DictationOverlayLayout.origin(in: visible, panelSize: panel, placement: .top)

        XCTAssertEqual(origin.x, visible.midX - panel.width / 2)
        XCTAssertEqual(origin.y, visible.maxY - panel.height - 12)
    }

    func testTopNeverDropsBelowTheUsableFrameOnAShortScreen() {
        let short = CGRect(x: 0, y: 40, width: 800, height: 100)

        let origin = DictationOverlayLayout.origin(in: short, panelSize: panel, placement: .top)

        XCTAssertEqual(origin.y, short.minY)
    }

    func testLeftCentersVerticallyOnTheLeftEdge() {
        let origin = DictationOverlayLayout.origin(in: visible, panelSize: panel, placement: .left)

        XCTAssertEqual(origin.x, visible.minX + 12)
        XCTAssertEqual(origin.y, visible.midY - panel.height / 2)
    }

    func testRightCentersVerticallyOnTheRightEdge() {
        let origin = DictationOverlayLayout.origin(in: visible, panelSize: panel, placement: .right)

        XCTAssertEqual(origin.x, visible.maxX - panel.width - 12)
        XCTAssertEqual(origin.y, visible.midY - panel.height / 2)
    }

    func testEdgeRectHugsEachEdgeCenteredAlongIt() {
        let size = CGSize(width: 400, height: 200)
        func rect(_ placement: DictationOverlayPlacement) -> CGRect {
            DictationOverlayLayout.edgeRect(length: 60, depth: 24, panelSize: size, placement: placement)
        }

        XCTAssertEqual(rect(.bottom), CGRect(x: 170, y: 0, width: 60, height: 24))
        XCTAssertEqual(rect(.top), CGRect(x: 170, y: 176, width: 60, height: 24))
        XCTAssertEqual(rect(.left), CGRect(x: 0, y: 70, width: 24, height: 60))
        XCTAssertEqual(rect(.right), CGRect(x: 376, y: 70, width: 24, height: 60))
    }

    func testDistanceAlongPillStartsAtTheLeftEndOnBottomAndTop() {
        let size = CGSize(width: 300, height: 160)
        for placement in [DictationOverlayPlacement.bottom, .top] {
            let along = DictationOverlayLayout.distanceAlongPill(
                from: CGPoint(x: 52.5 + 10, y: 20),
                pillLength: 195,
                panelSize: size,
                placement: placement
            )
            XCTAssertEqual(along, 10, "\(placement)")
        }
    }

    func testDistanceAlongPillStartsAtTheTopEndOnSideEdges() {
        let size = CGSize(width: 360, height: 240)
        let pillTop = (240 + 171) / 2.0
        for placement in [DictationOverlayPlacement.left, .right] {
            let nearTop = DictationOverlayLayout.distanceAlongPill(
                from: CGPoint(x: 30, y: pillTop - 5),
                pillLength: 171,
                panelSize: size,
                placement: placement
            )
            let nearBottom = DictationOverlayLayout.distanceAlongPill(
                from: CGPoint(x: 30, y: pillTop - 166),
                pillLength: 171,
                panelSize: size,
                placement: placement
            )
            XCTAssertEqual(nearTop, 5, "\(placement)")
            XCTAssertEqual(nearBottom, 166, "\(placement)")
        }
    }

    func testOnlyLeftAndRightAreVertical() {
        XCTAssertFalse(DictationOverlayPlacement.bottom.isVertical)
        XCTAssertFalse(DictationOverlayPlacement.top.isVertical)
        XCTAssertTrue(DictationOverlayPlacement.left.isVertical)
        XCTAssertTrue(DictationOverlayPlacement.right.isVertical)
        XCTAssertFalse(DictationOverlayPlacement.left.anchorsToTop)
        XCTAssertFalse(DictationOverlayPlacement.right.anchorsToTop)
    }

    func testUsableFrameKeepsVisibleFrameWhenTheMenuBarIsShown() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleWithMenuBar = CGRect(x: 0, y: 70, width: 1512, height: 875)

        let usable = DictationOverlayLayout.usableFrame(
            screenFrame: screen,
            visibleFrame: visibleWithMenuBar,
            topInset: 37
        )

        XCTAssertEqual(usable, visibleWithMenuBar)
    }

    func testUsableFrameReservesTheMenuBarWhenItAutoHidesOrTheAppIsFullScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleWithoutMenuBar = CGRect(x: 0, y: 70, width: 1512, height: 912)

        let usable = DictationOverlayLayout.usableFrame(
            screenFrame: screen,
            visibleFrame: visibleWithoutMenuBar,
            topInset: 37
        )

        XCTAssertEqual(usable.minY, 70)
        XCTAssertEqual(usable.maxY, 982 - 37)
        XCTAssertEqual(usable.minX, visibleWithoutMenuBar.minX)
        XCTAssertEqual(usable.width, visibleWithoutMenuBar.width)
    }

    func testStoredPlacementFallsBackToBottomForMissingOrUnknownValues() {
        let suite = makeIsolatedDefaultsSuite("overlay-placement-")
        let defaults = UserDefaults(suiteName: suite)!
        let key = UserDefaultsAppRuntimePreferences.dictationOverlayPlacementKey

        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .bottom)

        defaults.set("top", forKey: key)
        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .top)

        defaults.set("left", forKey: key)
        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .left)

        defaults.set("topLeft", forKey: key)
        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .bottom)
    }
}
