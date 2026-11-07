import XCTest

@testable import MacParakeetCore

final class NotchGeometryTests: XCTestCase {
    // MARK: Fixtures

    private func notched(
        id: UInt32, width: CGFloat, height: CGFloat, top: CGFloat, notchWidth: CGFloat, origin: CGPoint = .zero
    ) -> OverlayDisplay {
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        let side = (width - notchWidth) / 2
        let left = CGRect(x: frame.minX, y: frame.maxY - top, width: side, height: top)
        let right = CGRect(x: frame.maxX - side, y: frame.maxY - top, width: side, height: top)
        return OverlayDisplay(
            id: id,
            cutout: DisplayCutout.classify(
                frame: frame, safeAreaTop: top, auxiliaryTopLeft: left, auxiliaryTopRight: right, isBuiltIn: true)
        )
    }

    private var mbp14: OverlayDisplay { notched(id: 1, width: 1512, height: 982, top: 38, notchWidth: 184) }
    private var mbp16: OverlayDisplay { notched(id: 1, width: 1728, height: 1117, top: 38, notchWidth: 200) }
    private var air13: OverlayDisplay { notched(id: 1, width: 1470, height: 956, top: 37, notchWidth: 180) }
    private var islandHardware: OverlayDisplay { notched(id: 1, width: 1600, height: 1000, top: 32, notchWidth: 80) }
    private func external(id: UInt32 = 2) -> OverlayDisplay {
        OverlayDisplay(
            id: id,
            cutout: DisplayCutout.classify(
                frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), safeAreaTop: 0,
                auxiliaryTopLeft: nil, auxiliaryTopRight: nil, isBuiltIn: false))
    }
    private var plainBuiltIn: OverlayDisplay {
        OverlayDisplay(
            id: 1,
            cutout: DisplayCutout.classify(
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900), safeAreaTop: 0,
                auxiliaryTopLeft: nil, auxiliaryTopRight: nil, isBuiltIn: true))
    }

    private func geometry(_ display: OverlayDisplay) throws -> NotchGeometry {
        guard case .notch(let g) = display.cutout else {
            XCTFail("expected a notch, got \(display.cutout)")
            throw NSError(domain: "test", code: 0)
        }
        return g
    }

    // MARK: Classification

    func testNotched14InchRect() throws {
        let g = try geometry(mbp14)
        XCTAssertEqual(g.notchRect, CGRect(x: 664, y: 944, width: 184, height: 38))
        XCTAssertEqual(g.notchRect.midX, 756)
    }

    func testNotched16InchRect() throws {
        let g = try geometry(mbp16)
        XCTAssertEqual(g.notchRect, CGRect(x: 764, y: 1079, width: 200, height: 38))
    }

    func testAirIsANotch() throws {
        let g = try geometry(air13)
        XCTAssertEqual(g.notchRect.width, 180)
        XCTAssertEqual(g.notchRect.height, 37)
    }

    func testNoNotchOnPlainBuiltInOrExternal() {
        XCTAssertEqual(plainBuiltIn.cutout, .none)
        XCTAssertEqual(external().cutout, .none)
    }

    func testExternalDisplayWithInsetsIsNeverANotch() {
        let frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let cutout = DisplayCutout.classify(
            frame: frame, safeAreaTop: 38,
            auxiliaryTopLeft: CGRect(x: 0, y: 1042, width: 868, height: 38),
            auxiliaryTopRight: CGRect(x: 1052, y: 1042, width: 868, height: 38),
            isBuiltIn: false)
        XCTAssertEqual(cutout, .none)
    }

    func testNarrowCutoutIsNotANotch() {
        XCTAssertEqual(islandHardware.cutout, .narrowCutout)
    }

    // MARK: Panel frame

    func testPanelFrameIsCentredOnNotchAndFlushWithTop() throws {
        let g = try geometry(mbp14)
        let frame = g.panelFrame(expandedWidth: 360, height: 38)
        XCTAssertEqual(frame.midX, g.notchRect.midX)
        XCTAssertEqual(frame.maxY, 982)
        XCTAssertEqual(frame.width, 360)
    }

    func testPanelFrameNeverNarrowerThanNotchOrShorterThanNotch() throws {
        let g = try geometry(mbp14)
        let frame = g.panelFrame(expandedWidth: 10, height: 5)
        XCTAssertEqual(frame.width, 184)
        XCTAssertEqual(frame.height, 38)
    }

    func testPanelWidthCappedPerSide() throws {
        let g = try geometry(mbp14)
        let frame = g.panelFrame(expandedWidth: 5000, height: 38)
        XCTAssertEqual(frame.width, 184 + 2 * NotchGeometry.maxSideExtension)
        XCTAssertEqual(g.maxExpandedWidth, frame.width)
    }

    func testPanelCapBoundedByRealRoomBesideNotch() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let g = NotchGeometry(
            screenFrame: frame, notchRect: CGRect(x: 110, y: 170, width: 80, height: 30),
            leftAuxiliaryWidth: 50, rightAuxiliaryWidth: 110)
        XCTAssertEqual(g.sideExtensionLimit, 50)
    }

    func testNotchOnSecondaryOriginScreen() throws {
        let display = notched(id: 3, width: 1512, height: 982, top: 38, notchWidth: 184, origin: CGPoint(x: -1512, y: 100))
        let g = try geometry(display)
        let frame = g.panelFrame(expandedWidth: 300, height: 38)
        XCTAssertEqual(frame.midX, -1512 + 756)
        XCTAssertEqual(frame.maxY, 1082)
    }

    // MARK: Resolver

    func testBottomAndTopAreUnchangedOnANotchedMac() {
        for placement in [DictationOverlayPlacement.bottom, .top] {
            let surface = OverlaySurfaceResolver.resolve(
                placement: placement, displays: [mbp14], menuBarDisplayID: 1)
            XCTAssertEqual(surface, .edgePanel(placement: placement, displayID: 1))
        }
    }

    func testNotchedBuiltInUsesNotchPanel() throws {
        for display in [mbp14, mbp16, air13] {
            let surface = OverlaySurfaceResolver.resolve(
                placement: .notch, displays: [display], menuBarDisplayID: 1)
            XCTAssertEqual(surface, .notchPanel(displayID: 1, geometry: try geometry(display)))
        }
    }

    func testNoNotchFallsBackToTop() {
        let surface = OverlaySurfaceResolver.resolve(
            placement: .notch, displays: [plainBuiltIn], menuBarDisplayID: 1)
        XCTAssertEqual(surface, .edgePanel(placement: .top, displayID: 1))
    }

    func testClamshellFallsBackToTopOnExternalMenuBarDisplay() {
        // Lid closed: the built-in display is not in the active list.
        let surface = OverlaySurfaceResolver.resolve(
            placement: .notch, displays: [external()], menuBarDisplayID: 2)
        XCTAssertEqual(surface, .edgePanel(placement: .top, displayID: 2))
    }

    func testExternalMainDisplayFallsBackEvenWhenNotchedBuiltInIsAttached() {
        let surface = OverlaySurfaceResolver.resolve(
            placement: .notch, displays: [mbp14, external()], menuBarDisplayID: 2)
        XCTAssertEqual(surface, .edgePanel(placement: .top, displayID: 2))
    }

    func testNotchedBuiltInAsMenuBarDisplayWithExternalAttached() throws {
        let surface = OverlaySurfaceResolver.resolve(
            placement: .notch, displays: [mbp14, external()], menuBarDisplayID: 1)
        XCTAssertEqual(surface, .notchPanel(displayID: 1, geometry: try geometry(mbp14)))
    }

    func testAutoHideMenuBarStillUsesNotchPanel() throws {
        // Auto-hide changes visibleFrame only; the resolver input has none, and
        // the notch is physical, so the result must be the same.
        let surface = OverlaySurfaceResolver.resolve(
            placement: .notch, displays: [mbp16], menuBarDisplayID: 1)
        XCTAssertEqual(surface, .notchPanel(displayID: 1, geometry: try geometry(mbp16)))
    }

    func testDynamicIslandHardwareFallsBackToTop() {
        let surface = OverlaySurfaceResolver.resolve(
            placement: .notch, displays: [islandHardware], menuBarDisplayID: 1)
        XCTAssertEqual(surface, .edgePanel(placement: .top, displayID: 1))
    }

    func testNoDisplaysFallsBackToTop() {
        let surface = OverlaySurfaceResolver.resolve(placement: .notch, displays: [], menuBarDisplayID: nil)
        XCTAssertEqual(surface, .edgePanel(placement: .top, displayID: nil))
    }

    func testOffersNotchOnlyWhenARealNotchExists() {
        XCTAssertTrue(OverlaySurfaceResolver.offersNotch(displays: [mbp14, external()]))
        XCTAssertFalse(OverlaySurfaceResolver.offersNotch(displays: [plainBuiltIn, external()]))
        XCTAssertFalse(OverlaySurfaceResolver.offersNotch(displays: [islandHardware]))
        XCTAssertFalse(OverlaySurfaceResolver.offersNotch(displays: []))
    }

    func testNotchPlacementAnchorsToTopAndRawValueRoundTrips() {
        XCTAssertTrue(DictationOverlayPlacement.notch.anchorsToTop)
        XCTAssertEqual(DictationOverlayPlacement(rawValue: "notch"), .notch)
        XCTAssertEqual(DictationOverlayPlacement.notch.displayTitle, "Around the notch")
    }
}
