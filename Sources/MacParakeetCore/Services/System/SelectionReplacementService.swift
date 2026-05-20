import AppKit
import ApplicationServices
import Carbon
import Foundation
import OSLog

// MARK: - Public Types

public enum SelectionReplacementPath: String, Sendable, Equatable {
    /// AX `kAXSelectedTextAttribute` write succeeded.
    case ax
    /// Paste-back via Cmd+V succeeded (either AX-write was unavailable or
    /// failed, or the original capture was `.clipboard`).
    case clipboardPaste
}

public enum SelectionReplacementMode: Sendable, Equatable {
    /// Prefer zero-side-effect AX replacement, then fall back to clipboard
    /// paste into the original selection target.
    case replaceSelection
    /// Always paste the transformed output through the currently focused
    /// target. This keeps read-only selections useful: capture can happen in
    /// one surface while paste lands wherever focus is when the run finishes.
    case pasteIntoCurrentFocus
}

public enum SelectionReplacementError: Error, LocalizedError, Sendable {
    case accessibilityNotAuthorized
    case eventSourceUnavailable
    case pasteboardWriteFailed
    case eventPostingFailed
    case targetActivationFailed
    case allPathsFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityNotAuthorized:
            return "Accessibility permission required to replace selection."
        case .eventSourceUnavailable:
            return "Could not create a CGEventSource for paste simulation."
        case .pasteboardWriteFailed:
            return "Could not write replacement text to the clipboard."
        case .eventPostingFailed:
            return "Failed to post Cmd+V keystroke."
        case .targetActivationFailed:
            return "Could not reactivate the original app before pasting."
        case .allPathsFailed:
            return "Selection replacement failed via both AX-write and clipboard paste."
        }
    }
}

// MARK: - Backend Protocol

protocol SelectionReplacementBackend: Sendable {
    func isAccessibilityTrusted() -> Bool
    /// Attempt to write the new text via AX. Returns `true` when
    /// `AXUIElementSetAttributeValue(kAXSelectedTextAttribute, …)` returns
    /// `.success`. We deliberately do NOT verify via a re-read: substring
    /// "contains" verification false-positives when the inserted text
    /// already appeared elsewhere in the field, and reading `kAXValue` is
    /// brittle (many web/Electron fields don't expose it). Apps where AX
    /// claims success but doesn't actually update will surface in the smoke
    /// matrix and we'll fall back to clipboard-paste for those.
    func writeSelectionViaAX(_ text: String, element: AXUIElement) -> Bool

    @MainActor
    func writePasteboardString(_ text: String) -> Bool

    @MainActor
    func activateApplication(target: SelectionCaptureTarget) -> Bool

    @MainActor
    func isFrontmostApplication(target: SelectionCaptureTarget) -> Bool

    @MainActor
    func postCmdV() throws

    /// Current `NSPasteboard.changeCount`. Used by the restore guard to
    /// detect whether the user copied something else during the
    /// paste-and-restore window — if so, we preserve their newer content
    /// instead of clobbering it with our stale snapshot.
    @MainActor
    func currentChangeCount() -> Int

    @MainActor
    func snapshotPasteboard() -> PasteboardSnapshot

    @MainActor
    func restoreSnapshot(_ snapshot: PasteboardSnapshot)
}

// MARK: - Service

/// Replaces the user's current selection with new text. AX-write first
/// (zero side effects on clipboard), paste-back via Cmd+V otherwise.
///
/// See `docs/research/transforms-design-2026-05.md` §2 — the design accepts
/// a small clipboard race window (~500ms) in exchange for a working
/// universal path across every macOS app. Snapshot restoration runs even on
/// failure to keep the user's pre-transform clipboard contents safe.
public actor SelectionReplacementService {
    /// Time to wait for the paste to land before restoring the original
    /// clipboard snapshot. 500ms matches the conventional "Espanso / Raycast"
    /// value and the Gemini-review feedback on the capture side.
    public static let defaultPostPasteDelay: Duration = .milliseconds(500)
    public static let defaultActivationTimeout: Duration = .milliseconds(500)

    private let backend: any SelectionReplacementBackend
    private let postPasteDelay: Duration
    private let activationTimeout: Duration
    private let activationPollIntervalNanos: UInt64
    private let logger: Logger

    public init() {
        self.init(backend: SystemSelectionReplacementBackend())
    }

    init(
        backend: any SelectionReplacementBackend,
        postPasteDelay: Duration = SelectionReplacementService.defaultPostPasteDelay,
        activationTimeout: Duration = SelectionReplacementService.defaultActivationTimeout,
        activationPollIntervalNanos: UInt64 = 10_000_000,
        logger: Logger = Logger(subsystem: "com.macparakeet.core", category: "SelectionReplacementService")
    ) {
        self.backend = backend
        self.postPasteDelay = postPasteDelay
        self.activationTimeout = activationTimeout
        self.activationPollIntervalNanos = activationPollIntervalNanos
        self.logger = logger
    }

    /// Replace the user's selection (captured via `SelectionCaptureService`)
    /// with `newText`. Returns the path used, or throws on hard failure.
    @discardableResult
    public func replace(
        with newText: String,
        in context: SelectionCaptureResult,
        mode: SelectionReplacementMode = .replaceSelection
    ) async throws -> SelectionReplacementPath {
        if mode == .pasteIntoCurrentFocus {
            return try await pasteIntoCurrentFocus(newText: newText, context: context)
        }

        switch context {
        case .ax(_, let focused, _):
            // AX-write is the no-side-effect path. If it succeeds, we're done.
            if backend.writeSelectionViaAX(newText, element: focused.element) {
                return .ax
            }
            // Fall through to clipboard paste (no original snapshot — the AX
            // capture path didn't touch the clipboard, so we capture a fresh
            // snapshot here to preserve whatever the user had on it).
            let freshSnapshot = await snapshotPasteboardForFallback()
            try await pasteAndRestore(newText: newText, snapshot: freshSnapshot, target: context.target)
            return .clipboardPaste

        case .clipboard(_, let savedSnapshot, _):
            // Original capture already hijacked the clipboard. Paste then
            // restore the snapshot we promised the user we'd put back. If the
            // user copied something else while the LLM was running, preserve
            // that newer clipboard instead of the pre-transform snapshot.
            let restoreSnapshot = await snapshotForClipboardContext(savedSnapshot)
            try await pasteAndRestore(newText: newText, snapshot: restoreSnapshot, target: context.target)
            return .clipboardPaste

        case .empty, .failed:
            throw SelectionReplacementError.allPathsFailed
        }
    }

    private func pasteIntoCurrentFocus(
        newText: String,
        context: SelectionCaptureResult
    ) async throws -> SelectionReplacementPath {
        switch context {
        case .ax:
            let snapshot = await snapshotPasteboardForFallback()
            try await pasteAndRestore(newText: newText, snapshot: snapshot, target: nil)
            return .clipboardPaste

        case .clipboard(_, let savedSnapshot, _):
            let restoreSnapshot = await snapshotForClipboardContext(savedSnapshot)
            try await pasteAndRestore(newText: newText, snapshot: restoreSnapshot, target: nil)
            return .clipboardPaste

        case .empty, .failed:
            throw SelectionReplacementError.allPathsFailed
        }
    }

    @MainActor
    private func snapshotPasteboardForFallback() -> PasteboardSnapshot {
        backend.snapshotPasteboard()
    }

    private func snapshotForClipboardContext(_ savedSnapshot: PasteboardSnapshot) async -> PasteboardSnapshot {
        guard let temporaryChangeCount = savedSnapshot.temporaryChangeCount else {
            return savedSnapshot
        }

        let now = await currentChangeCountOnMain()
        guard now != temporaryChangeCount else {
            return savedSnapshot
        }

        logger.notice("transforms-spike: preserving clipboard content copied during LLM phase (capture=\(temporaryChangeCount, privacy: .public), now=\(now, privacy: .public))")
        return await snapshotPasteboardForFallback()
    }

    private func pasteAndRestore(
        newText: String,
        snapshot: PasteboardSnapshot,
        target: SelectionCaptureTarget?
    ) async throws {
        // Write our payload and capture the changeCount *after* the write —
        // that's the value the restore guard compares against. If anyone
        // else (the user) writes to the clipboard between now and the
        // restore step, the count will be higher and we'll preserve their
        // newer content instead of clobbering it.
        guard let ourChangeCount = await writeAndCaptureChangeCountOnMain(newText) else {
            // Write failed before we put anything user-relevant on the
            // clipboard. Restore unconditionally — we may have already
            // called clearContents().
            await restoreSnapshotOnMain(snapshot)
            throw SelectionReplacementError.pasteboardWriteFailed
        }

        if let target {
            guard await activateAndWaitForTarget(target) else {
                await restoreIfSafe(snapshot, ourChangeCount: ourChangeCount)
                throw SelectionReplacementError.targetActivationFailed
            }
        }

        do {
            try await postCmdVOnMain()
        } catch let error as SelectionReplacementError {
            await restoreIfSafe(snapshot, ourChangeCount: ourChangeCount)
            throw error
        } catch {
            await restoreIfSafe(snapshot, ourChangeCount: ourChangeCount)
            throw SelectionReplacementError.eventPostingFailed
        }

        // Give the host app time to consume the paste before restoring the
        // saved snapshot. Short enough that the user doesn't see a stale
        // pasteboard, long enough that slow apps (Slack, Mail) finish.
        try? await Task.sleep(for: postPasteDelay)
        await restoreIfSafe(snapshot, ourChangeCount: ourChangeCount)
    }

    @MainActor
    private func writeAndCaptureChangeCountOnMain(_ text: String) -> Int? {
        guard backend.writePasteboardString(text) else { return nil }
        return backend.currentChangeCount()
    }

    @MainActor
    private func activateApplicationOnMain(_ target: SelectionCaptureTarget) -> Bool {
        backend.activateApplication(target: target)
    }

    private func activateAndWaitForTarget(_ target: SelectionCaptureTarget) async -> Bool {
        guard await activateApplicationOnMain(target) else {
            return false
        }

        let deadline = ContinuousClock.now + activationTimeout
        while ContinuousClock.now < deadline {
            if await isFrontmostApplicationOnMain(target) {
                return true
            }
            try? await Task.sleep(nanoseconds: activationPollIntervalNanos)
        }
        return await isFrontmostApplicationOnMain(target)
    }

    @MainActor
    private func isFrontmostApplicationOnMain(_ target: SelectionCaptureTarget) -> Bool {
        backend.isFrontmostApplication(target: target)
    }

    @MainActor
    private func postCmdVOnMain() throws {
        try backend.postCmdV()
    }

    @MainActor
    private func restoreSnapshotOnMain(_ snapshot: PasteboardSnapshot) {
        backend.restoreSnapshot(snapshot)
    }

    /// Only restore the saved snapshot if the pasteboard's changeCount is
    /// still the one we set when we wrote our paste payload. A higher count
    /// means the user copied something else during our paste window — we
    /// preserve their content rather than reverting to our stale snapshot.
    private func restoreIfSafe(_ snapshot: PasteboardSnapshot, ourChangeCount: Int) async {
        let now = await currentChangeCountOnMain()
        if now == ourChangeCount {
            await restoreSnapshotOnMain(snapshot)
        } else {
            logger.notice("transforms-spike: skipping clipboard restore — user copied content mid-transform (ours=\(ourChangeCount, privacy: .public), now=\(now, privacy: .public))")
        }
    }

    @MainActor
    private func currentChangeCountOnMain() -> Int {
        backend.currentChangeCount()
    }
}

// MARK: - System Backend

// `@unchecked Sendable` for the same reason as
// `SystemSelectionCaptureBackend`: the `NSPasteboard` reference is only used
// from `@MainActor` methods. The AX write path is pure.
struct SystemSelectionReplacementBackend: SelectionReplacementBackend, @unchecked Sendable {
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

    func writeSelectionViaAX(_ text: String, element: AXUIElement) -> Bool {
        // Trust the AX setStatus directly. The earlier post-write
        // `value.contains(text)` verification looked safer but actually
        // false-positively reported success whenever the inserted text
        // already appeared anywhere else in the field — masking a real
        // AX-write failure and skipping the clipboard fallback that would
        // have worked. Apps that silently accept-and-discard
        // `kAXSelectedTextAttribute` writes will show up in the smoke matrix
        // as "AX capture Y, AX write Y, selection wasn't actually replaced"
        // and we'll downgrade those to clipboard-only in Phase 2.
        let setStatus = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        )
        return setStatus == .success
    }

    @MainActor
    func writePasteboardString(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    @MainActor
    func activateApplication(target: SelectionCaptureTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier),
              app.bundleIdentifier == target.bundleIdentifier
        else {
            return false
        }
        return app.activate()
    }

    @MainActor
    func isFrontmostApplication(target: SelectionCaptureTarget) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return app.processIdentifier == target.processIdentifier
            && app.bundleIdentifier == target.bundleIdentifier
    }

    @MainActor
    func currentChangeCount() -> Int {
        pasteboard.changeCount
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
    func postCmdV() throws {
        guard AXIsProcessTrusted() else {
            throw SelectionReplacementError.accessibilityNotAuthorized
        }
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw SelectionReplacementError.eventSourceUnavailable
        }
        let vKeyCode = shortcutKeyResolver.virtualKeyCode(
            for: "v",
            modifierKeyState: UInt32(cmdKey >> 8)
        )
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            throw SelectionReplacementError.eventPostingFailed
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
