import XCTest
@testable import MacParakeetCore

final class DictationOverlayLayoutTests: XCTestCase {
    private let visible = CGRect(x: 100, y: 50, width: 1000, height: 700)
    private let panel = CGSize(width: 300, height: 160)

    func testBottomCenterMatchesCurrentIdleAndOverlayDefault() {
        let origin = DictationOverlayLayout.origin(
            in: visible,
            panelSize: panel,
            placement: .bottomCenter
        )
        XCTAssertEqual(origin.x, visible.midX - panel.width / 2)
        XCTAssertEqual(origin.y, visible.minY + 12)
    }

    func testBottomLeftAndRightStayInsideVisibleFrame() {
        let left = DictationOverlayLayout.origin(
            in: visible,
            panelSize: panel,
            placement: .bottomLeft
        )
        XCTAssertEqual(left.x, visible.minX + 12)
        XCTAssertEqual(left.y, visible.minY + 12)

        let right = DictationOverlayLayout.origin(
            in: visible,
            panelSize: panel,
            placement: .bottomRight
        )
        XCTAssertEqual(right.x, visible.maxX - panel.width - 12)
        XCTAssertEqual(right.y, visible.minY + 12)
    }

    func testTopPlacementsClearTheMenuBarViaVisibleFrame() {
        let top = DictationOverlayLayout.origin(
            in: visible,
            panelSize: panel,
            placement: .topCenter
        )
        XCTAssertEqual(top.x, visible.midX - panel.width / 2)
        XCTAssertEqual(top.y, visible.maxY - panel.height - 12)
        XCTAssertEqual(
            DictationOverlayLayout.origin(in: visible, panelSize: panel, placement: .topLeft).x,
            visible.minX + 12
        )
        XCTAssertEqual(
            DictationOverlayLayout.origin(in: visible, panelSize: panel, placement: .topRight).x,
            visible.maxX - panel.width - 12
        )
    }

    func testOriginClampsWhenThePanelIsWiderThanTheScreen() {
        let tiny = CGRect(x: 0, y: 0, width: 200, height: 100)
        let huge = CGSize(width: 400, height: 80)
        let origin = DictationOverlayLayout.origin(
            in: tiny,
            panelSize: huge,
            placement: .bottomRight
        )
        XCTAssertEqual(origin.x, tiny.minX)
        XCTAssertEqual(origin.y, tiny.minY + 12)
    }

    func testUnknownStoredRawValueFallsBackToBottomCenter() {
        let suite = "overlay-placement-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .bottomCenter)

        defaults.set("bottomLeft", forKey: UserDefaultsAppRuntimePreferences.dictationOverlayPlacementKey)
        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .bottomLeft)

        defaults.set("sideways", forKey: UserDefaultsAppRuntimePreferences.dictationOverlayPlacementKey)
        XCTAssertEqual(DictationOverlayPlacement.current(defaults: defaults), .bottomCenter)
    }
}
