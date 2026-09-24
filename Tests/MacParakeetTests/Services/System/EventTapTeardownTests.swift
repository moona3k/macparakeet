import CoreFoundation
import XCTest

@testable import MacParakeetCore

final class EventTapTeardownTests: XCTestCase {
    // CGEvent taps need Input Monitoring permission, so exercise the teardown
    // on a plain Mach port: the leak in #1132 was a port that stayed valid.
    func testTearDownInvalidatesPortAndDetachesSource() throws {
        let port = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil))
        let source = try XCTUnwrap(CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0))
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)

        EventTapTeardown.tearDown(tap: port, source: source, runLoop: runLoop)

        XCTAssertFalse(CFMachPortIsValid(port))
        XCTAssertFalse(CFRunLoopSourceIsValid(source))
        XCTAssertFalse(CFRunLoopContainsSource(runLoop, source, .commonModes))
    }

    func testTearDownToleratesMissingPiecesAndRepeatedCalls() throws {
        let port = try XCTUnwrap(CFMachPortCreate(kCFAllocatorDefault, { _, _, _, _ in }, nil, nil))

        EventTapTeardown.tearDown(tap: nil, source: nil, runLoop: nil)
        EventTapTeardown.tearDown(tap: port, source: nil, runLoop: nil)
        EventTapTeardown.tearDown(tap: port, source: nil, runLoop: nil)

        XCTAssertFalse(CFMachPortIsValid(port))
    }
}
