import Foundation
@testable import MacParakeetCore

public actor MockClipboardService: ClipboardServiceProtocol {
    public var lastPastedText: String?
    public var lastCopiedText: String?
    public var lastPostPasteAction: KeyAction?
    public var lastPasteTarget: ClipboardPasteTarget?
    public var pasteCallCount = 0

    public init() {}

    public func pasteText(_ text: String) async throws {
        try await pasteText(text, target: nil)
    }

    public func pasteText(_ text: String, target: ClipboardPasteTarget?) async throws {
        lastPastedText = text
        lastPasteTarget = target
        pasteCallCount += 1
    }

    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws -> Bool {
        try await pasteTextWithAction(text, postPasteAction: postPasteAction, target: nil)
    }

    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?, target: ClipboardPasteTarget?) async throws -> Bool {
        lastPostPasteAction = postPasteAction
        try await pasteText(text, target: target)
        return postPasteAction != nil
    }

    public func copyToClipboard(_ text: String) async -> Bool {
        lastCopiedText = text
        return true
    }
}
