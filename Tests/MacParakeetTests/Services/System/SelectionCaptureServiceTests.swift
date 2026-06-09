import AppKit
@preconcurrency import ApplicationServices
import XCTest
@testable import MacParakeetCore

final class SelectionCaptureServiceTests: XCTestCase {
    func testCaptureReturnsFailedWhenAccessibilityNotAuthorized() async {
        let backend = FakeSelectionCaptureBackend(isTrusted: false)
        let service = SelectionCaptureService(backend: backend)

        let result = await service.captureSelection()

        switch result {
        case .failed(let error):
            XCTAssertEqual(error, .accessibilityNotAuthorized)
        default:
            XCTFail("Expected .failed(.accessibilityNotAuthorized), got \(result.pathTag)")
        }
    }

    func testCaptureReturnsAxWhenSelectedTextAttributeNonEmpty() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Hello world"
        )
        let service = SelectionCaptureService(backend: backend)

        let result = await service.captureSelection()

        switch result {
        case .ax(let text, _, let target):
            XCTAssertEqual(text, "Hello world")
            XCTAssertEqual(target?.processIdentifier, 1234)
            XCTAssertEqual(target?.bundleIdentifier, "com.example.Source")
            XCTAssertEqual(target?.localizedName, "Source")
        default:
            XCTFail("Expected .ax, got \(result.pathTag)")
        }
    }

    func testCaptureFallsBackToClipboardWhenAxEmptyAndPasteboardChanges() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 1,
            pasteboardAfterCmdC: "Clipboard selection",
            changeCountAfterCmdC: 2
        )
        let service = SelectionCaptureService(
            backend: backend,
            clipboardPollTimeout: .milliseconds(200),
            pollIntervalNanos: 1_000_000
        )

        let result = await service.captureSelection()

        switch result {
        case .clipboard(let text, let snapshot, let target):
            XCTAssertEqual(text, "Clipboard selection")
            XCTAssertEqual(snapshot.originalChangeCount, 1)
            XCTAssertEqual(snapshot.temporaryChangeCount, 2)
            XCTAssertEqual(target?.processIdentifier, 1234)
            XCTAssertEqual(target?.bundleIdentifier, "com.example.Source")
            XCTAssertEqual(target?.localizedName, "Source")
        default:
            XCTFail("Expected .clipboard, got \(result.pathTag)")
        }
    }

    func testCaptureReturnsEmptyWhenClipboardDidNotChangeAndNoPriorContent() async {
        // No change count AND no pre-existing clipboard text → still .empty.
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 5,
            snapshotItems: nil,         // nothing on clipboard
            pasteboardAfterCmdC: "ignored",
            changeCountAfterCmdC: 5     // No change
        )
        let service = SelectionCaptureService(
            backend: backend,
            clipboardPollTimeout: .milliseconds(60),
            pollIntervalNanos: 1_000_000
        )

        let result = await service.captureSelection()

        switch result {
        case .empty:
            break
        default:
            XCTFail("Expected .empty, got \(result.pathTag)")
        }
    }

    /// Terminal / read-only surface workflow: the user manually Cmd+C'd text
    /// before triggering the transform. The synthesized Cmd+C produces no new
    /// clipboard write (nothing selected in the terminal), so the hijack times
    /// out — but pre-existing clipboard text should be used as a fallback.
    func testCaptureFallsBackToPreExistingClipboardWhenHijackTimesOut() async {
        let existingItem = NSPasteboardItem()
        existingItem.setString("pre-existing clipboard text", forType: .string)
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 7,
            snapshotItems: [existingItem],
            pasteboardAfterCmdC: nil,
            changeCountAfterCmdC: 7     // No change — nothing was selected
        )
        let service = SelectionCaptureService(
            backend: backend,
            clipboardPollTimeout: .milliseconds(60),
            pollIntervalNanos: 1_000_000
        )

        let result = await service.captureSelection()

        switch result {
        case .clipboard(let text, let snapshot, _):
            XCTAssertEqual(text, "pre-existing clipboard text")
            XCTAssertEqual(snapshot.originalChangeCount, 7)
            // temporaryChangeCount equals originalChangeCount for the pre-existing
            // fallback — this tells restoreClipboardCaptureIfCurrent to skip
            // restoration if the user copied something new during the LLM phase.
            XCTAssertEqual(snapshot.temporaryChangeCount, 7)
        default:
            XCTFail("Expected .clipboard with pre-existing text, got \(result.pathTag)")
        }
    }

    /// Regression: abandoning a pre-existing clipboard fallback when the user
    /// has NOT copied anything new must not touch the pasteboard. The capture
    /// never hijacked the clipboard (it read text the user already had), so a
    /// restore would be a spurious `clearContents()` + `writeObjects()` that
    /// bumps the change count and fires clipboard-manager "new item" events for
    /// a duplicate of the user's own text.
    func testAbandonedPreExistingCaptureSkipsRestoreWhenClipboardUnchanged() async {
        let existingItem = NSPasteboardItem()
        existingItem.setString("pre-existing text", forType: .string)
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 9,
            snapshotItems: [existingItem],
            pasteboardAfterCmdC: nil,
            changeCountAfterCmdC: 9     // No change — pre-existing fallback
        )
        let service = SelectionCaptureService(
            backend: backend,
            clipboardPollTimeout: .milliseconds(60),
            pollIntervalNanos: 1_000_000
        )

        let result = await service.captureSelection()
        // Abandon with NO subsequent user copy (change count still 9).
        await service.restoreClipboardCaptureIfCurrent(result)

        XCTAssertEqual(backend.restoreCount(), 0, "Pre-existing fallback never hijacked the clipboard — restoring would spuriously bump the change count")
    }

    /// Abandoning a pre-existing clipboard capture should not clobber a
    /// subsequent user copy (changeCount moved while LLM was running).
    func testAbandonedPreExistingCapturePreservesSubsequentUserCopy() async {
        let existingItem = NSPasteboardItem()
        existingItem.setString("old clipboard text", forType: .string)
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 3,
            snapshotItems: [existingItem],
            pasteboardAfterCmdC: nil,
            changeCountAfterCmdC: 3
        )
        let service = SelectionCaptureService(
            backend: backend,
            clipboardPollTimeout: .milliseconds(60),
            pollIntervalNanos: 1_000_000
        )

        let result = await service.captureSelection()
        // Simulate the user copying something new during the LLM phase.
        backend.setChangeCountForTesting(4)
        await service.restoreClipboardCaptureIfCurrent(result)

        XCTAssertEqual(backend.restoreCount(), 0, "User clipboard write after capture must not be clobbered")
    }

    func testCaptureSnapshotIsCarriedForRestore() async {
        let placeholder = NSPasteboardItem()
        placeholder.setString("original", forType: .string)
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 7,
            snapshotItems: [placeholder],
            pasteboardAfterCmdC: "after",
            changeCountAfterCmdC: 8
        )
        let service = SelectionCaptureService(
            backend: backend,
            clipboardPollTimeout: .milliseconds(60),
            pollIntervalNanos: 1_000_000
        )

        let result = await service.captureSelection()

        guard case .clipboard(_, let snapshot, _) = result else {
            XCTFail("Expected .clipboard, got \(result.pathTag)")
            return
        }
        XCTAssertEqual(snapshot.originalChangeCount, 7)
        XCTAssertEqual(snapshot.items?.count, 1)
    }

    /// Regression: when Cmd+C moves `changeCount` but the resulting
    /// pasteboard content isn't text (image, file, etc.), the service used
    /// to return `.empty` without restoring the snapshot — silently
    /// destroying the user's pre-hijack clipboard. The fix restores the
    /// snapshot before bailing.
    func testCaptureRestoresClipboardWhenChangeMovedButNoText() async {
        let placeholder = NSPasteboardItem()
        placeholder.setString("original-user-content", forType: .string)
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 4,
            snapshotItems: [placeholder],
            pasteboardAfterCmdC: nil,           // image/file → no text
            changeCountAfterCmdC: 5             // but Cmd+C did write something
        )
        let service = SelectionCaptureService(
            backend: backend,
            clipboardPollTimeout: .milliseconds(60),
            pollIntervalNanos: 1_000_000
        )

        let result = await service.captureSelection()

        switch result {
        case .empty:
            break
        default:
            XCTFail("Expected .empty, got \(result.pathTag)")
        }
        XCTAssertEqual(backend.restoreCount(), 1, "Snapshot must be restored — user's pre-hijack clipboard had non-text content we'd otherwise have lost")
    }

    func testAbandonedClipboardCaptureSkipsRestoreWhenUserCopiedAfterCapture() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 4,
            pasteboardAfterCmdC: "captured-selection",
            changeCountAfterCmdC: 5
        )
        let service = SelectionCaptureService(
            backend: backend,
            clipboardPollTimeout: .milliseconds(60),
            pollIntervalNanos: 1_000_000
        )

        let result = await service.captureSelection()
        backend.setChangeCountForTesting(6)
        await service.restoreClipboardCaptureIfCurrent(result)

        XCTAssertEqual(backend.restoreCount(), 0, "User clipboard writes after capture must not be clobbered by abandoned-transform cleanup")
    }
}

// MARK: - Fake Backend

final class FakeSelectionCaptureBackend: SelectionCaptureBackend, @unchecked Sendable {
    private let trusted: Bool
    private let focused: AXUIElement?
    private let selectedTextValue: String?
    private var changeCount: Int
    private let pasteboardAfterCmdC: String?
    private let changeCountAfterCmdC: Int?
    private let snapshotItems: [NSPasteboardItem]?
    private var restoreCalls: Int = 0
    private var frontmostTargetCalls: Int = 0

    init(
        isTrusted: Bool,
        focusedElement: AXUIElement? = nil,
        selectedText: String? = nil,
        initialChangeCount: Int = 0,
        snapshotItems: [NSPasteboardItem]? = nil,
        pasteboardAfterCmdC: String? = nil,
        changeCountAfterCmdC: Int? = nil
    ) {
        self.trusted = isTrusted
        self.focused = focusedElement
        self.selectedTextValue = selectedText
        self.changeCount = initialChangeCount
        self.snapshotItems = snapshotItems
        self.pasteboardAfterCmdC = pasteboardAfterCmdC
        self.changeCountAfterCmdC = changeCountAfterCmdC
    }

    func isAccessibilityTrusted() -> Bool { trusted }
    func focusedElement() -> AXUIElement? { focused }
    func selectedText(of element: AXUIElement) -> String? { selectedTextValue }

    @MainActor
    func frontmostApplicationTarget() -> SelectionCaptureTarget? {
        frontmostTargetCalls += 1
        return SelectionCaptureTarget(
            processIdentifier: 1234,
            bundleIdentifier: "com.example.Source",
            localizedName: "Source"
        )
    }

    func frontmostTargetCallCount() -> Int { frontmostTargetCalls }

    @MainActor
    func snapshotPasteboard() -> PasteboardSnapshot {
        PasteboardSnapshot(items: snapshotItems, originalChangeCount: changeCount)
    }

    @MainActor
    func currentPasteboardString() -> String? {
        pasteboardAfterCmdC
    }

    @MainActor
    func currentPasteboardChangeCount() -> Int {
        changeCount
    }

    @MainActor
    func postCmdC() throws {
        if let newCount = changeCountAfterCmdC {
            changeCount = newCount
        }
    }

    @MainActor
    func restoreSnapshot(_ snapshot: PasteboardSnapshot) {
        restoreCalls += 1
    }

    func restoreCount() -> Int { restoreCalls }
    func setChangeCountForTesting(_ newValue: Int) { changeCount = newValue }
}
