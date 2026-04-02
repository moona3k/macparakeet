import Foundation
@testable import MacParakeetCore

public actor MockClipboardService: ClipboardServiceProtocol {
    public var lastPastedText: String?
    public var lastCopiedText: String?
    public var lastPostPasteAction: KeyAction?
    public var pasteCallCount = 0

    public init() {}

    public func pasteText(_ text: String) async throws {
        lastPastedText = text
        pasteCallCount += 1
    }

    public func pasteTextWithAction(_ text: String, postPasteAction: KeyAction?) async throws {
        lastPostPasteAction = postPasteAction
        try await pasteText(text)
    }

    public func copyToClipboard(_ text: String) async {
        lastCopiedText = text
    }
}
