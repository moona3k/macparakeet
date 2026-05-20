import ArgumentParser

struct VocabCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vocab",
        abstract: "Manage vocabulary: custom words, text snippets, and the text-processing pipeline.",
        discussion: "`flow` is a deprecated alias for `vocab` and will be removed at the next major CLI version.",
        subcommands: [
            VocabProcessCommand.self,
            VocabWordsCommand.self,
            VocabSnippetsCommand.self,
            VocabLegacyVocabularyCommand.self,
            VocabExportCommand.self,
            VocabImportCommand.self,
            VocabSchemaCommand.self,
        ],
        aliases: ["flow"]
    )
}

struct VocabLegacyVocabularyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vocabulary",
        abstract: "Deprecated compatibility path for flow vocabulary export/import/schema.",
        discussion: "Use `vocab export`, `vocab import`, or `vocab schema` instead.",
        shouldDisplay: false,
        subcommands: [
            VocabExportCommand.self,
            VocabImportCommand.self,
            VocabSchemaCommand.self,
        ]
    )
}
