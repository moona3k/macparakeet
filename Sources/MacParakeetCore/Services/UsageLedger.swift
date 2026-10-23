import Foundation
import OSLog

/// Process-wide sink for usage events. Engines and the AI client record
/// through it without knowing about the database; the app points it at the
/// repository at launch. Until then (and in the CLI) recording is a no-op.
public final class UsageLedger: @unchecked Sendable {
    public static let shared = UsageLedger()

    private let lock = NSLock()
    private var repository: UsageEventRepositoryProtocol?
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "UsageLedger")

    public init(repository: UsageEventRepositoryProtocol? = nil) {
        self.repository = repository
    }

    public func configure(repository: UsageEventRepositoryProtocol?) {
        lock.withLock { self.repository = repository }
    }

    /// Never throws: a failed usage write must not fail the user's request.
    public func record(_ event: UsageEvent) {
        guard let repository = lock.withLock({ self.repository }) else { return }
        do {
            try repository.save(event)
        } catch {
            logger.error("usage_record_failed error=\(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// The configured repository, for reading totals. `nil` before launch
    /// wiring and in the CLI.
    public var reader: UsageEventRepositoryProtocol? {
        lock.withLock { repository }
    }

    /// Rough token count for providers that report none (~4 characters per
    /// token). Marked as estimated wherever it is shown.
    public static func estimatedTokens(forCharacters count: Int) -> Int {
        max(0, (count + 3) / 4)
    }
}
