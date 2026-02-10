import Foundation
@testable import MacParakeetCore

public actor MockClipboardService: ClipboardServiceProtocol {
    public var lastPastedText: String?
    public var lastCopiedText: String?
    public var pasteCallCount = 0

    public init() {}

    public func pasteText(_ text: String) async throws {
        lastPastedText = text
        pasteCallCount += 1
    }

    public func copyToClipboard(_ text: String) async {
        lastCopiedText = text
    }
}
