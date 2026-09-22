import Foundation

/// Process-local ownership of foreground-app interaction, including asynchronous
/// clipboard restoration. A rejected acquisition never cancels the current owner.
@MainActor
public final class GUIMutationArbiter {
    public static let shared = GUIMutationArbiter()
    public enum Owner: Sendable, Equatable { case dictation, transform, voiceControl, historyPaste }
    public struct Lease: Sendable, Equatable {
        fileprivate let id: UUID
        public let owner: Owner
    }
    public private(set) var current: Lease?
    public init() {}
    public func acquire(_ owner: Owner) -> Lease? {
        guard current == nil else { return nil }
        let lease = Lease(id: UUID(), owner: owner)
        current = lease
        return lease
    }
    public func release(_ lease: Lease) {
        guard current == lease else { return }
        current = nil
    }
}
