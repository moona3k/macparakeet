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
        abstract: "View and manage dictation and transcription history.",
        subcommands: [
            DictationsSubcommand.self,
            TranscriptionsSubcommand.self,
            SearchSubcommand.self,
            SearchTranscriptionsSubcommand.self,
            DeleteDictationSubcommand.self,
            DeleteTranscriptionSubcommand.self,
            FavoritesSubcommand.self,
            FavoriteSubcommand.self,
            UnfavoriteSubcommand.self,
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
            print("[\(date)] (\(seconds)s) \(truncated)  (\(d.id.uuidString.prefix(8)))")
        }

        let stats = try repo.stats()
        print()
        print("Total: \(stats.visibleCount) dictations")
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
            print("[\(date)] \(t.fileName) (\(duration)) [\(status)]  (\(t.id.uuidString.prefix(8)))")
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

struct SearchTranscriptionsSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search-transcriptions",
        abstract: "Search transcriptions by keyword."
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
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        let all = try repo.fetchAll()

        let queryLower = query.lowercased()
        let results = all.filter { t in
            t.fileName.lowercased().contains(queryLower)
                || (t.rawTranscript?.lowercased().contains(queryLower) ?? false)
                || (t.cleanTranscript?.lowercased().contains(queryLower) ?? false)
        }.prefix(limit)

        if results.isEmpty {
            print("No transcriptions matching \"\(query)\".")
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        for t in results {
            let date = formatter.string(from: t.createdAt)
            let fav = t.isFavorite ? " *" : ""
            let duration: String
            if let ms = t.durationMs {
                let s = ms / 1000
                duration = "\(s / 60)m \(s % 60)s"
            } else {
                duration = "—"
            }
            print("[\(date)] \(t.fileName) (\(duration)) [\(t.status)]\(fav)  (\(t.id.uuidString.prefix(8)))")
        }

        print()
        print("\(results.count) result(s)")
    }
}

struct DeleteDictationSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-dictation",
        abstract: "Delete a dictation by ID."
    )

    @Argument(help: "The UUID (or prefix) of the dictation to delete.")
    var id: String

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbPath = resolveDatabasePath(database)
        ensureDatabaseDirectoryExists(path: dbPath)
        let dbManager = try DatabaseManager(path: dbPath)
        let repo = DictationRepository(dbQueue: dbManager.dbQueue)

        let dictation = try findDictation(id: id, repo: repo)
        let deleted = try repo.delete(id: dictation.id)

        if deleted {
            let preview = String(dictation.rawTranscript.prefix(60))
            print("Deleted dictation: \"\(preview)\"")
        } else {
            print("Dictation not found.")
        }
    }

    private func findDictation(id: String, repo: DictationRepository) throws -> Dictation {
        if let uuid = UUID(uuidString: id), let d = try repo.fetch(id: uuid) {
            return d
        }
        let all = try repo.fetchAll()
        let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
        guard let match = matches.first else {
            throw HistoryError.notFound("No dictation matching '\(id)'")
        }
        guard matches.count == 1 else {
            throw HistoryError.ambiguous("Multiple dictations match '\(id)'. Be more specific.")
        }
        return match
    }
}

struct DeleteTranscriptionSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-transcription",
        abstract: "Delete a transcription by ID."
    )

    @Argument(help: "The UUID (or prefix) of the transcription to delete.")
    var id: String

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbPath = resolveDatabasePath(database)
        ensureDatabaseDirectoryExists(path: dbPath)
        let dbManager = try DatabaseManager(path: dbPath)
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        let transcription = try findTranscription(id: id, repo: repo)
        let deleted = try repo.delete(id: transcription.id)

        if deleted {
            print("Deleted transcription: \"\(transcription.fileName)\"")
        } else {
            print("Transcription not found.")
        }
    }

    private func findTranscription(id: String, repo: TranscriptionRepository) throws -> Transcription {
        if let uuid = UUID(uuidString: id), let t = try repo.fetch(id: uuid) {
            return t
        }
        let all = try repo.fetchAll()
        let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
        guard let match = matches.first else {
            throw HistoryError.notFound("No transcription matching '\(id)'")
        }
        guard matches.count == 1 else {
            throw HistoryError.ambiguous("Multiple transcriptions match '\(id)'. Be more specific.")
        }
        return match
    }
}

struct FavoritesSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "favorites",
        abstract: "List favorite transcriptions."
    )

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbPath = resolveDatabasePath(database)
        ensureDatabaseDirectoryExists(path: dbPath)
        let dbManager = try DatabaseManager(path: dbPath)
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        let favorites = try repo.fetchFavorites()

        if favorites.isEmpty {
            print("No favorite transcriptions.")
            return
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short

        for t in favorites {
            let date = formatter.string(from: t.createdAt)
            let duration: String
            if let ms = t.durationMs {
                let s = ms / 1000
                duration = "\(s / 60)m \(s % 60)s"
            } else {
                duration = "—"
            }
            print("* [\(date)] \(t.fileName) (\(duration)) [\(t.status)]  (\(t.id.uuidString.prefix(8)))")
        }

        print()
        print("\(favorites.count) favorite(s)")
    }
}

struct FavoriteSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "favorite",
        abstract: "Mark a transcription as favorite."
    )

    @Argument(help: "The UUID (or prefix) of the transcription.")
    var id: String

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbPath = resolveDatabasePath(database)
        ensureDatabaseDirectoryExists(path: dbPath)
        let dbManager = try DatabaseManager(path: dbPath)
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        let transcription = try findTranscription(id: id, repo: repo)
        try repo.updateFavorite(id: transcription.id, isFavorite: true)
        print("Favorited: \"\(transcription.fileName)\"")
    }

    private func findTranscription(id: String, repo: TranscriptionRepository) throws -> Transcription {
        if let uuid = UUID(uuidString: id), let t = try repo.fetch(id: uuid) {
            return t
        }
        let all = try repo.fetchAll()
        let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
        guard let match = matches.first else {
            throw HistoryError.notFound("No transcription matching '\(id)'")
        }
        guard matches.count == 1 else {
            throw HistoryError.ambiguous("Multiple transcriptions match '\(id)'. Be more specific.")
        }
        return match
    }
}

struct UnfavoriteSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unfavorite",
        abstract: "Remove a transcription from favorites."
    )

    @Argument(help: "The UUID (or prefix) of the transcription.")
    var id: String

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbPath = resolveDatabasePath(database)
        ensureDatabaseDirectoryExists(path: dbPath)
        let dbManager = try DatabaseManager(path: dbPath)
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        let transcription = try findTranscription(id: id, repo: repo)
        try repo.updateFavorite(id: transcription.id, isFavorite: false)
        print("Unfavorited: \"\(transcription.fileName)\"")
    }

    private func findTranscription(id: String, repo: TranscriptionRepository) throws -> Transcription {
        if let uuid = UUID(uuidString: id), let t = try repo.fetch(id: uuid) {
            return t
        }
        let all = try repo.fetchAll()
        let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }
        guard let match = matches.first else {
            throw HistoryError.notFound("No transcription matching '\(id)'")
        }
        guard matches.count == 1 else {
            throw HistoryError.ambiguous("Multiple transcriptions match '\(id)'. Be more specific.")
        }
        return match
    }
}

enum HistoryError: Error, LocalizedError {
    case notFound(String)
    case ambiguous(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let msg): return msg
        case .ambiguous(let msg): return msg
        }
    }
}
