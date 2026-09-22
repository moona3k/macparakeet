import Foundation
import os

/// Enforces voice-data expiry even when the user stops recording or disables
/// speaker recognition. Retain this for the lifetime of the app environment.
public final class SpeakerVoiceprintRetention: Sendable {
    private let task: Task<Void, Never>

    public init(
        candidates: SpeakerEmbeddingCandidateRepositoryProtocol,
        journal: SpeakerMatchJournalRepositoryProtocol,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        // Capture dependencies, never self: releasing the owner must cancel
        // the sleeping task rather than leave an ownership cycle behind.
        task = Task.detached(priority: .utility) {
            let logger = Logger(
                subsystem: "com.macparakeet.core",
                category: "SpeakerVoiceprintRetention"
            )
            while !Task.isCancelled {
                let date = now()
                do {
                    try candidates.pruneExpired(now: date)
                } catch {
                    logger.warning(
                        "speaker_candidate_retention_failed error=\(error.localizedDescription, privacy: .private)"
                    )
                }
                // A failure in either store must not suppress the other's
                // cleanup or prevent another attempt on the next tick.
                do {
                    try journal.prune(
                        retention: SpeakerMatchJournalRepository.defaultRetention,
                        now: date
                    )
                } catch {
                    logger.warning(
                        "speaker_journal_retention_failed error=\(error.localizedDescription, privacy: .private)"
                    )
                }

                do {
                    try await sleep(.seconds(60 * 60))
                } catch {
                    return
                }
            }
        }
    }

    deinit {
        task.cancel()
    }
}
