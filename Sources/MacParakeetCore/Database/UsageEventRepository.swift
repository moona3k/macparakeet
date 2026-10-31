import Foundation
import GRDB

public protocol UsageEventRepositoryProtocol: Sendable {
    func save(_ event: UsageEvent) throws
    /// Totals per kind, provider, model, and locality for events on or after `since`
    /// (all time when `nil`), busiest first.
    func summary(since: Date?) throws -> [UsageSummaryRow]
    /// Local speech-engine totals from saved transcriptions and dictations.
    func speechEngineUsage(since: Date?) throws -> [SpeechEngineUsageRow]
    func deleteAll() throws
}

public final class UsageEventRepository: UsageEventRepositoryProtocol {
    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func save(_ event: UsageEvent) throws {
        try dbQueue.write { db in
            try event.save(db)
        }
    }

    public func summary(since: Date?) throws -> [UsageSummaryRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT kind, provider, model, isLocal,
                           COUNT(*) AS requests,
                           SUM(promptTokens) AS promptTokens,
                           SUM(completionTokens) AS completionTokens,
                           MAX(tokensEstimated) AS tokensEstimated,
                           SUM(audioMs) AS audioMs
                    FROM usage_events
                    WHERE (? IS NULL OR createdAt >= ?)
                    GROUP BY kind, provider, model, isLocal
                    ORDER BY requests DESC, provider, model, isLocal
                    """,
                arguments: [since, since]
            )
            return rows.compactMap { row in
                guard let kind = UsageEvent.Kind(rawValue: row["kind"]) else { return nil }
                return UsageSummaryRow(
                    kind: kind,
                    provider: row["provider"],
                    model: row["model"],
                    isLocal: row["isLocal"],
                    requests: row["requests"],
                    promptTokens: row["promptTokens"],
                    completionTokens: row["completionTokens"],
                    tokensEstimated: row["tokensEstimated"],
                    audioMs: row["audioMs"]
                )
            }
        }
    }

    public func speechEngineUsage(since: Date?) throws -> [SpeechEngineUsageRow] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT engine, variant, SUM(items) AS items, SUM(audioMs) AS audioMs FROM (
                        SELECT COALESCE(engine, 'unknown') AS engine, engineVariant AS variant,
                               COUNT(*) AS items, COALESCE(SUM(durationMs), 0) AS audioMs
                        FROM transcriptions
                        WHERE status = 'completed' AND (? IS NULL OR createdAt >= ?)
                        GROUP BY 1, 2
                        UNION ALL
                        SELECT COALESCE(engine, 'unknown') AS engine, engineVariant AS variant,
                               COUNT(*) AS items, COALESCE(SUM(durationMs), 0) AS audioMs
                        FROM dictations
                        WHERE status = 'completed' AND (? IS NULL OR createdAt >= ?)
                        GROUP BY 1, 2
                    )
                    GROUP BY engine, variant
                    ORDER BY audioMs DESC
                    """,
                arguments: [since, since, since, since]
            )
            return rows.map { row in
                SpeechEngineUsageRow(
                    engine: row["engine"], variant: row["variant"], items: row["items"], audioMs: row["audioMs"])
            }
        }
    }

    public func deleteAll() throws {
        _ = try dbQueue.write { db in
            try UsageEvent.deleteAll(db)
        }
    }
}
