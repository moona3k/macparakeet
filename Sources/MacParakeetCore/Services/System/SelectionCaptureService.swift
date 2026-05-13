import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog

// MARK: - Result Types

/// Source of a successful selection read. Used by `TransformExecutor` to pick
/// the right replacement path: an `.ax` capture can attempt an AX-write first,
/// while a `.clipboard` capture must paste-back via Cmd+V.
public enum SelectionCaptureResult: @unchecked Sendable {
    /// AX read returned a non-empty `kAXSelectedTextAttribute`. The element
    /// handle is retained so the replacement service can try `AXUIElementSet`
    /// before falling back to clipboard paste-back.
    case ax(text: String, element: AXFocusedElement, target: SelectionCaptureTarget?)

    /// AX read returned empty/unsupported; clipboard hijack (Cmd+C + poll
    /// `changeCount`) found non-empty text. The captured snapshot must be
    /// restored after replacement completes.
    case clipboard(text: String, savedClipboard: PasteboardSnapshot, target: SelectionCaptureTarget?)

    /// Neither AX nor clipboard hijack returned non-empty text.
    case empty

    /// A hard failure (e.g., AX permission denied at the system layer). The
    /// pipeline should surface a user-visible error.
    case failed(SelectionCaptureError)

    public var capturedText: String? {
        switch self {
        case .ax(let text, _, _), .clipboard(let text, _, _):
            return text
        case .empty, .failed:
            return nil
        }
    }

    public var target: SelectionCaptureTarget? {
        switch self {
        case .ax(_, _, let target), .clipboard(_, _, let target):
            return target
        case .empty, .failed:
            return nil
        }
    }

    /// Telemetry/diagnostic tag for log lines.
    public var pathTag: String {
        switch self {
        case .ax: return "ax"
        case .clipboard: return "clipboard"
        case .empty: return "empty"
        case .failed: return "failed"
        }
    }
}

public enum SelectionCaptureError: Error, LocalizedError, Sendable {
    case accessibilityNotAuthorized
    case eventSourceUnavailable
    case eventPostingFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotAuthorized:
            return "Accessibility permission required to read selected text."
        case .eventSourceUnavailable:
            return "Could not create a CGEventSource for the clipboard-fallback path."
        case .eventPostingFailed:
            return "Failed to post Cmd+C during clipboard-fallback selection capture."
        }
    }
}

/// `@unchecked Sendable` wrapper around an `AXUIElement` reference. `AXUIElement`
/// is a CFType that the AX framework treats as thread-safe for the read/write
/// calls the spike uses (`AXUIElementCopyAttributeValue` /
/// `AXUIElementSetAttributeValue`). Wrapping it lets the result type cross
/// actor boundaries without further annotation.
public struct AXFocusedElement: @unchecked Sendable {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }
}

/// The app that owned the selection when the Transform was triggered.
public struct SelectionCaptureTarget: Sendable, Equatable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String

    public init(processIdentifier: pid_t, bundleIdentifier: String) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Snapshot of the pasteboard items captured before a clipboard hijack. Held
/// opaquely so callers don't have to know about AppKit types. `@unchecked
/// Sendable` because `NSPasteboardItem` is not Sendable but our usage is
/// effectively immutable after capture.
public struct PasteboardSnapshot: @unchecked Sendable {
    public let items: [NSPasteboardItem]?
    public let originalChangeCount: Int
    public let temporaryChangeCount: Int?

    public init(
        items: [NSPasteboardItem]?,
        originalChangeCount: Int,
        temporaryChangeCount: Int? = nil
    ) {
        self.items = items
        self.originalChangeCount = originalChangeCount
        self.temporaryChangeCount = temporaryChangeCount
    }

    /// Empty placeholder — useful for tests and the `.empty` no-op path.
    public static let none = PasteboardSnapshot(items: nil, originalChangeCount: 0)

    public func withTemporaryChangeCount(_ changeCount: Int) -> PasteboardSnapshot {
        PasteboardSnapshot(
            items: items,
            originalChangeCount: originalChangeCount,
            temporaryChangeCount: changeCount
        )
    }
}

// MARK: - Backend Protocol (for testability)

/// Minimal protocol the capture service depends on. Production wires up a
/// `SystemSelectionCaptureBackend`; tests wire up a fake.
protocol SelectionCaptureBackend: Sendable {
    func isAccessibilityTrusted() -> Bool
    func focusedElement() -> AXUIElement?
    func selectedText(of element: AXUIElement) -> String?

    @MainActor
    func frontmostApplicationTarget() -> SelectionCaptureTarget?

    /// Snapshot the pasteboard and return the saved items + the changeCount at
    /// snapshot time (so the poll loop can detect the Cmd+C-triggered change).
    @MainActor
    func snapshotPasteboard() -> PasteboardSnapshot

    /// Read the latest pasteboard string (used by the post-Cmd+C poll).
    @MainActor
    func currentPasteboardString() -> String?

    /// Return the current pasteboard changeCount.
    @MainActor
    func currentPasteboardChangeCount() -> Int

    /// Post a synthetic Cmd+C event pair.
    @MainActor
    func postCmdC() throws

    /// Restore a previously-captured pasteboard snapshot. Called when the
    /// hijack succeeded in moving the change count but didn't yield text
    /// content (image / file etc.) — without this, the user's pre-hijack
    /// clipboard is silently destroyed.
    @MainActor
    func restoreSnapshot(_ snapshot: PasteboardSnapshot)
}

// MARK: - Service

/// Captures the currently-selected text in the frontmost macOS app.
///
/// AX-first, clipboard-hijack fallback. See
/// `docs/research/transforms-design-2026-05.md` Architecture sketch §1 for
/// the high-level design, and the Risk and unknowns section for why we keep
/// the clipboard fallback unconditionally.
///
/// The poll budget after Cmd+C is **500 ms** (per Gemini review feedback —
/// 250 ms was too tight in practice for apps like Mail / Slack that resolve
/// pasteboard writes through their own event loop).
public actor SelectionCaptureService {
    /// Default poll budget while waiting for Cmd+C to land a new pasteboard
    /// change count.
    public static let defaultClipboardPollTimeout: Duration = .milliseconds(500)

    private let backend: any SelectionCaptureBackend
    private let logger: Logger
    private let clipboardPollTimeout: Duration
    private let pollIntervalNanos: UInt64

    /// Production initializer — uses the real AX + pasteboard backend.
    public init() {
        self.init(backend: SystemSelectionCaptureBackend())
    }

    init(
        backend: any SelectionCaptureBackend,
        clipboardPollTimeout: Duration = SelectionCaptureService.defaultClipboardPollTimeout,
        pollIntervalNanos: UInt64 = 15_000_000,  // 15 ms
        logger: Logger = Logger(subsystem: "com.macparakeet.core", category: "SelectionCaptureService")
    ) {
        self.backend = backend
        self.clipboardPollTimeout = clipboardPollTimeout
        self.pollIntervalNanos = pollIntervalNanos
        self.logger = logger
    }

    /// Try to capture the user's current selection. Never throws — returns a
    /// `.failed` case for hard errors. Callers should treat `.empty` as the
    /// "no selection" UX path (toast: select text first).
    public func captureSelection() async -> SelectionCaptureResult {
        // AX-first path.
        guard backend.isAccessibilityTrusted() else {
            return .failed(.accessibilityNotAuthorized)
        }

        let target = await captureTargetOnMain()

        if let element = backend.focusedElement() {
            if let text = backend.selectedText(of: element),
               !text.isEmpty {
                return .ax(text: text, element: AXFocusedElement(element), target: target)
            }
        }

        // Clipboard-hijack fallback.
        return await clipboardHijack(target: target)
    }

    /// Restore a clipboard capture that is being abandoned before replacement.
    /// The guard preserves user clipboard writes made while the LLM was running:
    /// we only restore if the pasteboard is still at the Cmd+C change count
    /// created by `clipboardHijack()`.
    func restoreClipboardCaptureIfCurrent(_ result: SelectionCaptureResult) async {
        guard case .clipboard(_, let snapshot, _) = result else { return }

        guard let temporaryChangeCount = snapshot.temporaryChangeCount else {
            await restoreSnapshotOnMain(snapshot)
            return
        }

        let now = await currentChangeCountOnMain()
        if now == temporaryChangeCount {
            await restoreSnapshotOnMain(snapshot)
        } else {
            logger.notice("transforms-spike: skipping abandoned-capture clipboard restore — user copied content mid-transform (capture=\(temporaryChangeCount, privacy: .public), now=\(now, privacy: .public))")
        }
    }

    // MARK: - Clipboard Hijack

    private func clipboardHijack(target: SelectionCaptureTarget?) async -> SelectionCaptureResult {
        let snapshot = await snapshotPasteboardOnMain()
        do {
            try await postCmdCOnMain()
        } catch let error as SelectionCaptureError {
            return .failed(error)
        } catch {
            return .failed(.eventPostingFailed)
        }

        // Poll for change count delta within the budget. The string read is
        // intentionally done after the change-count check so we don't race
        // with the pasteboard mutating mid-Cmd+C.
        let deadline = ContinuousClock.now + clipboardPollTimeout
        while ContinuousClock.now < deadline {
            if Task.isCancelled {
                await restoreSnapshotOnMain(snapshot)
                return .empty
            }
            let now = await currentChangeCountOnMain()
            if now != snapshot.originalChangeCount {
                if let text = await currentStringOnMain(), !text.isEmpty {
                    return .clipboard(text: text, savedClipboard: snapshot.withTemporaryChangeCount(now), target: target)
                }
                // Change count moved but no string available (image, file, etc.).
                // Cmd+C *did* write — the user's pre-hijack clipboard is now
                // gone unless we put it back. Restore before bailing.
                await restoreSnapshotOnMain(snapshot)
                return .empty
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanos)
        }

        // No change count delta — selection was empty. Pasteboard wasn't
        // touched (Cmd+C with no selection is a no-op) so nothing to restore.
        return .empty
    }

    @MainActor
    private func captureTargetOnMain() -> SelectionCaptureTarget? {
        backend.frontmostApplicationTarget()
    }

    @MainActor
    private func snapshotPasteboardOnMain() -> PasteboardSnapshot {
        backend.snapshotPasteboard()
    }

    @MainActor
    private func currentChangeCountOnMain() -> Int {
        backend.currentPasteboardChangeCount()
    }

    @MainActor
    private func currentStringOnMain() -> String? {
        backend.currentPasteboardString()
    }

    @MainActor
    private func postCmdCOnMain() throws {
        try backend.postCmdC()
    }

    @MainActor
    private func restoreSnapshotOnMain(_ snapshot: PasteboardSnapshot) {
        backend.restoreSnapshot(snapshot)
    }
}

// MARK: - System Backend

// `@unchecked Sendable` because the stored `NSPasteboard` reference is only
// touched from `@MainActor` methods — the AX read paths are pure (no shared
// mutable state).
struct SystemSelectionCaptureBackend: SelectionCaptureBackend, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let shortcutKeyResolver: PasteShortcutKeyResolver

    init(
        pasteboard: NSPasteboard = .general,
        shortcutKeyResolver: PasteShortcutKeyResolver = PasteShortcutKeyResolver()
    ) {
        self.pasteboard = pasteboard
        self.shortcutKeyResolver = shortcutKeyResolver
    }

    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func focusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        )
        guard status == .success, let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(raw as AnyObject, to: AXUIElement.self)
    }

    func selectedText(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &raw
        )
        guard status == .success, let raw else { return nil }
        let value = raw as? String
        return value?.isEmpty == true ? nil : value
    }

    @MainActor
    func frontmostApplicationTarget() -> SelectionCaptureTarget? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = app.bundleIdentifier
        else {
            return nil
        }
        return SelectionCaptureTarget(
            processIdentifier: app.processIdentifier,
            bundleIdentifier: bundleIdentifier
        )
    }

    @MainActor
    func snapshotPasteboard() -> PasteboardSnapshot {
        let items = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
        return PasteboardSnapshot(items: items, originalChangeCount: pasteboard.changeCount)
    }

    @MainActor
    func currentPasteboardString() -> String? {
        pasteboard.string(forType: .string)
    }

    @MainActor
    func currentPasteboardChangeCount() -> Int {
        pasteboard.changeCount
    }

    @MainActor
    func postCmdC() throws {
        guard AXIsProcessTrusted() else {
            throw SelectionCaptureError.accessibilityNotAuthorized
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SelectionCaptureError.eventSourceUnavailable
        }
        let cKeyCode = shortcutKeyResolver.virtualKeyCode(
            for: "c",
            modifierKeyState: UInt32(cmdKey >> 8)
        )
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false) else {
            throw SelectionCaptureError.eventPostingFailed
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    @MainActor
    func restoreSnapshot(_ snapshot: PasteboardSnapshot) {
        guard let items = snapshot.items, !items.isEmpty else {
            pasteboard.clearContents()
            return
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
