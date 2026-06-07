import AppKit
import Foundation

public protocol FocusedAppContextProviding: Sendable {
    @MainActor
    func currentContext() -> AppPromptContext?
}

public struct FocusedAppContextService: FocusedAppContextProviding {
    public init() {}

    @MainActor
    public func currentContext() -> AppPromptContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return AppPromptContext(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.localizedName
        )
    }
}
