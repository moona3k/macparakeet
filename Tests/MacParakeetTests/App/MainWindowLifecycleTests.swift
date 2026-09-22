import AppKit
import SwiftUI
import XCTest
@testable import MacParakeet

@MainActor
final class MainWindowLifecycleTests: XCTestCase {
    func testCloseRetainsHostingContentUntilDeferredCleanup() async {
        var lifecycle = MainWindowLifecycle()
        let window = Self.makeWindow()
        let content = NSHostingView(rootView: Text("Closing"))
        window.contentView = content
        lifecycle.opened(window)

        XCTAssertTrue(lifecycle.windowWillClose(window) === window)
        XCTAssertNil(lifecycle.window)
        XCTAssertFalse(lifecycle.hasWindow)
        XCTAssertTrue(window.contentView === content)

        await Self.drainMainQueue()
        XCTAssertNil(window.contentView)
    }

    func testDeferredCleanupRetainsDetachedWindow() async {
        var lifecycle = MainWindowLifecycle()
        weak var closingWindow: NSWindow?
        autoreleasepool {
            let window = Self.makeWindow()
            window.contentView = NSHostingView(rootView: Text("Closing"))
            closingWindow = window
            lifecycle.opened(window)
            lifecycle.windowWillClose(window)
        }
        // No caller or lifecycle retains the window now; queued cleanup must.
        XCTAssertNotNil(closingWindow)
        XCTAssertNotNil(closingWindow?.contentView)

        await Self.drainMainQueue()
        // AppKit may retain the window internally; either way its content is gone.
        XCTAssertNil(closingWindow?.contentView)
    }

    func testImmediateReopenAndDuplicateClosePreserveReplacementContent() async {
        var lifecycle = MainWindowLifecycle()
        let first = Self.makeWindow()
        first.contentView = NSHostingView(rootView: Text("First"))
        lifecycle.opened(first)
        lifecycle.windowWillClose(first)

        let replacement = Self.makeWindow()
        let replacementContent = NSHostingView(rootView: Text("Replacement"))
        replacement.contentView = replacementContent
        lifecycle.opened(replacement)
        XCTAssertNil(lifecycle.windowWillClose(first))
        XCTAssertTrue(lifecycle.window === replacement)
        XCTAssertTrue(replacement.contentView === replacementContent)

        await Self.drainMainQueue()
        XCTAssertNil(first.contentView)
        XCTAssertTrue(lifecycle.window === replacement)
        XCTAssertTrue(replacement.contentView === replacementContent)

        // Once the original cleanup has run, stale notifications must not queue
        // another teardown of that window either.
        let restoredContent = NSHostingView(rootView: Text("Restored"))
        first.contentView = restoredContent
        XCTAssertNil(lifecycle.windowWillClose(first))
        await Self.drainMainQueue()
        XCTAssertTrue(first.contentView === restoredContent)
        XCTAssertTrue(replacement.contentView === replacementContent)
    }

    func testUntrackedCloseLeavesBothWindowsContentUntouched() async {
        var lifecycle = MainWindowLifecycle()
        let tracked = Self.makeWindow()
        let trackedContent = NSHostingView(rootView: Text("Tracked"))
        tracked.contentView = trackedContent
        lifecycle.opened(tracked)
        let untracked = Self.makeWindow()
        let untrackedContent = NSHostingView(rootView: Text("Untracked"))
        untracked.contentView = untrackedContent

        XCTAssertNil(lifecycle.windowWillClose(untracked))
        await Self.drainMainQueue()
        XCTAssertTrue(lifecycle.window === tracked)
        XCTAssertTrue(tracked.contentView === trackedContent)
        XCTAssertTrue(untracked.contentView === untrackedContent)
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
