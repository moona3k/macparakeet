import AppKit
import Foundation

public protocol FrontmostApplicationProviding: Sendable {
    @MainActor
    func currentFrontmostApplication() -> MeetingStartContext.FrontmostApplication?
}

public struct NSWorkspaceFrontmostApplicationProvider: FrontmostApplicationProviding {
    public init() {}

    @MainActor
    public func currentFrontmostApplication() -> MeetingStartContext.FrontmostApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return MeetingStartContext.FrontmostApplication(
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName
        )
    }
}
