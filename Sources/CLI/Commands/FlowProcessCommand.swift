import ArgumentParser
import AppKit
import Foundation
import MacParakeetCore

struct FlowProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Run clean text processing on input text."
    )

    @Argument(help: "Text to process through the clean pipeline.")
    var text: String

    @Flag(name: .long, help: "Copy result to clipboard.")
    var copy: Bool = false

    func run() async throws {
        try AppPaths.ensureDirectories()
        let dbManager = try DatabaseManager(path: AppPaths.databasePath)
        let wordRepo = CustomWordRepository(dbQueue: dbManager.dbQueue)
        let snippetRepo = TextSnippetRepository(dbQueue: dbManager.dbQueue)

        let words = try wordRepo.fetchEnabled()
        let snippets = try snippetRepo.fetchEnabled()

        let pipeline = TextProcessingPipeline()
        let result = pipeline.process(text: text, customWords: words, snippets: snippets)

        print(result.text)

        if !result.expandedSnippetIDs.isEmpty {
            try snippetRepo.incrementUseCount(ids: result.expandedSnippetIDs)
        }

        if copy {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.text, forType: .string)
            print("(copied to clipboard)")
        }
    }
}
