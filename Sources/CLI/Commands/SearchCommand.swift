import ArgumentParser
import Foundation
import MacParakeetCore

extension SegmentSearchSource: ExpressibleByArgument {}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search meeting and file/URL transcript segments.",
        discussion: """
            Queries use SQLite FTS5 syntax, including quoted phrases, prefix terms
            (term*), and AND/OR. Queries containing Han, Kana, or Thai characters
            automatically use an exact substring fallback.
            """
    )

    @Argument(help: "FTS5 query (phrase, prefix, and AND/OR syntax are supported).")
    var query: String

    @Option(help: "Only recordings at or after this ISO-8601 date/time.")
    var since: String?

    @Option(help: "Only recordings at or before this ISO-8601 date/time.")
    var until: String?

    @Option(help: "Filter source: meeting, file, or url.")
    var source: SegmentSearchSource?

    @Option(help: "Filter by speaker label substring.")
    var speaker: String?

    @Option(name: .shortAndLong, help: "Maximum number of segment hits.")
    var limit: Int = 20

    @Flag(name: .long, help: "Emit the segment-hit array as JSON.")
    var json = false

    @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
    var envelope = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func validate() throws {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("Pass a non-empty search query.")
        }
        guard limit >= 0 else { throw ValidationError("--limit must be >= 0.") }
        try validateJSONEnvelopeFlags(json: json, envelope: envelope)
        _ = try since.map { try parseSearchDate($0, option: "--since") }
        _ = try until.map { try parseSearchDate($0, option: "--until") }
    }

    func run() async throws {
        try emitJSONOrRethrow(json: json || envelope) {
            let db = try makeDatabaseManager(database: database)
            let repository = SegmentRepository(dbQueue: db.dbQueue)
            let hits = try repository.search(
                SegmentSearchQuery(
                    query: query,
                    since: try since.map { try parseSearchDate($0, option: "--since") },
                    until: try until.map { try parseSearchDate($0, option: "--until") },
                    source: source,
                    speaker: speaker,
                    limit: limit
                ))

            if envelope {
                try printEnvelope(command: "search", data: hits)
            } else if json {
                try printJSON(hits)
            } else if hits.isEmpty {
                print("No transcript segments matched.")
            } else {
                for hit in hits {
                    let location = hit.startMs.map(formatSearchTimestamp) ?? "#\(hit.seq)"
                    let speaker = hit.speaker.map { " [\($0)]" } ?? ""
                    print("[\(formatSearchDate(hit.recordedAt))] \(hit.title) \(location)\(speaker)\n  \(hit.snippet)")
                }
            }
        }
    }

}

struct SearchReindexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-reindex",
        abstract: "Deterministically rebuild transcript segments and their FTS index."
    )

    @Flag(name: .long, help: "Emit the rebuild result as JSON.")
    var json = false

    @Flag(name: .long, help: "Wrap JSON output in an ok/data/meta envelope.")
    var envelope = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func validate() throws {
        try validateJSONEnvelopeFlags(json: json, envelope: envelope)
    }

    func run() async throws {
        try emitJSONOrRethrow(json: json || envelope) {
            let db = try makeDatabaseManager(database: database)
            let result = try SegmentRepository(dbQueue: db.dbQueue).rebuildAll()
            if envelope {
                try printEnvelope(command: "search-reindex", data: result)
            } else if json {
                try printJSON(result)
            } else {
                print(
                    "Indexed \(result.segmentsIndexed) segments from \(result.transcriptionsIndexed) transcriptions."
                )
            }
        }
    }
}

private func parseSearchDate(_ value: String, option: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    let dayFormatter = DateFormatter()
    dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    dayFormatter.calendar = Calendar(identifier: .gregorian)
    dayFormatter.timeZone = TimeZone(secondsFromGMT: 0)
    dayFormatter.dateFormat = "yyyy-MM-dd"
    if let date = dayFormatter.date(from: value) { return date }
    throw ValidationError("\(option) must be ISO-8601 (for example 2026-07-10 or 2026-07-10T18:30:00Z).")
}

private func formatSearchDate(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

func formatSearchTimestamp(_ milliseconds: Int) -> String {
    let totalSeconds = max(0, milliseconds) / 1_000
    return String(format: "%02d:%02d:%02d", totalSeconds / 3_600, (totalSeconds % 3_600) / 60, totalSeconds % 60)
}
