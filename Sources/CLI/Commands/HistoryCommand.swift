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
            DeleteMeetingAudioSubcommand.self,
            ClearMeetingAudioSubcommand.self,
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

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try emitJSONOrRethrow(json: json) {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = DictationRepository(dbQueue: dbManager.dbQueue)
            let dictations = try repo.fetchAll(limit: limit)

            if json {
                try printJSON(dictations)
                return
            }

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
                // displayText honors the per-row "Undo AI edit" override so
                // the CLI matches what the GUI shows for the same row.
                let text = d.displayText
                let preview = text.count > 80 ? String(text.prefix(80)) + "..." : text
                print("[\(date)] (\(seconds)s) \(preview)  (\(d.id.uuidString.prefix(8)))")
            }

            let stats = try repo.stats()
            print()
            print("Total: \(stats.visibleCount) dictations")
        }
    }
}

struct TranscriptionsSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcriptions",
        abstract: "List recent transcriptions."
    )

    @Option(name: .shortAndLong, help: "Maximum number of results.")
    var limit: Int = 20

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try emitJSONOrRethrow(json: json) {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
            let transcriptions = try repo.fetchLibraryPage(query: TranscriptionLibraryQuery(
                limit: limit,
                includeProcessing: true
            )).items

            if json {
                try printJSON(transcriptions)
                return
            }

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

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try emitJSONOrRethrow(json: json) {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = DictationRepository(dbQueue: dbManager.dbQueue)
            let results = try repo.search(query: query, limit: limit)

            if json {
                try printJSON(results)
                return
            }

            if results.isEmpty {
                print("No results for \"\(query)\".")
                return
            }

            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short

            for d in results {
                let date = formatter.string(from: d.createdAt)
                let text = d.displayText
                let preview = text.count > 80 ? String(text.prefix(80)) + "..." : text
                print("[\(date)] \(preview)")
            }

            print()
            print("\(results.count) result(s)")
        }
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

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try emitJSONOrRethrow(json: json) {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let results = trimmedQuery.isEmpty
                ? []
                : try repo.fetchLibraryPage(query: TranscriptionLibraryQuery(
                    searchText: trimmedQuery,
                    limit: limit,
                    includeProcessing: true
                )).items

            if json {
                try printJSON(results)
                return
            }

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
        if let path = dictation.audioPath {
            try removeOwnedDictationAudio(at: path)
        }
        let deleted = try repo.delete(id: dictation.id)
        guard deleted else {
            throw CLILookupError.notFound("No dictation matching '\(id)'")
        }
        let preview = String(dictation.rawTranscript.prefix(60))
        print("Deleted dictation: \"\(preview)\"")
    }
}

private func removeOwnedDictationAudio(at path: String, fileManager: FileManager = .default) throws {
    let rootURL = URL(fileURLWithPath: AppPaths.dictationsDir, isDirectory: true)
        .standardizedFileURL
    let targetURL = URL(fileURLWithPath: path).standardizedFileURL

    guard targetURL.path.hasPrefix(rootURL.path + "/") else {
        return
    }

    guard fileManager.fileExists(atPath: targetURL.path) else { return }
    do {
        try fileManager.removeItem(at: targetURL)
    } catch {
        throw TranscriptionAssetCleanupError.removalFailed(
            path: targetURL.path,
            reason: error.localizedDescription
        )
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
        try TranscriptionAssetCleanup.removeOwnedAssets(for: transcription)
        let deleted = try repo.delete(id: transcription.id)
        guard deleted else {
            throw CLILookupError.notFound("No transcription matching '\(id)'")
        }
        print("Deleted transcription: \"\(transcription.fileName)\"")
    }
}

struct DeleteMeetingAudioSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "delete-meeting-audio",
        abstract: "Delete stored audio for a meeting transcript while keeping the transcript."
    )

    @Argument(help: "The UUID, UUID prefix, or file name of the meeting transcription.")
    var id: String

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)

        let transcription = try findTranscription(id: id, repo: repo)
        guard transcription.sourceType == .meeting else {
            throw ValidationError("Transcription '\(id)' is not a meeting recording.")
        }

        let hasAudioPath = !(transcription.filePath?.isEmpty ?? true)
        let removedAudio = try TranscriptionAssetCleanup.removeOwnedMeetingAudio(for: transcription)
        guard removedAudio || !hasAudioPath else {
            throw ValidationError("Meeting audio is not stored in MacParakeet's managed recordings folder.")
        }

        try repo.updateFilePath(id: transcription.id, filePath: nil)

        if removedAudio {
            print("Deleted meeting audio for: \"\(transcription.fileName)\"")
        } else {
            print("No meeting audio attached for: \"\(transcription.fileName)\"")
        }
    }
}

struct ClearMeetingAudioSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-meeting-audio",
        abstract: "Delete all stored meeting audio while keeping saved meeting transcripts."
    )

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    @Option(name: .long, help: .hidden)
    var meetingRecordingsDirectory: String?

    func run() throws {
        try AppPaths.ensureDirectories()
        let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
        let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
        let fm = FileManager.default
        let dir = meetingRecordingsDirectory ?? AppPaths.meetingRecordingsDir

        if fm.fileExists(atPath: dir) {
            try fm.removeItem(atPath: dir)
        }
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try repo.clearStoredAudioPathsForMeetingTranscriptions()

        print("Deleted all stored meeting audio. Saved meeting transcripts remain.")
    }
}

struct FavoritesSubcommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "favorites",
        abstract: "List favorite transcriptions."
    )

    @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
    var json: Bool = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func run() throws {
        try emitJSONOrRethrow(json: json) {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TranscriptionRepository(dbQueue: dbManager.dbQueue)
            let favorites = try repo.fetchLibraryPage(query: TranscriptionLibraryQuery(
                favoritesOnly: true,
                limit: Int.max,
                includeProcessing: true
            )).items

            if json {
                try printJSON(favorites)
                return
            }

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
