import AppKit
import Carbon
import Foundation
import OSLog

public protocol ClipboardServiceProtocol: Sendable {
    func pasteText(_ text: String) async throws
    func pasteText(_ text: String, restoresClipboard: Bool) async throws
    /// Paste text then simulate a keystroke. Returns `true` if the keystroke was actually fired.
    func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws -> Bool
    /// Paste text then simulate a keystroke. Returns `true` if the keystroke was actually fired.
    func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?, restoresClipboard: Bool) async throws -> Bool
    @discardableResult
    func copyToClipboard(_ text: String) async -> Bool
}

public enum ClipboardServiceError: LocalizedError {
    case accessibilityPermissionRequired
    case eventSourceUnavailable
    case eventCreationFailed
    case pasteboardWriteFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required for auto-paste."
        case .eventSourceUnavailable:
            return "Paste automation unavailable (event source creation failed)."
        case .eventCreationFailed:
            return "Paste automation unavailable (could not create keyboard events)."
        case .pasteboardWriteFailed:
            return "Paste automation unavailable (could not write transcript to the clipboard)."
        }
    }
}

protocol ClipboardEventPosting {
    @MainActor
    func simulatePaste(using pasteShortcutKeyResolver: PasteShortcutKeyResolver) throws
    @MainActor
    func simulateKeystroke(_ keyCode: UInt16) throws
}

struct CGClipboardEventPosting: ClipboardEventPosting {
    @MainActor
    func simulatePaste(using pasteShortcutKeyResolver: PasteShortcutKeyResolver) throws {
        guard AXIsProcessTrusted() else {
            throw ClipboardServiceError.accessibilityPermissionRequired
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ClipboardServiceError.eventSourceUnavailable
        }

        // Resolve under the same Command-modified layout state that the CGEvents carry.
        let vKeyCode = pasteShortcutKeyResolver.virtualKeyCode(for: "v", modifierKeyState: UInt32(cmdKey >> 8))

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            throw ClipboardServiceError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    @MainActor
    func simulateKeystroke(_ keyCode: UInt16) throws {
        guard AXIsProcessTrusted() else {
            throw ClipboardServiceError.accessibilityPermissionRequired
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ClipboardServiceError.eventSourceUnavailable
        }

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw ClipboardServiceError.eventCreationFailed
        }

        keyDown.flags = []
        keyUp.flags = []

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}

@MainActor
private final class ClipboardRestoreCoordinator {
    private struct PendingRestore {
        let originalItems: [NSPasteboardItem]?
        var latestTemporaryChangeCount: Int
        let generation: UInt64
    }

    private var pendingRestore: PendingRestore?
    private var generation: UInt64 = 0
    private let restoreAttemptObserver: (@MainActor () -> Void)?

    init(restoreAttemptObserver: (@MainActor () -> Void)? = nil) {
        self.restoreAttemptObserver = restoreAttemptObserver
    }

    func originalItemsForNewPaste(
        currentItems: [NSPasteboardItem]?,
        currentChangeCount: Int
    ) -> [NSPasteboardItem]? {
        if let pendingRestore {
            guard currentChangeCount == pendingRestore.latestTemporaryChangeCount else {
                self.pendingRestore = nil
                return currentItems
            }

            return pendingRestore.originalItems
        }

        return currentItems
    }

    func temporaryClipboardWasRestoredAfterFailedWrite(
        previousChangeCount: Int,
        restoredChangeCount: Int
    ) {
        guard var pendingRestore else {
            return
        }
        guard previousChangeCount == pendingRestore.latestTemporaryChangeCount else {
            return
        }

        pendingRestore.latestTemporaryChangeCount = restoredChangeCount
        self.pendingRestore = pendingRestore
    }

    func scheduleRestore(
        pasteboard: NSPasteboard,
        originalItems: [NSPasteboardItem]?,
        latestTemporaryChangeCount: Int,
        delay: TimeInterval
    ) {
        generation += 1
        let restoreGeneration = generation
        pendingRestore = PendingRestore(
            originalItems: originalItems,
            latestTemporaryChangeCount: latestTemporaryChangeCount,
            generation: restoreGeneration
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated {
                self.restoreIfCurrent(pasteboard: pasteboard, generation: restoreGeneration)
            }
        }
    }

    func cancelPendingRestore() {
        pendingRestore = nil
    }

    private func restoreIfCurrent(pasteboard: NSPasteboard, generation: UInt64) {
        defer {
            restoreAttemptObserver?()
        }

        guard let pendingRestore, pendingRestore.generation == generation else {
            return
        }

        defer {
            self.pendingRestore = nil
        }

        guard pasteboard.changeCount == pendingRestore.latestTemporaryChangeCount else {
            return
        }

        pasteboard.clearContents()
        if let originalItems = pendingRestore.originalItems, !originalItems.isEmpty {
            pasteboard.writeObjects(originalItems)
        }
    }
}

/// Handles clipboard save/restore and paste simulation via Cmd+V.
@MainActor
public final class ClipboardService: ClipboardServiceProtocol {
    nonisolated static let defaultClipboardRestoreDelay: TimeInterval = 0.5
    private static let sharedRestoreCoordinator = ClipboardRestoreCoordinator()

    private let logger = Logger(subsystem: "com.macparakeet.core", category: "ClipboardService")
    private let pasteboard: NSPasteboard
    private let pasteShortcutKeyResolver: PasteShortcutKeyResolver
    private let eventPosting: ClipboardEventPosting
    private let clipboardRestoreDelay: TimeInterval
    private let restoreCoordinator: ClipboardRestoreCoordinator
    private let pasteboardStringWriter: @MainActor (NSPasteboard, String) -> Bool

    public convenience init() {
        self.init(
            pasteboard: .general,
            pasteShortcutKeyResolver: PasteShortcutKeyResolver(),
            eventPosting: CGClipboardEventPosting(),
            clipboardRestoreDelay: Self.defaultClipboardRestoreDelay,
            restoreCoordinator: Self.sharedRestoreCoordinator,
            pasteboardStringWriter: { pasteboard, text in
                pasteboard.setString(text, forType: .string)
            }
        )
    }

    convenience init(
        pasteboard: NSPasteboard = .general,
        pasteShortcutKeyResolver: PasteShortcutKeyResolver = PasteShortcutKeyResolver(),
        eventPosting: ClipboardEventPosting = CGClipboardEventPosting(),
        clipboardRestoreDelay: TimeInterval = ClipboardService.defaultClipboardRestoreDelay,
        restoreAttemptObserver: (@MainActor () -> Void)? = nil,
        pasteboardStringWriter: @escaping @MainActor (NSPasteboard, String) -> Bool = { pasteboard, text in
            pasteboard.setString(text, forType: .string)
        }
    ) {
        self.init(
            pasteboard: pasteboard,
            pasteShortcutKeyResolver: pasteShortcutKeyResolver,
            eventPosting: eventPosting,
            clipboardRestoreDelay: clipboardRestoreDelay,
            restoreCoordinator: ClipboardRestoreCoordinator(restoreAttemptObserver: restoreAttemptObserver),
            pasteboardStringWriter: pasteboardStringWriter
        )
    }

    private init(
        pasteboard: NSPasteboard,
        pasteShortcutKeyResolver: PasteShortcutKeyResolver,
        eventPosting: ClipboardEventPosting,
        clipboardRestoreDelay: TimeInterval,
        restoreCoordinator: ClipboardRestoreCoordinator,
        pasteboardStringWriter: @escaping @MainActor (NSPasteboard, String) -> Bool
    ) {
        self.pasteboard = pasteboard
        self.pasteShortcutKeyResolver = pasteShortcutKeyResolver
        self.eventPosting = eventPosting
        self.clipboardRestoreDelay = clipboardRestoreDelay
        self.restoreCoordinator = restoreCoordinator
        self.pasteboardStringWriter = pasteboardStringWriter
    }

    /// Paste text into the active app by:
    /// 1. Saving current clipboard
    /// 2. Setting transcript on clipboard
    /// 3. Simulating Cmd+V
    /// 4. Restoring original clipboard after a delay long enough for slow paste targets,
    ///    unless the caller explicitly wants the pasted text retained as a manual-paste fallback.
    public func pasteText(_ text: String) async throws {
        try await pasteText(text, restoresClipboard: true)
    }

    public func pasteText(_ text: String, restoresClipboard: Bool) async throws {
        let restoreDelay = clipboardRestoreDelay

        // 1. Save current clipboard contents
        let currentItems = Self.snapshotItems(from: pasteboard)
        let previousChangeCount = pasteboard.changeCount
        let savedItems = restoreCoordinator.originalItemsForNewPaste(
            currentItems: currentItems,
            currentChangeCount: previousChangeCount
        )

        // 2. Set transcript
        pasteboard.clearContents()
        guard pasteboardStringWriter(pasteboard, text) else {
            pasteboard.clearContents()
            Self.writeItems(currentItems, to: pasteboard)
            restoreCoordinator.temporaryClipboardWasRestoredAfterFailedWrite(
                previousChangeCount: previousChangeCount,
                restoredChangeCount: pasteboard.changeCount
            )
            throw ClipboardServiceError.pasteboardWriteFailed
        }
        let ourChangeCount = pasteboard.changeCount

        if restoresClipboard {
            restoreCoordinator.scheduleRestore(
                pasteboard: pasteboard,
                originalItems: savedItems,
                latestTemporaryChangeCount: ourChangeCount,
                delay: restoreDelay
            )
        } else {
            restoreCoordinator.cancelPendingRestore()
        }

        // 3. Simulate Cmd+V
        try eventPosting.simulatePaste(using: pasteShortcutKeyResolver)
    }

    /// Copy text to clipboard without paste simulation
    @discardableResult
    public func copyToClipboard(_ text: String) async -> Bool {
        let currentItems = Self.snapshotItems(from: pasteboard)
        let previousChangeCount = pasteboard.changeCount

        pasteboard.clearContents()
        guard pasteboardStringWriter(pasteboard, text) else {
            pasteboard.clearContents()
            Self.writeItems(currentItems, to: pasteboard)
            restoreCoordinator.temporaryClipboardWasRestoredAfterFailedWrite(
                previousChangeCount: previousChangeCount,
                restoredChangeCount: pasteboard.changeCount
            )
            logger.error("Failed to write text to clipboard during copy fallback")
            return false
        }

        restoreCoordinator.cancelPendingRestore()
        return true
    }

    @discardableResult
    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws -> Bool {
        try await pasteTextWithAction(text, postPasteAction: postPasteAction, restoresClipboard: true)
    }

    @discardableResult
    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?, restoresClipboard: Bool) async throws -> Bool {
        guard let action = postPasteAction else {
            try await pasteText(text, restoresClipboard: restoresClipboard)
            return false
        }

        // If text is empty (trigger was entire dictation), skip paste — just fire keystroke
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try eventPosting.simulateKeystroke(action.keyCode)
            return true
        }

        // Paste text (no trailing space — action replaces the role of the space)
        try await pasteText(text, restoresClipboard: restoresClipboard)

        // After paste succeeds, the keystroke phase is entirely non-fatal.
        // Task.sleep can throw CancellationError — catch it alongside keystroke errors
        // so cancellation during the 200ms delay doesn't surface as a paste failure.
        do {
            try await Task.sleep(for: .milliseconds(200))
            try eventPosting.simulateKeystroke(action.keyCode)
            return true
        } catch is CancellationError {
            logger.notice("Post-paste keystroke skipped (task cancelled after paste succeeded)")
            return false
        } catch {
            logger.error("Post-paste keystroke failed (text was pasted successfully): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Private

    private static func snapshotItems(from pasteboard: NSPasteboard) -> [NSPasteboardItem]? {
        pasteboard.pasteboardItems?.map { item in
            let restored = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    restored.setData(data, forType: type)
                }
            }
            return restored
        }
    }

    private static func writeItems(_ items: [NSPasteboardItem]?, to pasteboard: NSPasteboard) {
        if let items, !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }

}
