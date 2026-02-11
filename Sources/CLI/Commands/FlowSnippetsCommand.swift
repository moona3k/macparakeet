import ArgumentParser
import Foundation
import MacParakeetCore

struct FlowSnippetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snippets",
        abstract: "Manage text snippets.",
        subcommands: [
            ListSnippets.self,
            AddSnippet.self,
            DeleteSnippet.self,
        ],
        defaultSubcommand: ListSnippets.self
    )

    struct ListSnippets: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List all text snippets."
        )

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: AppPaths.databasePath)
            let repo = TextSnippetRepository(dbQueue: dbManager.dbQueue)
            let snippets = try repo.fetchAll()

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

    struct AddSnippet: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a text snippet."
        )

        @Argument(help: "The trigger phrase (natural language, e.g. \"my signature\").")
        var trigger: String

        @Argument(help: "The expansion text.")
        var expansion: String

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: AppPaths.databasePath)
            let repo = TextSnippetRepository(dbQueue: dbManager.dbQueue)

            let snippet = TextSnippet(trigger: trigger, expansion: expansion)
            try repo.save(snippet)

            print("Added: Say \"\(trigger)\" -> \(expansion)")
        }
    }

    struct DeleteSnippet: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a text snippet by ID."
        )

        @Argument(help: "The UUID (or prefix) of the snippet to delete.")
        var id: String

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: AppPaths.databasePath)
            let repo = TextSnippetRepository(dbQueue: dbManager.dbQueue)

            // Support UUID prefix matching
            let snippets = try repo.fetchAll()
            let matches = snippets.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }

            guard let snippet = matches.first else {
                throw FlowError.notFound("No snippet matching '\(id)'")
            }
            guard matches.count == 1 else {
                throw FlowError.ambiguous("Multiple snippets match '\(id)'. Be more specific.")
            }

            _ = try repo.delete(id: snippet.id)
            print("Deleted: \"\(snippet.trigger)\"")
        }
    }
}
