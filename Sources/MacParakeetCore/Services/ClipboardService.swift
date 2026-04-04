import AppKit
import Carbon
import Foundation
import OSLog

public protocol ClipboardServiceProtocol: Sendable {
    func pasteText(_ text: String) async throws
    /// Paste text then simulate a keystroke. Returns `true` if the keystroke was actually fired.
    func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws -> Bool
    func copyToClipboard(_ text: String) async
}

public enum ClipboardServiceError: LocalizedError {
    case accessibilityPermissionRequired
    case eventSourceUnavailable
    case eventCreationFailed

    public var errorDescription: String? {
        switch self {
        case .accessibilityPermissionRequired:
            return "Accessibility permission is required for auto-paste."
        case .eventSourceUnavailable:
            return "Paste automation unavailable (event source creation failed)."
        case .eventCreationFailed:
            return "Paste automation unavailable (could not create keyboard events)."
        }
    }
}

/// Handles clipboard save/restore and paste simulation via Cmd+V.
@MainActor
public final class ClipboardService: ClipboardServiceProtocol {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "ClipboardService")

    public init() {}

    /// Paste text into the active app by:
    /// 1. Saving current clipboard
    /// 2. Setting transcript on clipboard
    /// 3. Simulating Cmd+V
    /// 4. Restoring original clipboard after 150ms delay
    public func pasteText(_ text: String) async throws {
        let pasteboard = NSPasteboard.general

        // 1. Save current clipboard contents
        let savedItems: [NSPasteboardItem]? = pasteboard.pasteboardItems?.map { item in
            let restored = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    restored.setData(data, forType: type)
                }
            }
            return restored
        }

        // 2. Set transcript
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        // Always attempt to restore the previous clipboard contents after a short delay.
        // If caller intentionally rewrites clipboard on error, changeCount guard prevents clobbering.
        defer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // If the user changed the clipboard after we wrote, do not clobber it.
                guard pasteboard.changeCount == ourChangeCount else {
                    return
                }

                pasteboard.clearContents()
                if let savedItems, !savedItems.isEmpty {
                    pasteboard.writeObjects(savedItems)
                }
            }
        }

        // 3. Simulate Cmd+V
        try simulatePaste()
    }

    /// Copy text to clipboard without paste simulation
    public func copyToClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws -> Bool {
        guard let action = postPasteAction else {
            try await pasteText(text)
            return false
        }

        // If text is empty (trigger was entire dictation), skip paste — just fire keystroke
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try simulateKeystroke(action.keyCode)
            return true
        }

        // Paste text (no trailing space — action replaces the role of the space)
        try await pasteText(text)

        // After paste succeeds, the keystroke phase is entirely non-fatal.
        // Task.sleep can throw CancellationError — catch it alongside keystroke errors
        // so cancellation during the 200ms delay doesn't surface as a paste failure.
        do {
            try await Task.sleep(for: .milliseconds(200))
            try simulateKeystroke(action.keyCode)
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

    private func simulateKeystroke(_ keyCode: UInt16) throws {
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

        // Explicitly clear modifier flags — .hidSystemState source may inherit
        // stray modifiers if the user happens to hold a key during dictation.
        keyDown.flags = []
        keyUp.flags = []

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func simulatePaste() throws {
        guard AXIsProcessTrusted() else {
            throw ClipboardServiceError.accessibilityPermissionRequired
        }

        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ClipboardServiceError.eventSourceUnavailable
        }

        // Resolve the shortcut under the same Command-modified layout state that
        // the generated CGEvents will carry. This preserves layouts such as
        // "Dvorak - QWERTY ⌘" that intentionally remap only while Command is held.
        let vKeyCode = virtualKeyCode(for: "v", modifierKeyState: UInt32(cmdKey >> 8))

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false) else {
            throw ClipboardServiceError.eventCreationFailed
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
    }

    private func virtualKeyCode(for character: Character, modifierKeyState: UInt32 = 0) -> CGKeyCode {
        let fallbackKeyCode: CGKeyCode = 0x09
        guard let layoutSourceRef = TISCopyCurrentKeyboardLayoutInputSource() else {
            logger.error("Failed to get current keyboard input source; falling back to QWERTY keycode 0x09")
            return fallbackKeyCode
        }
        let layoutSource = layoutSourceRef.takeRetainedValue()

        guard let layoutDataRef = TISGetInputSourceProperty(layoutSource, kTISPropertyUnicodeKeyLayoutData) else {
            logger.error("Failed to resolve keyboard layout data for paste shortcut; falling back to QWERTY keycode 0x09")
            return fallbackKeyCode
        }

        let layoutData = Unmanaged<CFData>.fromOpaque(layoutDataRef).takeUnretainedValue()
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else {
            logger.error("Failed to access keyboard layout bytes for paste shortcut; falling back to QWERTY keycode 0x09")
            return fallbackKeyCode
        }
        let keyboardLayout = UnsafeRawPointer(layoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        let target = String(character).utf16.first!

        for keyCode: UInt16 in 0..<128 {
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)

            let status = UCKeyTranslate(
                keyboardLayout,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                chars.count,
                &length,
                &chars
            )

            if status == noErr && length > 0 && chars[0] == target {
                return CGKeyCode(keyCode)
            }
        }

        logger.error("Failed to resolve virtual keycode for character '\(String(character), privacy: .public)'; falling back to QWERTY keycode 0x09")
        return fallbackKeyCode
    }
}
