import ArgumentParser
import Foundation
import MacParakeetCore

private func resolveDatabasePath(_ database: String?) -> String {
    let opt = database?.trimmingCharacters(in: .whitespacesAndNewlines)
    return (opt?.isEmpty == false) ? opt! : AppPaths.databasePath
}

private func ensureDatabaseDirectoryExists(path: String) {
    guard path != AppPaths.databasePath else { return }
    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "View dictation and transcription history.",
        subcommands: [
            DictationsSubcommand.self,
            TranscriptionsSubcommand.self,
            SearchSubcommand.self,
        ],
        defaultSubcommand: DictationsSubcommand.self
    )
}

struct DictationsSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dictations",
        abstract: "List recent dictations."
    )

    @Option(name: .shortAndLong, help: "Maximum number of results.")
    var limit: Int = 20

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbPath = resolveDatabasePath(database)
        ensureDatabaseDirectoryExists(path: dbPath)
        let dbManager = try DatabaseManager(path: dbPath)
        let repo = DictationRepository(dbQueue: dbManager.dbQueue)
        let dictations = try repo.fetchAll(limit: limit)

        if dictations.isEmpty {
            print("No dictations found.")
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        for d in dictations {
            let date = formatter.string(from: d.createdAt)
            let seconds = d.durationMs / 1000
            let preview = String((d.cleanTranscript ?? d.rawTranscript).prefix(80))
            let truncated = preview.count >= 80 ? preview + "..." : preview
            print("[\(date)] (\(seconds)s) \(truncated)")
        }

        let stats = try repo.stats()
        print()
        print("Total: \(stats.totalCount) dictations")
    }
}

struct TranscriptionsSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcriptions",
        abstract: "List recent transcriptions."
    )

    @Option(name: .shortAndLong, help: "Maximum number of results.")
    var limit: Int = 20

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbPath = resolveDatabasePath(database)
        ensureDatabaseDirectoryExists(path: dbPath)
        let dbManager = try DatabaseManager(path: dbPath)
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        let transcriptions = try repo.fetchAll(limit: limit)

        if transcriptions.isEmpty {
            print("No transcriptions found.")
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        for t in transcriptions {
            let date = formatter.string(from: t.createdAt)
            let status = "\(t.status)"
            let duration: String
            if let ms = t.durationMs {
                let s = ms / 1000
                duration = "\(s / 60)m \(s % 60)s"
            } else {
                duration = "—"
            }
            print("[\(date)] \(t.fileName) (\(duration)) [\(status)]")
        }
    }
}

struct SearchSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Search dictation history."
    )

    @Argument(help: "Search query.")
    var query: String

    @Option(name: .shortAndLong, help: "Maximum number of results.")
    var limit: Int = 20

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbPath = resolveDatabasePath(database)
        ensureDatabaseDirectoryExists(path: dbPath)
        let dbManager = try DatabaseManager(path: dbPath)
        let repo = DictationRepository(dbQueue: dbManager.dbQueue)
        let results = try repo.search(query: query, limit: limit)

        if results.isEmpty {
            print("No results for \"\(query)\".")
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        for d in results {
            let date = formatter.string(from: d.createdAt)
            let preview = String((d.cleanTranscript ?? d.rawTranscript).prefix(80))
            let truncated = preview.count >= 80 ? preview + "..." : preview
            print("[\(date)] \(truncated)")
        }

        print()
        print("\(results.count) result(s)")
    }
}
