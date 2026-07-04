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

        let frontmost = MeetingStartContext.FrontmostApplication(
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName
        )
        guard frontmost.bundleIdentifier != nil || frontmost.localizedName != nil else {
            return nil
        }
        return frontmost
    }
}
