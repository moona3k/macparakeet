import ArgumentParser
import Foundation
import MacParakeetCore

struct VocabSnippetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snippets",
        abstract: "Manage text snippets.",
        subcommands: [
            ListSnippets.self,
            AddSnippet.self,
            EditSnippet.self,
            DeleteSnippet.self,
        ],
        defaultSubcommand: ListSnippets.self
    )

    struct ListSnippets: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all text snippets."
        )

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = TextSnippetRepository(dbQueue: dbManager.dbQueue)
                let snippets = try repo.fetchAll()

                if json {
                    try printJSON(snippets)
                    return
                }

                if snippets.isEmpty {
                    print("No text snippets configured.")
                    return
                }

                for snippet in snippets {
                    let status = snippet.isEnabled ? "+" : "-"
                    var line = "[\(status)] Say: \"\(snippet.trigger)\" -> \(snippet.expansion)"
                    if snippet.useCount > 0 {
                        line += "  (used \(snippet.useCount)x)"
                    }
                    line += "  (\(snippet.id.uuidString.prefix(8)))"
                    print(line)
                }
                print("\n\(snippets.count) snippet(s)")
            }
        }
    }

    struct AddSnippet: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a text snippet."
        )

        @Argument(help: "The trigger phrase (natural language, e.g. \"my signature\").")
        var trigger: String

        @Argument(help: "The expansion text.")
        var expansion: String

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TextSnippetRepository(dbQueue: dbManager.dbQueue)

            let snippet = TextSnippet(trigger: trigger, expansion: expansion)
            try repo.save(snippet)

            print("Added: Say \"\(trigger)\" -> \(expansion)")
        }
    }

    struct EditSnippet: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "edit",
            abstract: "Edit a text snippet by ID."
        )

        @Argument(help: "The UUID (or prefix) of the snippet to edit.")
        var id: String

        @Option(help: "Replacement trigger phrase. Omit to keep the existing trigger.")
        var trigger: String?

        @Option(help: "Replacement expansion text. Omit to keep the existing expansion.")
        var expansion: String?

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            guard trigger != nil || expansion != nil else {
                throw ValidationError("Provide --trigger, --expansion, or both.")
            }

            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TextSnippetRepository(dbQueue: dbManager.dbQueue)
            let snippets = try repo.fetchAll()
            var snippet = try VocabSnippetsCommand.resolveSnippet(id: id, snippets: snippets)

            if let trigger {
                let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw ValidationError("Trigger cannot be empty.")
                }
                if snippets.contains(where: {
                    $0.id != snippet.id
                        && $0.trigger.caseInsensitiveCompare(trimmed) == .orderedSame
                }) {
                    throw VocabError.duplicate("Snippet trigger '\(trimmed)' already exists.")
                }
                snippet.trigger = trimmed
            }

            if let expansion {
                let processed = VocabSnippetsCommand.processedExpansion(from: expansion)
                guard !processed.isEmpty else {
                    throw ValidationError("Expansion cannot be empty.")
                }
                snippet.expansion = processed
            }

            snippet.updatedAt = Date()
            try repo.save(snippet)
            print("Updated: Say \"\(snippet.trigger)\" -> \(snippet.expansion)")
        }
    }

    struct DeleteSnippet: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a text snippet by ID."
        )

        @Argument(help: "The UUID (or prefix) of the snippet to delete.")
        var id: String

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = TextSnippetRepository(dbQueue: dbManager.dbQueue)

            let snippets = try repo.fetchAll()
            let snippet = try VocabSnippetsCommand.resolveSnippet(
                id: id,
                snippets: snippets,
                minimumPrefixLength: 1
            )

            _ = try repo.delete(id: snippet.id)
            print("Deleted: \"\(snippet.trigger)\"")
        }
    }

    private static func resolveSnippet(
        id: String,
        snippets: [TextSnippet],
        minimumPrefixLength: Int = 4
    ) throws -> TextSnippet {
        let searchID = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard searchID.count >= minimumPrefixLength else {
            throw ValidationError("ID prefix must be at least \(minimumPrefixLength) characters.")
        }
        let matches = snippets.filter { $0.id.uuidString.lowercased().hasPrefix(searchID) }

        guard let snippet = matches.first else {
            throw VocabError.notFound("No snippet matching '\(id)'")
        }
        guard matches.count == 1 else {
            throw VocabError.ambiguous("Multiple snippets match '\(id)'. Be more specific.")
        }
        return snippet
    }

    private static func processedExpansion(from raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\\n", with: "\n")
    }
}
