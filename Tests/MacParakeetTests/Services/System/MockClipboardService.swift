import Foundation
@testable import MacParakeetCore

public actor MockClipboardService: ClipboardServiceProtocol {
    public struct Snapshot: Sendable {
        public let lastPastedText: String?
        public let lastCopiedText: String?
        public let lastPostPasteAction: KeyAction?
        public let lastRestoresClipboard: Bool?
        public let pasteCallCount: Int
    }

    public var lastPastedText: String?
    public var lastCopiedText: String?
    public var lastPostPasteAction: KeyAction?
    public var lastRestoresClipboard: Bool?
    public var pasteCallCount = 0

    public init() {}

    public func snapshot() -> Snapshot {
        Snapshot(
            lastPastedText: lastPastedText,
            lastCopiedText: lastCopiedText,
            lastPostPasteAction: lastPostPasteAction,
            lastRestoresClipboard: lastRestoresClipboard,
            pasteCallCount: pasteCallCount
        )
    }

    public func pasteText(_ text: String) async throws {
        try await pasteText(text, restoresClipboard: true)
    }

    public func pasteText(_ text: String, restoresClipboard: Bool) async throws {
        lastPastedText = text
        lastRestoresClipboard = restoresClipboard
        pasteCallCount += 1
    }

    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws -> Bool {
        try await pasteTextWithAction(text, postPasteAction: postPasteAction, restoresClipboard: true)
    }

    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?, restoresClipboard: Bool) async throws -> Bool {
        lastPostPasteAction = postPasteAction
        try await pasteText(text, restoresClipboard: restoresClipboard)
        return postPasteAction != nil
    }

    public func copyToClipboard(_ text: String) async -> Bool {
        lastCopiedText = text
        return true
    }
}
