import AppKit
import XCTest
@testable import MacParakeetCore

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testDefaultRestoreDelayUsesHalfSecondFallbackWindow() {
        XCTAssertEqual(
            ClipboardService.defaultClipboardRestoreDelay,
            0.5,
            accuracy: 0.001,
            "Fallback clipboard paste should keep the dictated text available briefly without leaving a long stale-clipboard window."
        )
    }

    func testPasteTextAlwaysUsesClipboardPastePath() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        var pastedStrings: [String] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting {
                pastedStrings.append(pasteboard.string(forType: .string) ?? "")
            },
            clipboardRestoreDelay: Self.shortRestoreDelay
        )

        try await service.pasteText("dictation")

        XCTAssertEqual(pastedStrings, ["dictation"])

        try await waitForPasteboardString("original", on: pasteboard)
    }

    func testPasteboardWriteFailureHasActionableDescription() {
        XCTAssertEqual(
            ClipboardServiceError.pasteboardWriteFailed.errorDescription,
            "Paste automation unavailable (could not write transcript to the clipboard)."
        )
    }

    func testPasteTextWriteFailureRestoresClipboardAndDoesNotPostPaste() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        var attemptedWrites: [String] = []
        var pasteWasPosted = false
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting {
                pasteWasPosted = true
            },
            clipboardRestoreDelay: Self.shortRestoreDelay,
            pasteboardStringWriter: { _, text in
                attemptedWrites.append(text)
                return false
            }
        )

        do {
            try await service.pasteText("dictation")
            XCTFail("Expected pasteText to throw when writing to the pasteboard fails")
        } catch ClipboardServiceError.pasteboardWriteFailed {
            XCTAssertEqual(attemptedWrites, ["dictation"])
            XCTAssertFalse(pasteWasPosted)
            XCTAssertEqual(pasteboard.string(forType: .string), "original")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPasteTextRestoresOriginalClipboardAfterConfiguredDelay() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        var pastedStrings: [String] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting {
                pastedStrings.append(pasteboard.string(forType: .string) ?? "")
            },
            clipboardRestoreDelay: Self.shortRestoreDelay
        )

        try await service.pasteText("dictation")

        XCTAssertEqual(pastedStrings, ["dictation"])
        XCTAssertEqual(pasteboard.string(forType: .string), "dictation")

        try await waitForPasteboardString("original", on: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testPasteTextCanLeavePastedTextOnClipboard() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")
        let restoreAttempted = expectation(description: "restore should not be scheduled")
        restoreAttempted.isInverted = true

        var pastedStrings: [String] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting {
                pastedStrings.append(pasteboard.string(forType: .string) ?? "")
            },
            clipboardRestoreDelay: Self.shortRestoreDelay,
            restoreAttemptObserver: {
                restoreAttempted.fulfill()
            }
        )

        try await service.pasteText("dictation ", restoresClipboard: false)

        XCTAssertEqual(pastedStrings, ["dictation "])
        await fulfillment(of: [restoreAttempted], timeout: 0.1)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictation ")
    }

    func testPasteTextWithoutRestoreCancelsPendingRestore() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")
        let restoreAttempted = expectation(description: "first scheduled restore attempted")

        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(),
            clipboardRestoreDelay: Self.shortRestoreDelay,
            restoreAttemptObserver: {
                restoreAttempted.fulfill()
            }
        )

        try await service.pasteText("first dictation")
        try await service.pasteText("second dictation ", restoresClipboard: false)

        await fulfillment(of: [restoreAttempted], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "second dictation ")
    }

    func testOverlappingPasteTextRestoresPreExistingClipboard() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        var pastedStrings: [String] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting {
                pastedStrings.append(pasteboard.string(forType: .string) ?? "")
            },
            clipboardRestoreDelay: Self.shortRestoreDelay
        )

        try await service.pasteText("first dictation")
        try await service.pasteText("second dictation")

        XCTAssertEqual(pastedStrings, ["first dictation", "second dictation"])
        XCTAssertEqual(pasteboard.string(forType: .string), "second dictation")

        try await waitForPasteboardString("original", on: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testPasteTextWithActionSkipsPasteForEmptyTextAndFiresKeystroke() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        var pasteWasPosted = false
        var keystrokes: [UInt16] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(
                onPaste: {
                    pasteWasPosted = true
                },
                onKeystroke: { keyCode in
                    keystrokes.append(keyCode)
                }
            ),
            clipboardRestoreDelay: Self.shortRestoreDelay
        )

        let fired = try await service.pasteTextWithAction("  \n", postPasteAction: .returnKey)

        XCTAssertTrue(fired)
        XCTAssertFalse(pasteWasPosted)
        XCTAssertEqual(keystrokes, [KeyAction.returnKey.keyCode])
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testPasteTextWithActionPastesTextThenFiresKeystroke() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        var pastedStrings: [String] = []
        var keystrokes: [UInt16] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(
                onPaste: {
                    pastedStrings.append(pasteboard.string(forType: .string) ?? "")
                },
                onKeystroke: { keyCode in
                    keystrokes.append(keyCode)
                }
            ),
            clipboardRestoreDelay: Self.shortRestoreDelay
        )

        let fired = try await service.pasteTextWithAction("dictation", postPasteAction: .returnKey)

        XCTAssertTrue(fired)
        XCTAssertEqual(pastedStrings, ["dictation"])
        XCTAssertEqual(keystrokes, [KeyAction.returnKey.keyCode])

        try await waitForPasteboardString("original", on: pasteboard)
    }

    func testPasteTextWithActionCanLeavePastedTextOnClipboard() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")
        let restoreAttempted = expectation(description: "restore should not be scheduled")
        restoreAttempted.isInverted = true

        var pastedStrings: [String] = []
        var keystrokes: [UInt16] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(
                onPaste: {
                    pastedStrings.append(pasteboard.string(forType: .string) ?? "")
                },
                onKeystroke: { keyCode in
                    keystrokes.append(keyCode)
                }
            ),
            clipboardRestoreDelay: Self.shortRestoreDelay,
            restoreAttemptObserver: {
                restoreAttempted.fulfill()
            }
        )

        let fired = try await service.pasteTextWithAction(
            "dictation",
            postPasteAction: .returnKey,
            restoresClipboard: false
        )

        XCTAssertTrue(fired)
        XCTAssertEqual(pastedStrings, ["dictation"])
        XCTAssertEqual(keystrokes, [KeyAction.returnKey.keyCode])
        await fulfillment(of: [restoreAttempted], timeout: 0.1)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictation")
    }

    func testUserClipboardChangeDuringRestoreWindowIsNotClobbered() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")
        let restoreAttempted = expectation(description: "scheduled restore attempted")

        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(),
            clipboardRestoreDelay: Self.shortRestoreDelay,
            restoreAttemptObserver: {
                restoreAttempted.fulfill()
            }
        )

        try await service.pasteText("dictation")
        replacePasteboard(pasteboard, with: "user copy")

        await fulfillment(of: [restoreAttempted], timeout: 2)

        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
    }

    func testPasteAfterUserClipboardChangeUsesNewClipboardAsRestoreTarget() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(),
            clipboardRestoreDelay: Self.shortRestoreDelay
        )

        try await service.pasteText("first dictation")
        replacePasteboard(pasteboard, with: "user copy")
        try await service.pasteText("second dictation")

        try await waitForPasteboardString("user copy", on: pasteboard)

        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
    }

    func testCopyToClipboardCancelsPendingRestore() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")
        let restoreAttempted = expectation(description: "scheduled restore attempted")

        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(),
            clipboardRestoreDelay: Self.shortRestoreDelay,
            restoreAttemptObserver: {
                restoreAttempted.fulfill()
            }
        )

        try await service.pasteText("dictation")
        await service.copyToClipboard("manual copy")

        await fulfillment(of: [restoreAttempted], timeout: 2)

        XCTAssertEqual(pasteboard.string(forType: .string), "manual copy")
    }

    func testCopyToClipboardWriteFailurePreservesCurrentClipboard() async {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(),
            clipboardRestoreDelay: Self.shortRestoreDelay,
            pasteboardStringWriter: { _, _ in false }
        )

        let copied = await service.copyToClipboard("manual copy")

        XCTAssertFalse(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testFailedCopyToClipboardKeepsPendingOriginalRestore() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        var failNextWrite = false
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(),
            clipboardRestoreDelay: Self.shortRestoreDelay,
            pasteboardStringWriter: { pasteboard, text in
                guard !failNextWrite else {
                    failNextWrite = false
                    return false
                }
                return pasteboard.setString(text, forType: .string)
            }
        )

        try await service.pasteText("dictation")
        failNextWrite = true

        let copied = await service.copyToClipboard("manual copy")

        XCTAssertFalse(copied)
        XCTAssertEqual(pasteboard.string(forType: .string), "dictation")

        try await waitForPasteboardString("original", on: pasteboard)
    }

    private static let shortRestoreDelay: TimeInterval = 0.03

    private func makeScratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("com.macparakeet.tests.clipboard.\(UUID().uuidString)"))
    }

    private func replacePasteboard(_ pasteboard: NSPasteboard, with string: String) {
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(string, forType: .string))
    }

    private func waitForPasteboardString(
        _ expected: String,
        on pasteboard: NSPasteboard,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if pasteboard.string(forType: .string) == expected {
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(pasteboard.string(forType: .string), expected, file: file, line: line)
    }

}

@MainActor
private final class RecordingClipboardEventPosting: ClipboardEventPosting {
    private let onPaste: @MainActor () throws -> Void
    private let onKeystroke: @MainActor (UInt16) throws -> Void

    init(
        onPaste: @escaping @MainActor () throws -> Void = {},
        onKeystroke: @escaping @MainActor (UInt16) throws -> Void = { _ in }
    ) {
        self.onPaste = onPaste
        self.onKeystroke = onKeystroke
    }

    func simulatePaste(using pasteShortcutKeyResolver: PasteShortcutKeyResolver) throws {
        try onPaste()
    }

    func simulateKeystroke(_ keyCode: UInt16) throws {
        try onKeystroke(keyCode)
    }
}
