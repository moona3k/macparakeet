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
        default:
            XCTFail("Expected .clipboard, got \(result.pathTag)")
        }
    }

    func testCaptureReturnsEmptyWhenClipboardDidNotChange() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 5,
            pasteboardAfterCmdC: "ignored",
            changeCountAfterCmdC: 5  // No change
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
        SelectionCaptureTarget(
            processIdentifier: 1234,
            bundleIdentifier: "com.example.Source"
        )
    }

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
