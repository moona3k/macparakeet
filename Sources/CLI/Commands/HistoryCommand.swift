import ArgumentParser
import Foundation
import MacParakeetCore

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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
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
            let text = d.cleanTranscript ?? d.rawTranscript
            let preview = text.count > 80 ? String(text.prefix(80)) + "..." : text
            print("[\(date)] (\(seconds)s) \(preview)  (\(d.id.uuidString.prefix(8)))")
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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
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
            let text = d.cleanTranscript ?? d.rawTranscript
            let preview = text.count > 80 ? String(text.prefix(80)) + "..." : text
            print("[\(date)] \(preview)")
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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        let results = try repo.search(query: query, limit: limit)

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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        let repo = DictationRepository(dbQueue: dbManager.dbQueue)

        let dictation = try findDictation(id: id, repo: repo)
        _ = try repo.delete(id: dictation.id)
        let preview = String(dictation.rawTranscript.prefix(60))
        print("Deleted dictation: \"\(preview)\"")
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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        let transcription = try findTranscription(id: id, repo: repo)
        _ = try repo.delete(id: transcription.id)
        print("Deleted transcription: \"\(transcription.fileName)\"")
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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        let transcription = try findTranscription(id: id, repo: repo)
        try repo.updateFavorite(id: transcription.id, isFavorite: true)
        print("Favorited: \"\(transcription.fileName)\"")
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
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        let transcription = try findTranscription(id: id, repo: repo)
        try repo.updateFavorite(id: transcription.id, isFavorite: false)
        print("Unfavorited: \"\(transcription.fileName)\"")
    }
}
