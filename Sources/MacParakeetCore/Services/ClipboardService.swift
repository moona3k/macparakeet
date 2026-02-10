import AppKit
import Foundation

public protocol ClipboardServiceProtocol: Sendable {
    func pasteText(_ text: String) async throws
    func copyToClipboard(_ text: String) async
}

/// Handles clipboard save/restore and paste simulation via Cmd+V.
@MainActor
public final class ClipboardService: ClipboardServiceProtocol {
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

        // 3. Simulate Cmd+V
        simulatePaste()

        // 4. Restore clipboard after delay
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

    /// Copy text to clipboard without paste simulation
    public func copyToClipboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Private

    private func simulatePaste() {
        // Cmd+V: virtual key 0x09 = 'v'
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
