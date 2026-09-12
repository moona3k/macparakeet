import AppKit
import XCTest
@testable import MacParakeet

@MainActor
final class MainWindowLifecycleTests: XCTestCase {
    func testWindowWillCloseDetachesTrackedWindowAndReturnsItForDeferredCleanup() {
        var lifecycle = MainWindowLifecycle()
        let window = Self.makeWindow()
        lifecycle.opened(window)

        let returned = lifecycle.windowWillClose(window)

        XCTAssertTrue(returned === window)
        XCTAssertFalse(lifecycle.hasWindow)
        XCTAssertNil(lifecycle.window)
    }

    func testImmediateReopenAfterCloseTracksTheNewWindowInstance() {
        var lifecycle = MainWindowLifecycle()
        let firstWindow = Self.makeWindow()
        lifecycle.opened(firstWindow)
        _ = lifecycle.windowWillClose(firstWindow)

        let secondWindow = Self.makeWindow()
        lifecycle.opened(secondWindow)

        XCTAssertTrue(lifecycle.window === secondWindow)
    }

    func testStaleWindowWillCloseCannotClearAReplacementWindow() {
        var lifecycle = MainWindowLifecycle()
        let firstWindow = Self.makeWindow()
        lifecycle.opened(firstWindow)
        _ = lifecycle.windowWillClose(firstWindow)

        let secondWindow = Self.makeWindow()
        lifecycle.opened(secondWindow)

        // A late/duplicate close notification for the already-detached first
        // window must not be able to clear the replacement.
        let returned = lifecycle.windowWillClose(firstWindow)

        XCTAssertNil(returned)
        XCTAssertTrue(lifecycle.window === secondWindow)
    }

    func testWindowWillCloseForUntrackedWindowReturnsNil() {
        var lifecycle = MainWindowLifecycle()
        let trackedWindow = Self.makeWindow()
        lifecycle.opened(trackedWindow)

        let untrackedWindow = Self.makeWindow()
        let returned = lifecycle.windowWillClose(untrackedWindow)

        XCTAssertNil(returned)
        XCTAssertTrue(lifecycle.window === trackedWindow)
    }

    private static func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
    }
}
