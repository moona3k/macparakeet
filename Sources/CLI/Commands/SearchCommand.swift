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

    @Option(help: "Only recordings at or after this ISO-8601 timestamp or local date (start of day).")
    var since: String?

    @Option(help: "Only recordings at or before this ISO-8601 timestamp or local date (end of day).")
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
        _ = try since.map { try parseSearchDate($0, boundary: .since) }
        _ = try until.map { try parseSearchDate($0, boundary: .until) }
    }

    func run() async throws {
        try emitJSONOrRethrow(json: json || envelope) {
            let db = try makeDatabaseManager(database: database)
            let repository = SegmentRepository(dbQueue: db.dbQueue)
            let hits = try repository.search(
                SegmentSearchQuery(
                    query: query,
                    since: try since.map { try parseSearchDate($0, boundary: .since) },
                    until: try until.map { try parseSearchDate($0, boundary: .until) },
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

enum SearchDateBoundary {
    case since
    case until

    fileprivate var option: String {
        switch self {
        case .since: "--since"
        case .until: "--until"
        }
    }
}

func parseSearchDate(
    _ value: String,
    boundary: SearchDateBoundary,
    timeZone: TimeZone = .current
) throws -> Date {
    if let day = localSearchDay(value, timeZone: timeZone) {
        switch boundary {
        case .since:
            return day.start
        case .until:
            return Date(
                timeIntervalSinceReferenceDate: day.end.timeIntervalSinceReferenceDate.nextDown
            )
        }
    }

    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: value) { return date }
    throw ValidationError(
        "\(boundary.option) must be ISO-8601 (for example 2026-07-10 or 2026-07-10T18:30:00Z)."
    )
}

private func localSearchDay(_ value: String, timeZone: TimeZone) -> DateInterval? {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
        parts[0].count == 4,
        parts[1].count == 2,
        parts[2].count == 2,
        let year = Int(parts[0]),
        let month = Int(parts[1]),
        let day = Int(parts[2])
    else {
        return nil
    }

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(
        calendar: calendar,
        timeZone: timeZone,
        year: year,
        month: month,
        day: day
    )
    guard let date = calendar.date(from: components) else { return nil }
    let resolved = calendar.dateComponents([.year, .month, .day], from: date)
    guard resolved.year == year, resolved.month == month, resolved.day == day else { return nil }
    return calendar.dateInterval(of: .day, for: date)
}

private func formatSearchDate(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

func formatSearchTimestamp(_ milliseconds: Int) -> String {
    let totalSeconds = max(0, milliseconds) / 1_000
    return String(format: "%02d:%02d:%02d", totalSeconds / 3_600, (totalSeconds % 3_600) / 60, totalSeconds % 60)
}
