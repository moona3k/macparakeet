import AppKit
@preconcurrency import ApplicationServices
import os
import XCTest
@testable import MacParakeetCore

final class SelectionReplacementServiceTests: XCTestCase {
    func testReplaceViaAxSucceeds() async throws {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: true
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))

        let path = try await service.replace(
            with: "polished",
            in: .ax(text: "raw", element: AXFocusedElement(AXUIElementCreateSystemWide()), target: nil)
        )

        XCTAssertEqual(path, .ax)
        XCTAssertEqual(backend.lastAXText(), "polished")
        XCTAssertEqual(backend.cmdVPostCount(), 0)
    }

    func testPasteIntoCurrentFocusSkipsAXWriteAndOriginalTargetActivation() async throws {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: true
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))
        let originalTarget = SelectionCaptureTarget(
            processIdentifier: 1234,
            bundleIdentifier: "com.example.Source"
        )

        let path = try await service.replace(
            with: "polished",
            in: .ax(
                text: "raw",
                element: AXFocusedElement(AXUIElementCreateSystemWide()),
                target: originalTarget
            ),
            mode: .pasteIntoCurrentFocus
        )

        XCTAssertEqual(path, .clipboardPaste)
        XCTAssertNil(backend.lastAXText())
        XCTAssertEqual(backend.activatedTargets(), [])
        XCTAssertEqual(backend.lastClipboardText(), "polished")
        XCTAssertEqual(backend.cmdVPostCount(), 1)
    }

    func testReplaceFallsBackToPasteWhenAXFails() async throws {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: false
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))

        let path = try await service.replace(
            with: "polished",
            in: .ax(text: "raw", element: AXFocusedElement(AXUIElementCreateSystemWide()), target: nil)
        )

        XCTAssertEqual(path, .clipboardPaste)
        XCTAssertEqual(backend.lastClipboardText(), "polished")
        XCTAssertEqual(backend.cmdVPostCount(), 1)
        XCTAssertGreaterThanOrEqual(backend.restoreCount(), 1)
    }

    func testReplaceClipboardContextRestoresSnapshot() async throws {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: false
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))
        let snapshot = PasteboardSnapshot(items: nil, originalChangeCount: 42)

        let path = try await service.replace(
            with: "polished",
            in: .clipboard(text: "raw", savedClipboard: snapshot, target: nil)
        )

        XCTAssertEqual(path, .clipboardPaste)
        XCTAssertGreaterThanOrEqual(backend.restoreCount(), 1)
        XCTAssertEqual(backend.lastRestoredChangeCount(), 42)
    }

    func testReplaceThrowsOnEmptyContext() async {
        let backend = FakeSelectionReplacementBackend(isTrusted: true)
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))

        do {
            _ = try await service.replace(with: "polished", in: .empty)
            XCTFail("Expected throw")
        } catch let error as SelectionReplacementError {
            XCTAssertEqual(error, .allPathsFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testReplaceRestoresClipboardOnPasteboardWriteFailure() async {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: false,
            pasteboardWriteSucceeds: false
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))
        let snapshot = PasteboardSnapshot(items: nil, originalChangeCount: 99)

        do {
            _ = try await service.replace(
                with: "polished",
                in: .clipboard(text: "raw", savedClipboard: snapshot, target: nil)
            )
            XCTFail("Expected pasteboardWriteFailed")
        } catch let error as SelectionReplacementError {
            XCTAssertEqual(error, .pasteboardWriteFailed)
            XCTAssertGreaterThanOrEqual(backend.restoreCount(), 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Regression: if the user copies content during the post-paste window,
    /// we must NOT restore the saved snapshot — that would silently destroy
    /// what they just put on the clipboard. The fix gates `restoreSnapshot`
    /// on `currentChangeCount() == ourChangeCount`.
    func testReplaceSkipsRestoreWhenUserCopiesMidTransform() async throws {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: false,
            pasteboardWriteSucceeds: true,
            simulateUserCopyAfterWrite: true
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))
        let snapshot = PasteboardSnapshot(items: nil, originalChangeCount: 42)

        _ = try await service.replace(
            with: "polished",
            in: .clipboard(text: "raw", savedClipboard: snapshot, target: nil)
        )

        XCTAssertEqual(backend.cmdVPostCount(), 1, "Paste should still happen — we only suppress restore")
        XCTAssertEqual(backend.restoreCount(), 0, "Restore must be skipped — user wrote to clipboard mid-transform")
    }

    func testReplacePreservesClipboardUserCopiedBetweenCaptureAndPaste() async throws {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: false,
            pasteboardWriteSucceeds: true,
            initialChangeCount: 12
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))
        let preTransformSnapshot = PasteboardSnapshot(
            items: nil,
            originalChangeCount: 10,
            temporaryChangeCount: 11
        )

        _ = try await service.replace(
            with: "polished",
            in: .clipboard(text: "raw", savedClipboard: preTransformSnapshot, target: nil)
        )

        XCTAssertEqual(backend.cmdVPostCount(), 1)
        XCTAssertEqual(backend.restoreCount(), 1)
        XCTAssertEqual(backend.lastRestoredChangeCount(), 12, "Restore should use the user's newer clipboard snapshot, not the pre-transform one")
    }

    func testClipboardPasteReactivatesOriginalTargetBeforeCmdV() async throws {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: false
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))
        let snapshot = PasteboardSnapshot(items: nil, originalChangeCount: 42)
        let target = SelectionCaptureTarget(
            processIdentifier: 1234,
            bundleIdentifier: "com.example.Source"
        )

        _ = try await service.replace(
            with: "polished",
            in: .clipboard(text: "raw", savedClipboard: snapshot, target: target)
        )

        XCTAssertEqual(backend.activatedTargets(), [target])
        XCTAssertEqual(backend.cmdVPostCount(), 1)
    }

    func testClipboardPasteDoesNotPostCmdVWhenTargetActivationFails() async {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: false,
            targetActivationSucceeds: false
        )
        let service = SelectionReplacementService(backend: backend, postPasteDelay: .milliseconds(1))
        let snapshot = PasteboardSnapshot(items: nil, originalChangeCount: 42)

        do {
            _ = try await service.replace(
                with: "polished",
                in: .clipboard(
                    text: "raw",
                    savedClipboard: snapshot,
                    target: SelectionCaptureTarget(
                        processIdentifier: 1234,
                        bundleIdentifier: "com.example.Source"
                    )
                )
            )
            XCTFail("Expected targetActivationFailed")
        } catch let error as SelectionReplacementError {
            XCTAssertEqual(error, .targetActivationFailed)
            XCTAssertEqual(backend.cmdVPostCount(), 0)
            XCTAssertGreaterThanOrEqual(backend.restoreCount(), 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testClipboardPasteDoesNotPostCmdVUntilTargetIsFrontmost() async {
        let backend = FakeSelectionReplacementBackend(
            isTrusted: true,
            axWriteSucceeds: false,
            targetActivationSucceeds: true,
            activationMakesTargetFrontmost: false
        )
        let service = SelectionReplacementService(
            backend: backend,
            postPasteDelay: .milliseconds(1),
            activationTimeout: .milliseconds(1),
            activationPollIntervalNanos: 1_000_000
        )
        let snapshot = PasteboardSnapshot(items: nil, originalChangeCount: 42)

        do {
            _ = try await service.replace(
                with: "polished",
                in: .clipboard(
                    text: "raw",
                    savedClipboard: snapshot,
                    target: SelectionCaptureTarget(
                        processIdentifier: 1234,
                        bundleIdentifier: "com.example.Source"
                    )
                )
            )
            XCTFail("Expected targetActivationFailed")
        } catch let error as SelectionReplacementError {
            XCTAssertEqual(error, .targetActivationFailed)
            XCTAssertEqual(backend.cmdVPostCount(), 0)
            XCTAssertGreaterThanOrEqual(backend.frontmostCheckCount(), 1)
            XCTAssertGreaterThanOrEqual(backend.restoreCount(), 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

// MARK: - Fake Backend

/// Thread-safe state container so a Sendable backend can record calls and
/// the test can read them back without coupling to actor isolation.
final class FakeSelectionReplacementBackend: SelectionReplacementBackend, @unchecked Sendable {
    private let trusted: Bool
    private let axWriteSucceedsValue: Bool
    private let pasteboardWriteSucceedsValue: Bool
    private let simulateUserCopyAfterWrite: Bool
    private let targetActivationSucceeds: Bool
    private let activationMakesTargetFrontmost: Bool
    private let lock = OSAllocatedUnfairLock<State>(initialState: State())

    private struct State {
        var axTexts: [String] = []
        var clipboardTexts: [String] = []
        var activatedTargets: [SelectionCaptureTarget] = []
        var frontmostTarget: SelectionCaptureTarget?
        var frontmostChecks: Int = 0
        var cmdVPosts: Int = 0
        var restoreSnapshots: [PasteboardSnapshot] = []
        /// Simulated pasteboard changeCount. Bumped on `writePasteboardString`
        /// (mirroring `setString`'s behavior in production) and optionally
        /// bumped after our own write-count has been observed once to
        /// simulate a concurrent user copy mid-transform.
        var changeCount: Int = 0
        var pastePayloadWritten = false
        var returnedOurChangeCountAfterWrite = false
    }

    init(
        isTrusted: Bool,
        axWriteSucceeds: Bool = false,
        pasteboardWriteSucceeds: Bool = true,
        simulateUserCopyAfterWrite: Bool = false,
        targetActivationSucceeds: Bool = true,
        activationMakesTargetFrontmost: Bool = true,
        initialChangeCount: Int = 0
    ) {
        self.trusted = isTrusted
        self.axWriteSucceedsValue = axWriteSucceeds
        self.pasteboardWriteSucceedsValue = pasteboardWriteSucceeds
        self.simulateUserCopyAfterWrite = simulateUserCopyAfterWrite
        self.targetActivationSucceeds = targetActivationSucceeds
        self.activationMakesTargetFrontmost = activationMakesTargetFrontmost
        lock.withLock { $0.changeCount = initialChangeCount }
    }

    func isAccessibilityTrusted() -> Bool { trusted }

    func writeSelectionViaAX(_ text: String, element: AXUIElement) -> Bool {
        lock.withLock { $0.axTexts.append(text) }
        return axWriteSucceedsValue
    }

    @MainActor
    func writePasteboardString(_ text: String) -> Bool {
        lock.withLock { state in
            state.clipboardTexts.append(text)
            if pasteboardWriteSucceedsValue {
                state.changeCount += 1
                state.pastePayloadWritten = true
                state.returnedOurChangeCountAfterWrite = false
            }
        }
        return pasteboardWriteSucceedsValue
    }

    @MainActor
    func activateApplication(target: SelectionCaptureTarget) -> Bool {
        lock.withLock { state in
            state.activatedTargets.append(target)
            if targetActivationSucceeds, activationMakesTargetFrontmost {
                state.frontmostTarget = target
            }
        }
        return targetActivationSucceeds
    }

    @MainActor
    func isFrontmostApplication(target: SelectionCaptureTarget) -> Bool {
        lock.withLock { state in
            state.frontmostChecks += 1
            return state.frontmostTarget == target
        }
    }

    @MainActor
    func postCmdV() throws {
        lock.withLock { $0.cmdVPosts += 1 }
    }

    @MainActor
    func currentChangeCount() -> Int {
        let simulateBump = simulateUserCopyAfterWrite
        return lock.withLock { state in
            if simulateBump,
               state.pastePayloadWritten,
               state.returnedOurChangeCountAfterWrite {
                return state.changeCount + 1
            }
            if state.pastePayloadWritten {
                state.returnedOurChangeCountAfterWrite = true
            }
            return state.changeCount
        }
    }

    @MainActor
    func snapshotPasteboard() -> PasteboardSnapshot {
        let changeCount = lock.withLock { $0.changeCount }
        return PasteboardSnapshot(items: nil, originalChangeCount: changeCount)
    }

    @MainActor
    func restoreSnapshot(_ snapshot: PasteboardSnapshot) {
        lock.withLock { $0.restoreSnapshots.append(snapshot) }
    }

    // Test accessors

    func lastAXText() -> String? {
        lock.withLock { $0.axTexts.last }
    }

    func lastClipboardText() -> String? {
        lock.withLock { $0.clipboardTexts.last }
    }

    func cmdVPostCount() -> Int {
        lock.withLock { $0.cmdVPosts }
    }

    func activatedTargets() -> [SelectionCaptureTarget] {
        lock.withLock { $0.activatedTargets }
    }

    func frontmostCheckCount() -> Int {
        lock.withLock { $0.frontmostChecks }
    }

    func restoreCount() -> Int {
        lock.withLock { $0.restoreSnapshots.count }
    }

    func lastRestoredChangeCount() -> Int? {
        lock.withLock { $0.restoreSnapshots.last?.originalChangeCount }
    }
}
