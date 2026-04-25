import ArgumentParser
import Foundation
import MacParakeetCore

struct FlowWordsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "words",
        abstract: "Manage custom words vocabulary.",
        subcommands: [
            ListWords.self,
            AddWord.self,
            DeleteWord.self,
        ],
        defaultSubcommand: ListWords.self
    )

    struct ListWords: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List custom words."
        )

        enum SourceFilter: String, ExpressibleByArgument {
            case all, manual, learned
        }

        @Option(name: .long, help: "Filter by source: all, manual, learned. Default: all.")
        var source: SourceFilter = .all

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = CustomWordRepository(dbQueue: dbManager.dbQueue)
            let all = try repo.fetchAll()
            let words: [CustomWord]
            switch source {
            case .all:     words = all
            case .manual:  words = all.filter { $0.source == .manual }
            case .learned: words = all.filter { $0.source == .learned }
            }

            if json {
                try printJSON(words)
                return
            }

            if words.isEmpty {
                print("No custom words configured.")
                return
            }

            for word in words {
                let status = word.isEnabled ? "+" : "-"
                if let replacement = word.replacement {
                    print("[\(status)] \(word.word) -> \(replacement)  [\(word.source.rawValue)]  (\(word.id.uuidString.prefix(8)))")
                } else {
                    print("[\(status)] \(word.word) (anchor)  [\(word.source.rawValue)]  (\(word.id.uuidString.prefix(8)))")
                }
            }
            print("\n\(words.count) word(s)")
        }
    }

    struct AddWord: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a custom word or correction."
        )

        @Argument(help: "The word or phrase to match in STT output.")
        var word: String

        @Argument(help: "The replacement text (omit for vocabulary anchor).")
        var replacement: String?

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = CustomWordRepository(dbQueue: dbManager.dbQueue)

            let customWord = CustomWord(word: word, replacement: replacement)
            try repo.save(customWord)

            if let replacement {
                print("Added: \(word) -> \(replacement)")
            } else {
                print("Added vocabulary anchor: \(word)")
            }
        }
    }

    struct DeleteWord: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a custom word by ID."
        )

        @Argument(help: "The UUID (or prefix) of the word to delete.")
        var id: String

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = CustomWordRepository(dbQueue: dbManager.dbQueue)

            // Support UUID prefix matching
            let words = try repo.fetchAll()
            let matches = words.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }

            guard let word = matches.first else {
                throw FlowError.notFound("No word matching '\(id)'")
            }
            guard matches.count == 1 else {
                throw FlowError.ambiguous("Multiple words match '\(id)'. Be more specific.")
            }

            _ = try repo.delete(id: word.id)
            print("Deleted: \(word.word)")
        }
    }
}

enum FlowError: Error, LocalizedError {
    case notFound(String)
    case ambiguous(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let msg): return msg
        case .ambiguous(let msg): return msg
        }
    }
}
