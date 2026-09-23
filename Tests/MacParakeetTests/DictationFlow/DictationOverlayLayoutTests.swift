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
        let suite = "overlay-placement-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = UserDefaultsAppRuntimePreferences.dictationOverlayPlacementKey

        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .bottom)

        defaults.set("top", forKey: key)
        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .top)

        defaults.set("topLeft", forKey: key)
        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .bottom)
    }
}
