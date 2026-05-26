import AppKit
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class DictationOverlayControllerTests: XCTestCase {
    private func mouseEvent(
        type: NSEvent.EventType,
        in view: NSView,
        localPoint: NSPoint
    ) -> NSEvent {
        let windowPoint = view.convert(localPoint, to: nil)
        return NSEvent.mouseEvent(
            with: type,
            location: windowPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    func testMouseTrackingViewHitTestConvertsSuperviewPointToLocalCoordinates() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let tracker = MouseTrackingView(frame: NSRect(x: 50, y: 60, width: 300, height: 160))
        parent.addSubview(tracker)

        var receivedPoint: NSPoint?
        tracker.shouldReceiveMouseDown = { point in
            receivedPoint = point
            return true
        }

        XCTAssertIdentical(parent.hitTest(NSPoint(x: 60, y: 75)), tracker)
        XCTAssertEqual(receivedPoint?.x, 10)
        XCTAssertEqual(receivedPoint?.y, 15)
    }

    func testMouseTrackingViewClicksOnMouseUpWhenPressAndReleaseStayInsideControlZone() {
        let tracker = MouseTrackingView(frame: NSRect(x: 50, y: 60, width: 300, height: 160))
        tracker.shouldReceiveMouseDown = { point in
            point.x >= 0 && point.x <= 100 && point.y >= 0 && point.y <= 100
        }

        var clickedPoint: NSPoint?
        tracker.onClick = { clickedPoint = $0 }

        tracker.mouseDown(with: mouseEvent(type: .leftMouseDown, in: tracker, localPoint: NSPoint(x: 20, y: 20)))
        tracker.mouseUp(with: mouseEvent(type: .leftMouseUp, in: tracker, localPoint: NSPoint(x: 25, y: 30)))

        XCTAssertEqual(clickedPoint?.x, 25)
        XCTAssertEqual(clickedPoint?.y, 30)
    }

    func testMouseTrackingViewDoesNotClickWhenMouseUpLeavesControlZone() {
        let tracker = MouseTrackingView(frame: NSRect(x: 50, y: 60, width: 300, height: 160))
        tracker.shouldReceiveMouseDown = { point in
            point.x >= 0 && point.x <= 100 && point.y >= 0 && point.y <= 100
        }

        var clickCount = 0
        tracker.onClick = { _ in clickCount += 1 }

        tracker.mouseDown(with: mouseEvent(type: .leftMouseDown, in: tracker, localPoint: NSPoint(x: 20, y: 20)))
        tracker.mouseUp(with: mouseEvent(type: .leftMouseUp, in: tracker, localPoint: NSPoint(x: 150, y: 20)))

        XCTAssertEqual(clickCount, 0)
    }

    func testDictationOverlayPanelCannotBecomeKeyOrMain() {
        let panel = DictationOverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: true
        )

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
    }

    func testControlHitTestingTargetsCancelAndStopZonesInVisibleControlRow() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 160)

        XCTAssertEqual(
            DictationOverlayControlHitTesting.target(
                at: NSPoint(x: 50, y: 25),
                in: bounds,
                overlayState: .recording,
                recordingMode: .persistent,
                requiresVisibleControlRow: true
            ),
            .cancel
        )
        XCTAssertEqual(
            DictationOverlayControlHitTesting.target(
                at: NSPoint(x: 250, y: 25),
                in: bounds,
                overlayState: .recording,
                recordingMode: .persistent,
                requiresVisibleControlRow: true
            ),
            .stop
        )
        XCTAssertNil(
            DictationOverlayControlHitTesting.target(
                at: NSPoint(x: 150, y: 25),
                in: bounds,
                overlayState: .recording,
                recordingMode: .persistent,
                requiresVisibleControlRow: true
            )
        )
    }

    func testClickHitTestingIgnoresTransparentSpaceAboveVisibleControls() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 160)

        XCTAssertNil(
            DictationOverlayControlHitTesting.target(
                at: NSPoint(x: 250, y: 100),
                in: bounds,
                overlayState: .recording,
                recordingMode: .persistent,
                requiresVisibleControlRow: true
            )
        )
    }

    func testControlHitTestingIgnoresBoundsNarrowerThanPill() {
        XCTAssertNil(
            DictationOverlayControlHitTesting.target(
                at: NSPoint(x: 10, y: 25),
                in: NSRect(x: 0, y: 0, width: 200, height: 160),
                overlayState: .recording,
                recordingMode: .persistent,
                requiresVisibleControlRow: true
            )
        )
    }

    func testControlHitTestingIgnoresNonPersistentRecordingStates() {
        let bounds = NSRect(x: 0, y: 0, width: 300, height: 160)
        let stopPoint = NSPoint(x: 250, y: 25)

        XCTAssertNil(
            DictationOverlayControlHitTesting.target(
                at: stopPoint,
                in: bounds,
                overlayState: .recording,
                recordingMode: .holdToTalk,
                requiresVisibleControlRow: true
            )
        )
        XCTAssertNil(
            DictationOverlayControlHitTesting.target(
                at: stopPoint,
                in: bounds,
                overlayState: .processing,
                recordingMode: .persistent,
                requiresVisibleControlRow: true
            )
        )
    }
}
