import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli flow vocabulary` — export / import / schema for the
/// combined vocabulary bundle (custom words + text snippets).
///
/// Designed so that a local coding agent can:
///   1. Run `flow vocabulary schema` to learn the JSON shape.
///   2. Generate a bundle file from natural-language input ("add 50
///      medical terminology corrections to my vocabulary").
///   3. Pipe it into `flow vocabulary import` with `--dry-run` to preview,
///      then again without it to commit.
struct FlowVocabularyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vocabulary",
        abstract: "Backup, restore, and bulk-edit the combined vocabulary (custom words + text snippets).",
        discussion: """
        Vocabulary bundles are versioned JSON files containing your custom-word
        corrections and text snippets. They round-trip cleanly between Macs.

        Common workflows
          • Back up before reinstall:
              macparakeet-cli flow vocabulary export --output ~/vocab.json
          • Restore on a new machine:
              macparakeet-cli flow vocabulary import --input ~/vocab.json
          • Let a coding agent generate entries from natural language:
              macparakeet-cli flow vocabulary schema           # show the spec
              # ...agent writes vocab.json...
              macparakeet-cli flow vocabulary import --input vocab.json --dry-run
              macparakeet-cli flow vocabulary import --input vocab.json
        """,
        subcommands: [
            ExportVocabulary.self,
            ImportVocabulary.self,
            VocabularySchema.self,
        ]
    )

    // MARK: - Export

    struct ExportVocabulary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Write the current vocabulary as a JSON bundle to a file or stdout.",
            discussion: """
            Output is a `macparakeet.vocabulary` v1 bundle. Run
            `flow vocabulary schema` for the full format. Only manual custom
            words are exported (learned words regenerate per-machine).
            """
        )

        @Option(name: [.short, .long], help: "Output file path. Omit to write to stdout.")
        var output: String?

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() async throws {
            try AppPaths.ensureDirectories()
            let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
            let service = VocabularyImportExportService(
                customWordRepo: CustomWordRepository(dbQueue: dbManager.dbQueue),
                snippetRepo: TextSnippetRepository(dbQueue: dbManager.dbQueue),
                dbQueue: dbManager.dbQueue
            )
            let export = try service.exportBundleData()

            if let output, !output.trimmingCharacters(in: .whitespaces).isEmpty {
                let resolved = expandTilde(output)
                let url = URL(fileURLWithPath: resolved)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try export.data.write(to: url, options: .atomic)
                let bundle = export.bundle
                printErr("Exported \(bundle.customWords.count) word(s) and \(bundle.textSnippets.count) snippet(s) to \(resolved)")
            } else {
                FileHandle.standardOutput.write(export.data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        }
    }

    // MARK: - Import

    struct ImportVocabulary: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Read a JSON vocabulary bundle and apply it to the database.",
            discussion: """
            Reads a `macparakeet.vocabulary` v1 bundle from the given file or
            stdin. By default, duplicate entries (matched case-insensitively
            on `word` / `trigger`) are SKIPPED — pass `--policy replace` to
            overwrite. Pass `--dry-run` to see counts without writing.
            """
        )

        @Option(name: [.short, .long], help: "Input file path. Omit to read from stdin.")
        var input: String?

        @Option(name: .long, help: "Conflict policy when an entry already exists: skip (default) or replace.")
        var policy: PolicyOption = .skip

        @Flag(name: .long, help: "Decode + report counts without writing to the database.")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Emit machine-readable JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        enum PolicyOption: String, ExpressibleByArgument, CaseIterable {
            case skip, replace

            var serviceValue: VocabularyImportExportService.ConflictPolicy {
                switch self {
                case .skip: return .skip
                case .replace: return .replace
                }
            }
        }

        func run() async throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let dbManager = try DatabaseManager(path: resolvedDatabasePath(database))
                let service = VocabularyImportExportService(
                    customWordRepo: CustomWordRepository(dbQueue: dbManager.dbQueue),
                    snippetRepo: TextSnippetRepository(dbQueue: dbManager.dbQueue),
                    dbQueue: dbManager.dbQueue
                )

                let data = try readInputData()
                let preview = try service.decodePreview(from: data)

                if dryRun {
                    let dryReport = DryRunReport(
                        ok: true,
                        wordsTotal: preview.wordsTotal,
                        snippetsTotal: preview.snippetsTotal,
                        wordConflicts: preview.wordConflicts,
                        snippetConflicts: preview.snippetConflicts,
                        duplicateWords: preview.duplicateWords,
                        duplicateSnippets: preview.duplicateSnippets,
                        policy: policy.rawValue
                    )
                    if json {
                        try printJSON(dryReport)
                    } else {
                        printDryRunHuman(preview)
                    }
                    return
                }

                let result = try service.apply(preview: preview, policy: policy.serviceValue)
                let report = ApplyReport(
                    ok: true,
                    wordsAdded: result.wordsAdded,
                    wordsReplaced: result.wordsReplaced,
                    wordsSkipped: result.wordsSkipped,
                    snippetsAdded: result.snippetsAdded,
                    snippetsReplaced: result.snippetsReplaced,
                    snippetsSkipped: result.snippetsSkipped,
                    policy: policy.rawValue
                )

                if json {
                    try printJSON(report)
                } else {
                    printApplyHuman(result)
                }
            }
        }

        private func readInputData() throws -> Data {
            if let input, !input.trimmingCharacters(in: .whitespaces).isEmpty {
                let url = URL(fileURLWithPath: expandTilde(input))
                return try Data(contentsOf: url)
            }
            // stdin
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty else { throw CLIInputError.empty }
            return data
        }

        private func printDryRunHuman(_ preview: VocabularyImportExportService.ImportPreview) {
            print("Bundle contents:")
            print("  Custom words:   \(preview.wordsTotal)")
            print("  Text snippets:  \(preview.snippetsTotal)")
            if let appVersion = preview.bundle.appVersion {
                print("  Exported by:    MacParakeet \(appVersion)")
            }
            print("  Exported at:    \(preview.bundle.exportedAt)")

            if preview.hasConflicts {
                print("\nConflicts (would be \(policy == .skip ? "SKIPPED" : "REPLACED")):")
                if !preview.wordConflicts.isEmpty {
                    let sample = preview.wordConflicts.prefix(10).map { "\"\($0)\"" }.joined(separator: ", ")
                    let extra = preview.wordConflicts.count - min(10, preview.wordConflicts.count)
                    print("  Words (\(preview.wordConflicts.count)): \(sample)\(extra > 0 ? ", and \(extra) more" : "")")
                }
                if !preview.snippetConflicts.isEmpty {
                    let sample = preview.snippetConflicts.prefix(10).map { "\"\($0)\"" }.joined(separator: ", ")
                    let extra = preview.snippetConflicts.count - min(10, preview.snippetConflicts.count)
                    print("  Snippets (\(preview.snippetConflicts.count)): \(sample)\(extra > 0 ? ", and \(extra) more" : "")")
                }
                if !preview.duplicateWords.isEmpty {
                    let sample = preview.duplicateWords.prefix(10).map { "\"\($0)\"" }.joined(separator: ", ")
                    let extra = preview.duplicateWords.count - min(10, preview.duplicateWords.count)
                    print("  Duplicate words in file (\(preview.duplicateWords.count)): \(sample)\(extra > 0 ? ", and \(extra) more" : "")")
                }
                if !preview.duplicateSnippets.isEmpty {
                    let sample = preview.duplicateSnippets.prefix(10).map { "\"\($0)\"" }.joined(separator: ", ")
                    let extra = preview.duplicateSnippets.count - min(10, preview.duplicateSnippets.count)
                    print("  Duplicate snippets in file (\(preview.duplicateSnippets.count)): \(sample)\(extra > 0 ? ", and \(extra) more" : "")")
                }
            } else {
                print("\nNo conflicts. All entries are new.")
            }
            print("\n(dry-run — nothing was written)")
        }

        private func printApplyHuman(_ r: VocabularyImportExportService.ImportResult) {
            print("Custom words:")
            print("  Added:    \(r.wordsAdded)")
            if r.wordsReplaced > 0 { print("  Replaced: \(r.wordsReplaced)") }
            if r.wordsSkipped > 0  { print("  Skipped:  \(r.wordsSkipped) (already existed)") }
            print("Text snippets:")
            print("  Added:    \(r.snippetsAdded)")
            if r.snippetsReplaced > 0 { print("  Replaced: \(r.snippetsReplaced)") }
            if r.snippetsSkipped > 0  { print("  Skipped:  \(r.snippetsSkipped) (already existed)") }
        }

        struct DryRunReport: Encodable {
            let ok: Bool
            let wordsTotal: Int
            let snippetsTotal: Int
            let wordConflicts: [String]
            let snippetConflicts: [String]
            let duplicateWords: [String]
            let duplicateSnippets: [String]
            let policy: String
        }

        struct ApplyReport: Encodable {
            let ok: Bool
            let wordsAdded: Int
            let wordsReplaced: Int
            let wordsSkipped: Int
            let snippetsAdded: Int
            let snippetsReplaced: Int
            let snippetsSkipped: Int
            let policy: String
        }
    }

    // MARK: - Schema

    struct VocabularySchema: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "schema",
            abstract: "Print the vocabulary bundle JSON schema and an example.",
            discussion: """
            Use this when asking a coding agent to produce a bundle. The
            output is plain text + JSON example so an LLM can read it
            directly. Pass `--json` to get a structured spec object instead.
            """
        )

        @Flag(name: .long, help: "Emit a JSON spec object instead of human-readable text.")
        var json: Bool = false

        func run() async throws {
            if json {
                try printJSON(VocabularyBundleSpec.current())
            } else {
                print(VocabularyBundleSpec.humanReadable)
            }
        }
    }
}

// MARK: - Schema spec

/// Self-describing JSON spec for the vocabulary bundle. Designed for ingestion
/// by a coding agent — every field carries a description, and the spec
/// includes a complete example.
struct VocabularyBundleSpec: Encodable {
    let schema: String
    let version: Int
    let description: String
    let fields: [Field]
    let example: VocabularyBundle

    struct Field: Encodable {
        let path: String
        let type: String
        let required: Bool
        let description: String
    }

    static func current() -> VocabularyBundleSpec {
        VocabularyBundleSpec(
            schema: VocabularyBundle.schemaIdentifier,
            version: VocabularyBundle.currentVersion,
            description: """
            Portable backup of a MacParakeet user's vocabulary. Includes \
            custom-word corrections (used by the Clean text-processing \
            pipeline) and text snippets (trigger phrase → expansion text). \
            UUIDs are intentionally omitted: they are generated at import \
            time. The `.learned` source is intentionally omitted: it \
            regenerates per-machine.
            """,
            fields: [
                .init(path: "schema", type: "string", required: true,
                      description: "Always \"\(VocabularyBundle.schemaIdentifier)\". Used to detect non-bundle JSON files."),
                .init(path: "version", type: "integer", required: true,
                      description: "Format version. Current: \(VocabularyBundle.currentVersion). Importer rejects newer versions."),
                .init(path: "exportedAt", type: "ISO-8601 date-time", required: true,
                      description: "When the bundle was generated. Shown in the import preview."),
                .init(path: "appVersion", type: "string", required: false,
                      description: "MacParakeet version that produced the bundle. Optional but recommended."),
                .init(path: "customWords", type: "array of CustomWord", required: true,
                      description: "Word-correction rules applied during the Clean pipeline. Match is case-insensitive."),
                .init(path: "customWords[].word", type: "string", required: true,
                      description: "The raw token Parakeet emits (often misspelled or wrong-cased). Leading/trailing whitespace is trimmed; empty values are rejected."),
                .init(path: "customWords[].replacement", type: "string or null", required: false,
                      description: "What to substitute. Blank strings are treated as null."),
                .init(path: "customWords[].isEnabled", type: "boolean", required: true,
                      description: "Whether the rule is active by default. Disabled entries import disabled."),
                .init(path: "customWords[].createdAt", type: "ISO-8601 date-time or null", required: false,
                      description: "Original creation time. Optional; defaults to import time when omitted."),
                .init(path: "textSnippets", type: "array of TextSnippet", required: true,
                      description: "Trigger → expansion shortcuts. The trigger is what you say; the expansion is what gets pasted."),
                .init(path: "textSnippets[].trigger", type: "string", required: true,
                      description: "Spoken trigger phrase (e.g. \"my address\"). Leading/trailing whitespace is trimmed; empty values are rejected."),
                .init(path: "textSnippets[].expansion", type: "string", required: true,
                      description: "Replacement text. Leading/trailing spaces are trimmed; empty values are rejected. Real newline characters in JSON (\\n) become line breaks."),
                .init(path: "textSnippets[].isEnabled", type: "boolean", required: true,
                      description: "Whether the snippet is active."),
                .init(path: "textSnippets[].action", type: "string or null", required: false,
                      description: "Optional keystroke to send after pasting. Currently only \"return\" is supported. null means no action."),
                .init(path: "textSnippets[].createdAt", type: "ISO-8601 date-time or null", required: false,
                      description: "Original creation time. Optional; defaults to import time when omitted."),
            ],
            example: exampleBundle()
        )
    }

    static func exampleBundle() -> VocabularyBundle {
        let now = Date(timeIntervalSince1970: 1_745_000_000) // stable for docs
        return VocabularyBundle(
            exportedAt: now,
            appVersion: "0.6.0",
            customWords: [
                .init(word: "kubernetes", replacement: "Kubernetes",
                      isEnabled: true, createdAt: now),
                .init(word: "MacParakeet", replacement: nil,
                      isEnabled: true, createdAt: now),
                .init(word: "centre", replacement: "centre",
                      isEnabled: true, createdAt: now),
            ],
            textSnippets: [
                .init(trigger: "my address",
                      expansion: "123 Main St\nSan Francisco, CA 94110",
                      isEnabled: true, action: nil, createdAt: now),
                .init(trigger: "send message",
                      expansion: "thanks!", isEnabled: true,
                      action: .returnKey, createdAt: now),
            ]
        )
    }

    // MARK: - Human-readable doc

    static var humanReadable: String {
        let exampleData = (try? prettyEncoder.encode(exampleBundle())) ?? Data()
        let exampleJSON = String(data: exampleData, encoding: .utf8) ?? "{}"

        return """
        MacParakeet Vocabulary Bundle — JSON Schema (v\(VocabularyBundle.currentVersion))
        =====================================================================

        File identity
          schema:   "\(VocabularyBundle.schemaIdentifier)"   (must match)
          version:  \(VocabularyBundle.currentVersion)               (importer rejects newer versions)

        Top-level fields
          schema        string         required   format identifier
          version       integer        required   bundle format version
          exportedAt    ISO-8601       required   when this file was generated
          appVersion    string         optional   MacParakeet version that wrote it
          customWords   CustomWord[]   required   word correction rules
          textSnippets  TextSnippet[]  required   trigger → expansion shortcuts

        CustomWord
          word          string         required   what Parakeet emits; trimmed, non-empty
          replacement   string|null    optional   trimmed substitute (blank = null)
          isEnabled     boolean        required   active by default
          createdAt     ISO-8601|null  optional   original creation time

        TextSnippet
          trigger       string         required   natural spoken phrase; trimmed, non-empty
          expansion     string         required   pasted text; trimmed, non-empty; real \\n becomes a newline
          isEnabled     boolean        required   active by default
          action        "return"|null  optional   keystroke after paste (only "return" or null)
          createdAt     ISO-8601|null  optional   original creation time

        Tips for generating bundles
          • Match by `word` / `trigger` is case-insensitive — don't include
            both "Daniel" and "daniel"; the importer will treat them as one.
          • Triggers are heard as natural speech. Use phrases like "my email",
            not "addr" or "sig".
          • For multi-line expansions, use real \\n in the JSON string.
          • Do not include blank words, triggers, or expansions; import rejects
            those the same way manual entry does.
          • UUIDs are NOT in this format — they're generated on import.

        Round-trip
          # Generate template:
          macparakeet-cli flow vocabulary export > template.json
          # ...edit it...
          macparakeet-cli flow vocabulary import --input template.json --dry-run
          macparakeet-cli flow vocabulary import --input template.json

        Example
        -------
        \(exampleJSON)
        """
    }

    private static let prettyEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
