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

    func testCaptureAXSelectionNeverPostsCmdC() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Hello world"
        )
        let service = SelectionCaptureService(backend: backend)

        _ = await service.captureAXSelection()

        XCTAssertEqual(backend.postCmdCCount(), 0)
    }

    func testCaptureAXSelectionSkipsOwnBundleSystemFocusAndUsesPreferredProcess() async {
        let systemElement = AXUIElementCreateSystemWide()
        let processElement = AXUIElementCreateApplication(99)
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: systemElement,
            selectedText: "MacParakeet draft",
            processFocusedElement: processElement,
            processSelectedText: "Mail selection",
            frontmostBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.macparakeet.tests"
        )
        let service = SelectionCaptureService(backend: backend)
        let preferred = SelectionCaptureTarget(
            processIdentifier: 99,
            bundleIdentifier: "com.apple.mail",
            localizedName: "Mail"
        )

        let result = await service.captureAXSelection(preferring: preferred)

        switch result {
        case .ax(let text, _, let target):
            XCTAssertEqual(text, "Mail selection")
            XCTAssertEqual(target?.processIdentifier, 99)
            XCTAssertEqual(target?.bundleIdentifier, "com.apple.mail")
        default:
            XCTFail("Expected .ax from the preferred process, got \(result.pathTag)")
        }
        XCTAssertEqual(backend.postCmdCCount(), 0)
    }

    func testCaptureAXSelectionUsesFrontmostProcessWhenSystemFocusMoves() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Wrong app selection",
            processFocusedElement: AXUIElementCreateApplication(1234),
            processSelectedText: "Source selection"
        )
        let service = SelectionCaptureService(backend: backend)

        let result = await service.captureAXSelection()

        guard case .ax(let text, _, let target) = result else {
            XCTFail("Expected selection from the captured process, got \(result.pathTag)")
            return
        }
        XCTAssertEqual(text, "Source selection")
        XCTAssertEqual(target?.processIdentifier, 1234)
        XCTAssertEqual(backend.postCmdCCount(), 0)
    }

    func testCaptureAXSelectionPrefersMenuOpenTargetWhenAnotherAppBecomesFrontmost() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Other app selection",
            processFocusedElement: AXUIElementCreateApplication(99),
            processSelectedText: "Menu open selection"
        )
        let service = SelectionCaptureService(backend: backend)
        let menuOpenTarget = SelectionCaptureTarget(
            processIdentifier: 99,
            bundleIdentifier: "com.apple.mail"
        )

        let result = await service.captureAXSelection(preferring: menuOpenTarget)

        guard case .ax(let text, _, let target) = result else {
            XCTFail("Expected the menu-open app selection, got \(result.pathTag)")
            return
        }
        XCTAssertEqual(text, "Menu open selection")
        XCTAssertEqual(target, menuOpenTarget)
    }

    func testCaptureAXSelectionDoesNotUseSystemFocusWhenProcessLookupFails() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: "Another app selection",
            processLookupAvailable: false
        )
        let service = SelectionCaptureService(backend: backend)

        let result = await service.captureAXSelection()

        guard case .empty = result else {
            XCTFail("Expected no capture from another app, got \(result.pathTag)")
            return
        }
        XCTAssertEqual(backend.postCmdCCount(), 0)
    }

    func testTargetedClipboardCaptureStopsWhenFocusMovesBeforeCopy() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            frontmostProcessIdentifiers: [1234, 5678]
        )
        let service = SelectionCaptureService(backend: backend)
        let target = SelectionCaptureTarget(processIdentifier: 1234, bundleIdentifier: "com.example.Source")

        let result = await service.captureSelection(in: target)

        guard case .failed(let error) = result else {
            XCTFail("Expected focus-change failure, got \(result.pathTag)")
            return
        }
        XCTAssertEqual(error, .targetNotFrontmost)
        XCTAssertEqual(backend.postCmdCCount(), 0)
    }

    func testTargetedClipboardCaptureKeepsOriginalTarget() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 1,
            pasteboardAfterCmdC: "Selected text",
            changeCountAfterCmdC: 2
        )
        let service = SelectionCaptureService(backend: backend)
        let target = SelectionCaptureTarget(processIdentifier: 1234, bundleIdentifier: "com.example.Source")

        let result = await service.captureSelection(in: target)

        guard case .clipboard(let text, _, let capturedTarget) = result else {
            XCTFail("Expected clipboard capture, got \(result.pathTag)")
            return
        }
        XCTAssertEqual(text, "Selected text")
        XCTAssertEqual(capturedTarget, target)
        XCTAssertEqual(backend.postCmdCCount(), 1)
    }

    func testTargetedClipboardCaptureRejectsTextIfFocusMovesAfterCopy() async {
        let backend = FakeSelectionCaptureBackend(
            isTrusted: true,
            focusedElement: AXUIElementCreateSystemWide(),
            selectedText: nil,
            initialChangeCount: 1,
            pasteboardAfterCmdC: "Other app selection",
            changeCountAfterCmdC: 2,
            frontmostProcessIdentifiers: [1234, 1234, 5678]
        )
        let service = SelectionCaptureService(backend: backend)
        let target = SelectionCaptureTarget(processIdentifier: 1234, bundleIdentifier: "com.example.Source")

        let result = await service.captureSelection(in: target)

        guard case .failed(let error) = result else {
            XCTFail("Expected focus-change failure, got \(result.pathTag)")
            return
        }
        XCTAssertEqual(error, .targetNotFrontmost)
        XCTAssertEqual(backend.postCmdCCount(), 1)
        XCTAssertEqual(backend.restoreCount(), 0, "A later user copy must not be overwritten")
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
    private let processFocused: AXUIElement?
    private let processSelectedTextValue: String?
    private let processLookupAvailable: Bool
    private let frontmostBundle: String
    private let frontmostProcessIdentifiers: [pid_t]
    private var restoreCalls: Int = 0
    private var frontmostTargetCalls: Int = 0
    private var postCmdCCalls: Int = 0

    init(
        isTrusted: Bool,
        focusedElement: AXUIElement? = nil,
        selectedText: String? = nil,
        initialChangeCount: Int = 0,
        snapshotItems: [NSPasteboardItem]? = nil,
        pasteboardAfterCmdC: String? = nil,
        changeCountAfterCmdC: Int? = nil,
        processFocusedElement: AXUIElement? = nil,
        processSelectedText: String? = nil,
        processLookupAvailable: Bool = true,
        frontmostBundleIdentifier: String = "com.example.Source",
        frontmostProcessIdentifiers: [pid_t] = [1234]
    ) {
        self.trusted = isTrusted
        self.focused = focusedElement
        self.selectedTextValue = selectedText
        self.changeCount = initialChangeCount
        self.snapshotItems = snapshotItems
        self.pasteboardAfterCmdC = pasteboardAfterCmdC
        self.changeCountAfterCmdC = changeCountAfterCmdC
        self.processFocused = processFocusedElement
        self.processSelectedTextValue = processSelectedText
        self.processLookupAvailable = processLookupAvailable
        self.frontmostBundle = frontmostBundleIdentifier
        self.frontmostProcessIdentifiers = frontmostProcessIdentifiers
    }

    func isAccessibilityTrusted() -> Bool { trusted }
    func focusedElement() -> AXUIElement? { focused }
    func focusedElement(ofProcess pid: pid_t) -> AXUIElement? {
        processLookupAvailable ? (processFocused ?? focused) : nil
    }
    func selectedText(of element: AXUIElement) -> String? {
        if let processFocused, CFEqual(element, processFocused) {
            return processSelectedTextValue
        }
        return selectedTextValue
    }

    @MainActor
    func frontmostApplicationTarget() -> SelectionCaptureTarget? {
        frontmostTargetCalls += 1
        return SelectionCaptureTarget(
            processIdentifier: frontmostProcessIdentifiers[
                min(frontmostTargetCalls - 1, frontmostProcessIdentifiers.count - 1)
            ],
            bundleIdentifier: frontmostBundle,
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
        postCmdCCalls += 1
        if let newCount = changeCountAfterCmdC {
            changeCount = newCount
        }
    }

    func postCmdCCount() -> Int { postCmdCCalls }

    @MainActor
    func restoreSnapshot(_ snapshot: PasteboardSnapshot) {
        restoreCalls += 1
    }

    func restoreCount() -> Int { restoreCalls }
    func setChangeCountForTesting(_ newValue: Int) { changeCount = newValue }
}
