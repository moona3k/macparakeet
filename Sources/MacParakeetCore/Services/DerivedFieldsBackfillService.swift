import Foundation
import GRDB
import OSLog

/// Backfills `derivedTitle` / `derivedSnippet` on existing transcription rows
/// after the v0.9 migration adds the columns. Runs once per app launch on a
/// low-priority background task; each batch is one short write transaction so
/// it doesn't interfere with foreground reads.
///
/// Idempotent: rows that already have a non-nil `derivedTitle` are skipped.
/// Rows where the deriver legitimately returns nil (empty / whitespace-only
/// transcripts) get an empty-string sentinel so they exit the eligible-set —
/// without the sentinel the predicate would re-select them forever.
public final class DerivedFieldsBackfillService: @unchecked Sendable {
    private let dbQueue: DatabaseQueue
    private let batchSize: Int
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "DerivedFieldsBackfill")

    public init(dbQueue: DatabaseQueue, batchSize: Int = 50) {
        self.dbQueue = dbQueue
        self.batchSize = batchSize
    }

    /// Run the backfill in the background. Returns immediately; work proceeds
    /// on a detached utility-priority task. Safe to call multiple times — only
    /// the first run does meaningful work; subsequent runs hit the
    /// completed-skip predicate and exit fast.
    public func runInBackground() {
        Task.detached(priority: .utility) { [self] in
            do {
                let processed = try runOnce()
                if processed > 0 {
                    logger.info("derived_fields_backfilled rows=\(processed, privacy: .public)")
                }
            } catch is CancellationError {
                // expected on app shutdown
            } catch {
                logger.error("derived_fields_backfill_failed error=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Process every eligible row, batched. Returns the actual number of rows
    /// updated. Synchronous so it composes naturally with `Task.detached` and
    /// is straightforward to call from tests.
    @discardableResult
    public func runOnce() throws -> Int {
        var totalProcessed = 0
        while !Task.isCancelled {
            let processed = try processBatch()
            if processed == 0 { break }
            totalProcessed += processed
        }
        return totalProcessed
    }

    private func processBatch() throws -> Int {
        try dbQueue.write { db in
            let rows = try Transcription
                .filter(Transcription.Columns.derivedTitle == nil)
                .filter(Transcription.Columns.status == Transcription.TranscriptionStatus.completed.rawValue)
                .limit(batchSize)
                .fetchAll(db)
            guard !rows.isEmpty else { return 0 }

            for var row in rows {
                let source = row.cleanTranscript ?? row.rawTranscript
                row.derivedTitle = TitleDeriver.derive(from: source) ?? ""
                row.derivedSnippet = SnippetDeriver.derive(from: source, excluding: row.derivedTitle) ?? ""
                try row.update(db)
            }
            return rows.count
        }
    }
}
