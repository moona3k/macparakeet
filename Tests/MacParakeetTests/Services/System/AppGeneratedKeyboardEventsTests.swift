import AppKit
import Carbon
import XCTest
@testable import MacParakeetCore

@MainActor
final class AppGeneratedKeyboardEventsTests: XCTestCase {
    func testProductionPastePostsMarkedCommandLayoutPairAtSessionBoundary() throws {
        var posted: [(CGEvent, CGEventTapLocation)] = []
        let poster = CGClipboardEventPosting(
            isAccessibilityTrusted: { true },
            postEvent: { posted.append(($0, $1)) }
        )
        let data = Data([0]) as CFData
        let resolver = PasteShortcutKeyResolver(
            keyboardLayoutProvider: { .data(data) },
            translatedCharacterProvider: { _, code, modifiers, _ in
                // Deliberately not the US V key; the production poster must
                // resolve using its Command-modified layout.
                XCTAssertEqual(modifiers, UInt32(cmdKey >> 8))
                return code == 17 ? UniChar(118) : nil
            }
        )
        try poster.simulatePaste(using: resolver)

        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted.map { $0.0.type }, [.keyDown, .keyUp])
        for (event, location) in posted {
            XCTAssertEqual(location, .cgSessionEventTap)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 17)
            XCTAssertEqual(event.flags, .maskCommand)
            XCTAssertTrue(AppGeneratedEventMarker.isMarked(event))
            XCTAssertEqual(
                event.getIntegerValueField(.eventSourceStateID),
                Int64(CGEventSourceStateID.combinedSessionState.rawValue))
        }
    }

    func testProductionPostPasteActionAlsoUsesMarkedSessionPair() throws {
        var posted: [(CGEvent, CGEventTapLocation)] = []
        let poster = CGClipboardEventPosting(
            isAccessibilityTrusted: { true }, postEvent: { posted.append(($0, $1)) })
        try poster.simulateKeystroke(36)
        XCTAssertEqual(posted.map { $0.0.type }, [.keyDown, .keyUp])
        for (event, location) in posted {
            XCTAssertEqual(location, .cgSessionEventTap)
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 36)
            XCTAssertEqual(event.flags, [])
            XCTAssertTrue(AppGeneratedEventMarker.isMarked(event))
        }
    }

    func testPermissionFailureCannotPostPartOfAPair() {
        let poster = CGClipboardEventPosting(
            isAccessibilityTrusted: { false }, postEvent: { _, _ in XCTFail("must not post") })
        XCTAssertThrowsError(try poster.simulateKeystroke(36))
        XCTAssertThrowsError(try poster.simulatePaste(using: PasteShortcutKeyResolver()))
    }

    func testStreamingInterruptReplayPreservesUnmarkedInputAtSessionBoundary() throws {
        let key = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        let mouse = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: CGPoint(x: 40, y: 70), mouseButton: .left))
        for original in [key, mouse] {
            original.flags = .maskShift
            original.timestamp = 123_456_789
            original.setIntegerValueField(.eventSourceUserData, value: 123)
            var posted: CGEvent?
            var postCount = 0
            XCTAssertTrue(
                CGStreamingCursorEventPosting.replayInterceptedInput(original) { event, location in
                    XCTAssertEqual(location, .cgSessionEventTap)
                    posted = event
                    postCount += 1
                })
            XCTAssertEqual(postCount, 1)
            let replay = try XCTUnwrap(posted)
            XCTAssertFalse(replay === original)
            XCTAssertEqual(replay.type, original.type)
            XCTAssertEqual(replay.flags, original.flags)
            XCTAssertEqual(replay.timestamp, original.timestamp)
            XCTAssertEqual(replay.location, original.location)
            XCTAssertEqual(
                replay.getIntegerValueField(.keyboardEventKeycode),
                original.getIntegerValueField(.keyboardEventKeycode))
            XCTAssertEqual(replay.getIntegerValueField(.eventSourceUserData), 123)
            XCTAssertFalse(AppGeneratedEventMarker.isMarked(replay))
        }
    }

    func testStreamingMarkerRemainsCompatibleAndUnmarkedEventsStayUnmarked() throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        XCTAssertFalse(AppGeneratedEventMarker.isMarked(event))
        StreamingCursorEventMarker.mark(event)
        XCTAssertTrue(AppGeneratedEventMarker.isMarked(event))
        XCTAssertEqual(StreamingCursorEventMarker.userData, 0x4D50_5343)
        // Do not assume already-stamped source metadata can be overwritten.
        // Production stamps fresh events once, so model foreign input separately.
        let foreign = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true))
        foreign.setIntegerValueField(.eventSourceUserData, value: 123)
        XCTAssertEqual(foreign.getIntegerValueField(.eventSourceUserData), 123)
        XCTAssertFalse(AppGeneratedEventMarker.isMarked(foreign))
    }
}
