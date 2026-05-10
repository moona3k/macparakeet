import AppKit
import XCTest
@testable import MacParakeetCore

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testDefaultRestoreDelayLeavesRoomForAsyncPasteConsumers() {
        XCTAssertGreaterThanOrEqual(
            ClipboardService.defaultClipboardRestoreDelay,
            0.75,
            "Restoring too soon can make slow target apps paste the previously saved clipboard item."
        )
    }

    func testPasteboardWriteFailureHasActionableDescription() {
        XCTAssertEqual(
            ClipboardServiceError.pasteboardWriteFailed.errorDescription,
            "Paste automation unavailable (could not write transcript to the clipboard)."
        )
    }

    func testTargetApplicationUnavailableHasActionableDescription() {
        XCTAssertEqual(
            ClipboardServiceError.targetApplicationUnavailable.errorDescription,
            "Paste automation unavailable (target app is no longer running)."
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

    func testPasteTextPostsPasteToTargetProcess() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        let target = ClipboardPasteTarget(processIdentifier: 12345, bundleIdentifier: "com.example.Editor")
        var pasteTargets: [ClipboardPasteTarget?] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(
                onPasteTarget: { target in
                    pasteTargets.append(target)
                }
            ),
            clipboardRestoreDelay: Self.shortRestoreDelay
        )

        try await service.pasteText("dictation", target: target)

        XCTAssertEqual(pasteTargets, [target])
    }

    func testTargetedProtocolDefaultsPreserveLegacyConformers() async throws {
        let legacyService = LegacyClipboardService()
        let service: ClipboardServiceProtocol = legacyService
        let target = ClipboardPasteTarget(processIdentifier: 12345, bundleIdentifier: "com.example.Editor")

        try await service.pasteText("dictation", target: target)
        let fired = try await service.pasteTextWithAction(
            "send it",
            postPasteAction: .returnKey,
            target: target
        )

        let snapshot = await legacyService.snapshot()
        XCTAssertEqual(snapshot.pastedTexts, ["dictation", "send it"])
        XCTAssertEqual(snapshot.postPasteActions, [.returnKey])
        XCTAssertTrue(fired)
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

    func testPasteTextWithActionPostsPasteAndKeystrokeToTargetProcess() async throws {
        let pasteboard = makeScratchPasteboard()
        defer { pasteboard.releaseGlobally() }
        replacePasteboard(pasteboard, with: "original")

        let target = ClipboardPasteTarget(processIdentifier: 12345, bundleIdentifier: "com.example.Editor")
        var pastedStrings: [String] = []
        var pasteTargets: [ClipboardPasteTarget?] = []
        var keystrokes: [UInt16] = []
        var keystrokeTargets: [ClipboardPasteTarget?] = []
        let service = ClipboardService(
            pasteboard: pasteboard,
            eventPosting: RecordingClipboardEventPosting(
                onPasteTarget: { target in
                    pastedStrings.append(pasteboard.string(forType: .string) ?? "")
                    pasteTargets.append(target)
                },
                onKeystrokeTarget: { keyCode, target in
                    keystrokes.append(keyCode)
                    keystrokeTargets.append(target)
                }
            ),
            clipboardRestoreDelay: Self.shortRestoreDelay
        )

        let fired = try await service.pasteTextWithAction(
            "dictation",
            postPasteAction: .returnKey,
            target: target
        )

        XCTAssertTrue(fired)
        XCTAssertEqual(pastedStrings, ["dictation"])
        XCTAssertEqual(pasteTargets, [target])
        XCTAssertEqual(keystrokes, [KeyAction.returnKey.keyCode])
        XCTAssertEqual(keystrokeTargets, [target])

        try await waitForPasteboardString("original", on: pasteboard)
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
    private let onPaste: @MainActor (ClipboardPasteTarget?) throws -> Void
    private let onKeystroke: @MainActor (UInt16, ClipboardPasteTarget?) throws -> Void

    init(
        onPaste: @escaping @MainActor () throws -> Void = {},
        onKeystroke: @escaping @MainActor (UInt16) throws -> Void = { _ in }
    ) {
        self.onPaste = { _ in try onPaste() }
        self.onKeystroke = { keyCode, _ in try onKeystroke(keyCode) }
    }

    init(
        onPasteTarget: @escaping @MainActor (ClipboardPasteTarget?) throws -> Void,
        onKeystrokeTarget: @escaping @MainActor (UInt16, ClipboardPasteTarget?) throws -> Void = { _, _ in }
    ) {
        self.onPaste = onPasteTarget
        self.onKeystroke = onKeystrokeTarget
    }

    func simulatePaste(using pasteShortcutKeyResolver: PasteShortcutKeyResolver, target: ClipboardPasteTarget?) throws {
        try onPaste(target)
    }

    func simulateKeystroke(_ keyCode: UInt16, target: ClipboardPasteTarget?) throws {
        try onKeystroke(keyCode, target)
    }
}

private actor LegacyClipboardService: ClipboardServiceProtocol {
    private var pastedTexts: [String] = []
    private var postPasteActions: [KeyAction?] = []
    private var copiedTexts: [String] = []

    func pasteText(_ text: String) async throws {
        pastedTexts.append(text)
    }

    func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws -> Bool {
        pastedTexts.append(text)
        postPasteActions.append(postPasteAction)
        return postPasteAction != nil
    }

    func copyToClipboard(_ text: String) async -> Bool {
        copiedTexts.append(text)
        return true
    }

    func snapshot() -> (pastedTexts: [String], postPasteActions: [KeyAction?], copiedTexts: [String]) {
        (pastedTexts, postPasteActions, copiedTexts)
    }
}
