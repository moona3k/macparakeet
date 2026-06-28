import ArgumentParser
import Foundation
import MacParakeetCore

enum PromptAutoRunSource: String, ExpressibleByArgument {
    case file
    case youtube
    case podcast
    case meeting

    var sourceType: Transcription.SourceType {
        switch self {
        case .file: return .file
        case .youtube: return .youtube
        case .podcast: return .podcast
        case .meeting: return .meeting
        }
    }
}

/// `macparakeet-cli prompts` — manage the prompt library and run prompts
/// against saved transcriptions. Built so an agent or CI run can verify
/// migrations, seed test prompts deterministically, and exercise the
/// multi-summary write path without launching the GUI.
struct PromptsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prompts",
        abstract: "Manage the prompt library and run prompts against transcriptions.",
        subcommands: [
            ListSubcommand.self,
            ShowSubcommand.self,
            AddSubcommand.self,
            SetSubcommand.self,
            DeleteSubcommand.self,
            RestoreDefaultsSubcommand.self,
            RunSubcommand.self,
        ],
        defaultSubcommand: ListSubcommand.self
    )
}

// MARK: - List

extension PromptsCommand {
    struct ListSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List prompts in the library."
        )

        enum Filter: String, ExpressibleByArgument {
            case all, visible, autoRun = "auto-run"
        }

        @Option(name: .long, help: "Which prompts to list: all, visible, auto-run. Default: all.")
        var filter: Filter = .all

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)

                let prompts: [Prompt]
                switch filter {
                case .all:     prompts = try repo.fetchAll().filter { $0.category == .result }
                case .visible: prompts = try repo.fetchVisible(category: .result)
                case .autoRun: prompts = try repo.fetchAutoRunPrompts()
                }

                if json {
                    try printJSON(prompts)
                    return
                }

                if prompts.isEmpty {
                    print("No prompts found.")
                    return
                }

                for p in prompts {
                    let badges = renderBadges(p)
                    print("\(p.id.uuidString.prefix(8))  \(p.name)\(badges)")
                }
                print()
                print("\(prompts.count) prompt(s)")
            }
        }
    }
}

// MARK: - Show

extension PromptsCommand {
    struct ShowSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a prompt's full content."
        )

        @Argument(help: "Prompt ID, ID prefix, or name.")
        var idOrName: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let prompt = try findPrompt(idOrName: idOrName, repo: repo)

                if json {
                    try printJSON(prompt)
                    return
                }

                print("ID:        \(prompt.id.uuidString)")
                print("Name:      \(prompt.name)\(renderBadges(prompt))")
                print("Category:  \(prompt.category.rawValue)")
                print("Updated:   \(ISO8601DateFormatter().string(from: prompt.updatedAt))")
                print()
                print(prompt.content)
            }
        }
    }
}

// MARK: - Add

extension PromptsCommand {
    struct AddSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a custom prompt."
        )

        @Option(name: .long, help: "Prompt display name (must be unique).")
        var name: String

        @Option(name: .long, help: "Prompt body text. Mutually exclusive with --from-file.")
        var content: String?

        @Option(name: .long, help: "Path to a file containing the prompt body.")
        var fromFile: String?

        @Flag(name: .long, help: "Mark as auto-run (implies visible).")
        var autoRun: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if content != nil && fromFile != nil {
                throw ValidationError("--content and --from-file are mutually exclusive")
            }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--name must not be empty")
            }
        }

        func run() throws {
            try AppPaths.ensureDirectories()
            let db = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = PromptRepository(dbQueue: db.dbQueue)

            // Body precedence: --content > --from-file > stdin (for piped workflows
            // like `cat prompt.md | macparakeet-cli prompts add --name X`).
            let body: String
            if let content {
                body = content
            } else if let fromFile {
                body = try String(contentsOfFile: expandTilde(fromFile), encoding: .utf8)
            } else {
                body = readStdinUTF8()
            }
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError("prompt body is empty (provide --content, --from-file, or pipe via stdin)")
            }

            let prompt = Prompt(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                content: body,
                isVisible: true,
                isAutoRun: autoRun
            )
            try repo.save(prompt)
            print("Added prompt '\(prompt.name)' (\(prompt.id.uuidString.prefix(8)))")
        }

        private func readStdinUTF8() -> String {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}

// MARK: - Set

extension PromptsCommand {
    struct SetSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Toggle a prompt's visibility or auto-run state."
        )

        @Argument(help: "Prompt ID, ID prefix, or name.")
        var idOrName: String

        @Flag(name: .long, help: "Make the prompt visible in the library.")
        var visible: Bool = false

        @Flag(name: .long, help: "Hide the prompt from the library.")
        var hidden: Bool = false

        @Flag(name: .long, help: "Enable auto-run on completed transcriptions.")
        var autoRun: Bool = false

        @Flag(name: .long, help: "Disable auto-run.")
        var noAutoRun: Bool = false

        @Option(name: .long, help: "Scope --auto-run/--no-auto-run to one source: file, youtube, podcast, meeting. Omit for global all-source behavior.")
        var source: PromptAutoRunSource?

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if visible && hidden {
                throw ValidationError("--visible and --hidden are mutually exclusive")
            }
            if autoRun && noAutoRun {
                throw ValidationError("--auto-run and --no-auto-run are mutually exclusive")
            }
            // Auto-run requires visible (mirrors PromptRepository.toggleAutoRun).
            // Reject the contradictory combo explicitly so the user doesn't get a
            // silent precedence surprise where one flag overrides the other.
            if hidden && autoRun {
                throw ValidationError("--hidden and --auto-run cannot be combined (auto-run requires visible)")
            }
            if source != nil {
                if visible || hidden {
                    throw ValidationError("--source can only be combined with --auto-run or --no-auto-run")
                }
                if !(autoRun || noAutoRun) {
                    throw ValidationError("--source requires --auto-run or --no-auto-run")
                }
            }
            if !(visible || hidden || autoRun || noAutoRun) {
                throw ValidationError("specify at least one of --visible / --hidden / --auto-run / --no-auto-run")
            }
        }

        /// Apply the set-flags to a prompt. Pure (no `updatedAt`/DB side effects)
        /// so the flag semantics are unit-testable without the app database.
        ///
        /// The `--auto-run` / `--no-auto-run` flags are global ("all sources"),
        /// mirroring `PromptRepository.toggleAutoRun`: clearing `appliesToSources`
        /// so a prompt narrowed in the GUI (e.g. meeting-only) isn't left claiming
        /// global-on while silently scoped, and a disabled prompt returns to a
        /// clean `nil` scope.
        static func applyFlags(
            to prompt: inout Prompt,
            visible: Bool,
            hidden: Bool,
            autoRun: Bool,
            noAutoRun: Bool
        ) {
            if visible { prompt.isVisible = true }
            if hidden  { prompt.isVisible = false; prompt.isAutoRun = false; prompt.appliesToSources = nil }
            if autoRun { prompt.isAutoRun = true; prompt.isVisible = true; prompt.appliesToSources = nil }
            if noAutoRun { prompt.isAutoRun = false; prompt.appliesToSources = nil }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)

                var prompt = try findPrompt(idOrName: idOrName, repo: repo)

                if let source {
                    try repo.setAutoRun(id: prompt.id, source: source.sourceType, enabled: autoRun)
                    prompt = try repo.fetch(id: prompt.id) ?? prompt
                } else {
                    Self.applyFlags(
                        to: &prompt,
                        visible: visible,
                        hidden: hidden,
                        autoRun: autoRun,
                        noAutoRun: noAutoRun
                    )

                    prompt.updatedAt = Date()
                    try repo.save(prompt)
                }

                if json {
                    try printJSON(prompt)
                } else {
                    print("Updated '\(prompt.name)':\(renderBadges(prompt))")
                }
            }
        }
    }
}

// MARK: - Delete

extension PromptsCommand {
    struct DeleteSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a custom prompt (built-ins cannot be deleted)."
        )

        @Argument(help: "Prompt ID, ID prefix, or name.")
        var idOrName: String

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try AppPaths.ensureDirectories()
            let db = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = PromptRepository(dbQueue: db.dbQueue)

            let prompt = try findPrompt(idOrName: idOrName, repo: repo)
            if prompt.isBuiltIn {
                throw PromptCLIError.cannotDeleteBuiltIn(prompt.name)
            }
            let deleted = try repo.delete(id: prompt.id)
            guard deleted else {
                throw PromptCLIError.deleteFailed(prompt.name)
            }
            print("Deleted prompt '\(prompt.name)'")
        }
    }
}

// MARK: - Restore Defaults

extension PromptsCommand {
    struct RestoreDefaultsSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore-defaults",
            abstract: "Re-show built-in result prompts and hidden built-in Transforms."
        )

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try AppPaths.ensureDirectories()
            let db = try DatabaseManager(path: resolvedDatabasePath(database))
            let repo = PromptRepository(dbQueue: db.dbQueue)
            try repo.restoreDefaults()
            print("Built-in result prompts and hidden built-in Transforms re-shown.")
        }
    }
}

// MARK: - Run

extension PromptsCommand {
    struct RunSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a saved prompt against a saved transcription via an LLM provider."
        )

        @OptionGroup var llm: LLMInlineOptions

        @Argument(help: "Prompt ID, ID prefix, or name.")
        var promptIdOrName: String

        @Option(name: .long, help: "Transcription ID or prefix to run the prompt against.")
        var transcription: String

        @Flag(name: .long, help: "Print output only; don't save a PromptResult to the summaries table.")
        var noStore: Bool = false

        @Flag(name: .long, help: "Stream the response token by token.")
        var stream: Bool = false

        @Flag(name: .long, help: "Emit a structured JSON envelope (output, provider, model, usage, stopReason, latencyMs) instead of plain text.")
        var json: Bool = false

        @Option(name: .long, help: "Extra instructions appended to the prompt for this run.")
        var extra: String?

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if json && stream {
                throw ValidationError("--json with --stream is not yet supported. Run without --stream for the envelope, or omit --json for token streaming.")
            }
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let promptRepo = PromptRepository(dbQueue: db.dbQueue)
                let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
                let resultRepo = PromptResultRepository(dbQueue: db.dbQueue)

                let prompt = try findPrompt(idOrName: promptIdOrName, repo: promptRepo)
                let transcript = try findTranscription(id: transcription, repo: transcriptionRepo)

                let transcriptText = transcript.cleanTranscript ?? transcript.rawTranscript ?? ""
                guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PromptCLIError.emptyTranscript(transcript.fileName)
                }

                let trimmedExtra = extra?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedExtra = (trimmedExtra?.isEmpty == false) ? trimmedExtra : nil
                let systemPrompt = PromptSystemPromptAssembler.assemble(
                    promptContent: prompt.content,
                    extraInstructions: normalizedExtra,
                    userNotes: transcript.userNotes,
                    transcript: transcriptText
                )

                let execution = try llm.buildExecutionContext()
                let service = LLMService(
                    client: execution.client,
                    contextResolver: StaticLLMExecutionContextResolver(context: execution.context)
                )

                var output = ""
                var jsonResult: LLMResult?
                if json {
                    let result = try await service.generatePromptResultDetailed(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt
                    )
                    output = result.output
                    jsonResult = result
                } else if stream {
                    let tokenStream = service.generatePromptResultStream(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt
                    )
                    for try await token in tokenStream {
                        print(token, terminator: "")
                        output += token
                    }
                    print()
                } else {
                    output = try await service.generatePromptResult(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt
                    )
                    print(output)
                }

                if !noStore {
                    let result = PromptResult(
                        transcriptionId: transcript.id,
                        promptName: prompt.name,
                        promptContent: prompt.content,
                        extraInstructions: normalizedExtra,
                        content: output,
                        userNotesSnapshot: transcript.userNotes
                    )
                    try resultRepo.save(result)
                    // Status messages on stderr so stdout stays grep-able as the prompt output.
                    FileHandle.standardError.write(Data("\nSaved PromptResult \(result.id.uuidString.prefix(8))\n".utf8))
                }

                if let jsonResult {
                    try printJSON(jsonResult)
                }
            }
        }
    }
}

// MARK: - Helpers

private func renderBadges(_ p: Prompt) -> String {
    var badges: [String] = []
    if p.isBuiltIn { badges.append("built-in") }
    if !p.isVisible { badges.append("hidden") }
    if p.isAutoRun {
        if let appliesToSources = p.appliesToSources {
            let sources = Transcription.SourceType.allCases
                .filter { appliesToSources.contains($0) }
                .map(\.rawValue)
                .joined(separator: ",")
            badges.append("auto-run: \(sources)")
        } else {
            badges.append("auto-run")
        }
    }
    return badges.isEmpty ? "" : "  [\(badges.joined(separator: ", "))]"
}

private enum PromptCLIError: Error, LocalizedError {
    case cannotDeleteBuiltIn(String)
    case deleteFailed(String)
    case emptyTranscript(String)

    var errorDescription: String? {
        switch self {
        case .cannotDeleteBuiltIn(let name):
            return "Cannot delete built-in prompt '\(name)'. Use `prompts set <name> --hidden` to hide it instead."
        case .deleteFailed(let name):
            return "Delete failed for prompt '\(name)'."
        case .emptyTranscript(let fileName):
            return "Transcription '\(fileName)' has no text to run a prompt against."
        }
    }
}
