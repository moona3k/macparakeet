import AppKit
import XCTest
@testable import MacParakeet

@MainActor
final class OverlayHostingContainerViewTests: XCTestCase {
    func testOverlayIsAddedAsSiblingAboveHostingView() {
        let hostingView = NSView()
        let overlayView = NSView()

        let container = OverlayHostingContainerView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 160),
            hostingView: hostingView,
            overlayView: overlayView
        )

        XCTAssertEqual(container.subviews.count, 2)
        XCTAssertTrue(container.subviews[0] === hostingView)
        XCTAssertTrue(container.subviews[1] === overlayView)
    }

    func testHostingAndOverlayFillContainerBounds() {
        let hostingView = NSView()
        let overlayView = NSView()

        let container = OverlayHostingContainerView(
            frame: NSRect(x: 0, y: 0, width: 350, height: 90),
            hostingView: hostingView,
            overlayView: overlayView
        )

        XCTAssertEqual(hostingView.frame, container.bounds)
        XCTAssertEqual(overlayView.frame, container.bounds)
        XCTAssertEqual(hostingView.autoresizingMask, [.width, .height])
        XCTAssertEqual(overlayView.autoresizingMask, [.width, .height])
    }
}
