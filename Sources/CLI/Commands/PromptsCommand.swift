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
            CollectionsSubcommand.self,
            ShowSubcommand.self,
            HistorySubcommand.self,
            DiffSubcommand.self,
            RestoreSubcommand.self,
            AddSubcommand.self,
            SetSubcommand.self,
            DeleteSubcommand.self,
            RestoreDeletedSubcommand.self,
            RestoreDefaultsSubcommand.self,
            RunSubcommand.self,
        ],
        defaultSubcommand: ListSubcommand.self
    )
}

// MARK: - List

extension PromptsCommand {
    struct CollectionsSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "collections",
            abstract: "Organize prompts into collections.",
            subcommands: [
                ListSubcommand.self,
                AddSubcommand.self,
                RenameSubcommand.self,
                DeleteSubcommand.self,
                ReorderSubcommand.self,
            ],
            defaultSubcommand: ListSubcommand.self
        )

        struct ListSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List prompt collections in display order."
            )

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let collections = try promptCollectionRepository(database: database).fetchAll()
                    if json {
                        try printJSON(collections)
                    } else if collections.isEmpty {
                        print("No prompt collections.")
                    } else {
                        for collection in collections {
                            print("\(collection.id.uuidString)  \(collection.name)")
                        }
                    }
                }
            }
        }

        struct AddSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "add",
                abstract: "Add a prompt collection."
            )

            @Option(name: .long, help: "Collection display name (must be unique).")
            var name: String

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("--name must not be empty")
                }
            }

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let repository = try promptCollectionRepository(database: database)
                    let collection = PromptCollection(
                        name: name,
                        sortOrder: (try repository.fetchAll().map(\.sortOrder).max() ?? -1) + 1
                    )
                    try repository.save(collection)
                    let saved = try requirePromptCollection(id: collection.id, repository: repository)
                    if json {
                        try printJSON(saved)
                    } else {
                        print("Added prompt collection '\(saved.name)' (\(saved.id.uuidString))")
                    }
                }
            }
        }

        struct RenameSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "rename",
                abstract: "Rename a prompt collection."
            )

            @Argument(help: "Full prompt collection UUID.")
            var id: String

            @Option(name: .long, help: "New collection display name (must be unique).")
            var name: String

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ValidationError("--name must not be empty")
                }
            }

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let repository = try promptCollectionRepository(database: database)
                    let collectionID = try fullPromptCollectionID(id)
                    var collection = try requirePromptCollection(id: collectionID, repository: repository)
                    collection.name = name
                    try repository.save(collection)
                    let saved = try requirePromptCollection(id: collectionID, repository: repository)
                    if json {
                        try printJSON(saved)
                    } else {
                        print("Renamed prompt collection '\(saved.name)'.")
                    }
                }
            }
        }

        struct DeleteSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "delete",
                abstract: "Delete a prompt collection and unfile its prompts."
            )

            @Argument(help: "Full prompt collection UUID.")
            var id: String

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let repository = try promptCollectionRepository(database: database)
                    let collectionID = try fullPromptCollectionID(id)
                    let collection = try requirePromptCollection(id: collectionID, repository: repository)
                    guard try repository.delete(id: collectionID) else {
                        throw PromptCollectionRepositoryError.collectionNotFound(collectionID)
                    }
                    if json {
                        try printJSON(PromptCollectionDeleteResult(id: collectionID, name: collection.name))
                    } else {
                        print("Deleted prompt collection '\(collection.name)'; prompts are now unfiled.")
                    }
                }
            }
        }

        struct ReorderSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "reorder",
                abstract: "Replace the complete prompt collection display order."
            )

            @Argument(help: "Complete ordered list of prompt collection UUIDs.")
            var ids: [String] = []

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let repository = try promptCollectionRepository(database: database)
                    try repository.reorder(ids: ids.map(fullPromptCollectionID))
                    let collections = try repository.fetchAll()
                    if json {
                        try printJSON(collections)
                    } else {
                        print("Reordered \(collections.count) prompt collection(s).")
                    }
                }
            }
        }
    }

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
                    try printJSON(prompts.map { try promptCLIRecord($0, db: db) })
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

        @Option(name: .long, help: "Show an immutable historical version number instead of the active prompt.")
        var version: Int?

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let prompt = try findPrompt(
                    idOrName: idOrName,
                    repo: repo,
                    categories: [.result, .transform]
                )

                if let version {
                    let versionRepo = PromptVersionRepository(dbQueue: db.dbQueue)
                    let selected = try findPromptVersion(number: version, prompt: prompt, repo: versionRepo)
                    if json {
                        try printJSON(selected)
                    } else {
                        printPromptVersion(selected, promptName: prompt.name)
                    }
                    return
                }

                if json {
                    try printJSON(try promptCLIRecord(prompt, db: db))
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

// MARK: - History and diff

extension PromptsCommand {
    struct HistorySubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "history",
            abstract: "List a prompt's immutable versions."
        )

        @Argument(help: "Prompt ID, ID prefix, or name.") var idOrName: String
        @Flag(name: .long, help: "Emit JSON instead of human-readable output.") var json = false
        @Option(help: "Path to SQLite database file (defaults to the app database).") var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let db = try makeDatabaseManager(database: database)
                let prompt = try findPrompt(
                    idOrName: idOrName,
                    repo: PromptRepository(dbQueue: db.dbQueue),
                    categories: [.result, .transform]
                )
                let versions = try PromptVersionRepository(dbQueue: db.dbQueue).fetchAll(promptId: prompt.id)
                if json {
                    try printJSON(versions)
                } else {
                    for version in versions {
                        let active = version.id == prompt.activeVersionId ? "  [active]" : ""
                        print("v\(version.versionNumber)  \(version.origin.rawValue)  \(formatPromptVersionDate(version.createdAt))\(active)")
                    }
                }
            }
        }
    }

    struct DiffSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "diff",
            abstract: "Compare two immutable prompt versions."
        )

        @Argument(help: "Prompt ID, ID prefix, or name.") var idOrName: String
        @Option(name: .long, help: "Older version number.") var from: Int
        @Option(name: .long, help: "Newer version number.") var to: Int
        @Flag(name: .long, help: "Emit JSON instead of human-readable output.") var json = false
        @Option(help: "Path to SQLite database file (defaults to the app database).") var database: String?

        func validate() throws {
            guard from > 0, to > 0 else { throw ValidationError("--from and --to must be positive version numbers") }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let db = try makeDatabaseManager(database: database)
                let prompt = try findPrompt(
                    idOrName: idOrName,
                    repo: PromptRepository(dbQueue: db.dbQueue),
                    categories: [.result, .transform]
                )
                let versions = PromptVersionRepository(dbQueue: db.dbQueue)
                let old = try findPromptVersion(number: from, prompt: prompt, repo: versions)
                let new = try findPromptVersion(number: to, prompt: prompt, repo: versions)
                let diff = PromptDiffService.diff(from: old, to: new)
                if json {
                    try printJSON(PromptDiffRecord(prompt: prompt, from: old, to: new, diff: diff))
                } else {
                    print("\(prompt.name): v\(from) -> v\(to)")
                    print(renderPromptDiff(diff))
                }
            }
        }
    }

    struct RestoreSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "Restore an old prompt version by creating a new active version."
        )

        @Argument(help: "Prompt ID, ID prefix, or name.") var idOrName: String
        @Option(name: .long, help: "Version number to copy into a new version.") var version: Int
        @Option(name: .long, help: "Optional history note for the restored version.") var note: String?
        @Flag(name: .long, help: "Emit JSON instead of human-readable output.") var json = false
        @Option(help: "Path to SQLite database file (defaults to the app database).") var database: String?

        func validate() throws {
            guard version > 0 else { throw ValidationError("--version must be positive") }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let db = try makeDatabaseManager(database: database)
                let prompt = try findPrompt(
                    idOrName: idOrName,
                    repo: PromptRepository(dbQueue: db.dbQueue),
                    categories: [.result, .transform]
                )
                let versionRepo = PromptVersionRepository(dbQueue: db.dbQueue)
                let source = try findPromptVersion(number: version, prompt: prompt, repo: versionRepo)
                let restored = try PromptEditingService(dbQueue: db.dbQueue).restore(
                    promptId: prompt.id,
                    versionId: source.id,
                    changeNote: note
                )
                if json {
                    try printJSON(try promptCLIRecord(restored, db: db))
                } else {
                    let active = try versionRepo.fetchActive(promptId: prompt.id)
                    print("Restored '\(prompt.name)' from v\(version) as v\(active?.versionNumber ?? 0).")
                }
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

        @Option(name: .long, help: "Assign the new prompt to this full collection UUID.")
        var collection: String?

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json = false

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
            try emitJSONOrRethrow(json: json) {
                let db = try makeDatabaseManager(database: database)
                let collectionID = try collection.map(fullPromptCollectionID)
                if let collectionID {
                    _ = try requirePromptCollection(
                        id: collectionID,
                        repository: PromptCollectionRepository(dbQueue: db.dbQueue)
                    )
                }

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
                    isAutoRun: autoRun,
                    collectionId: collectionID
                )
                let repo = PromptRepository(dbQueue: db.dbQueue)
                try repo.save(prompt)
                let saved = try repo.fetch(id: prompt.id) ?? prompt
                if json {
                    try printJSON(try promptCLIRecord(saved, db: db))
                } else {
                    print("Added prompt '\(saved.name)' (\(saved.id.uuidString.prefix(8)))")
                }
            }
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
            abstract: "Configure a prompt's visibility, auto-run, or meeting-note context."
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

        @Flag(name: .long, help: "Include meeting notes as additional context for this result prompt.")
        var includeMeetingNotes: Bool = false

        @Flag(name: .long, help: "Do not include meeting notes automatically for this result prompt.")
        var noIncludeMeetingNotes: Bool = false

        @Option(
            name: .long,
            help:
                "Scope --auto-run/--no-auto-run to one source: file, youtube, podcast, meeting. Omit for global all-source behavior."
        )
        var source: PromptAutoRunSource?

        @Option(name: .long, help: "Use this active-provider model for the prompt; creates a version.")
        var model: String?

        @Flag(name: .long, help: "Clear the prompt model override; creates a version when changed.")
        var activeModel = false

        @Option(name: .long, help: "Override sampling temperature (0...2); creates a version.")
        var temperature: Double?

        @Option(name: .long, help: "Override nucleus sampling top-p (0...1); creates a version.")
        var topP: Double?

        @Option(name: .long, help: "Override top-k (0...1000); creates a version.")
        var topK: Int?

        @Option(name: .long, help: "Override maximum output tokens (1...131072); creates a version.")
        var maxTokens: Int?

        @Option(name: .long, help: "Thinking mode: providerDefault, enabled, disabled; creates a version.")
        var thinkingMode: String?

        @Option(name: .long, help: "Reasoning effort: low, medium, high, xhigh; creates a version.")
        var reasoningEffort: String?

        @Flag(name: .long, help: "Clear all per-prompt inference settings; creates a version when changed.")
        var providerDefaultSettings = false

        @Option(name: .long, help: "Assign the prompt to this full collection UUID.")
        var collection: String?

        @Flag(name: .long, help: "Remove the prompt from its collection.")
        var noCollection = false

        @Option(name: .long, help: "Obsolete; use --label to configure active label availability.")
        var meetingType: String?

        @Flag(name: .long, help: "Obsolete; use --all-labels for the active label fallback.")
        var allMeetingTypes = false

        @Option(name: .long, help: "Configure availability for one label UUID, prefix, or name, across sources.")
        var label: String?

        @Flag(name: .long, help: "Configure the fallback when no explicit label rule matches, across sources.")
        var allLabels = false

        @Flag(name: .long, help: "Make the prompt available for the selected label policy.")
        var available = false

        @Flag(name: .long, help: "Make the prompt unavailable for the selected label policy.")
        var unavailable = false

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
            if includeMeetingNotes && noIncludeMeetingNotes {
                throw ValidationError("--include-meeting-notes and --no-include-meeting-notes are mutually exclusive")
            }
            if model != nil && activeModel {
                throw ValidationError("--model and --active-model are mutually exclusive")
            }
            if let model, model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--model must not be empty")
            }
            let hasInferenceOptions = temperature != nil || topP != nil || topK != nil
                || maxTokens != nil || thinkingMode != nil || reasoningEffort != nil
            if providerDefaultSettings && hasInferenceOptions {
                throw ValidationError("--provider-default-settings cannot be combined with inference overrides")
            }
            if collection != nil && noCollection {
                throw ValidationError("--collection and --no-collection are mutually exclusive")
            }
            if let thinkingMode,
                PromptInferenceSettings.ThinkingMode(rawValue: thinkingMode) == nil
            {
                throw ValidationError("--thinking-mode must be providerDefault, enabled, or disabled")
            }
            if let reasoningEffort,
                PromptInferenceSettings.ReasoningEffort(rawValue: reasoningEffort) == nil
            {
                throw ValidationError("--reasoning-effort must be low, medium, high, or xhigh")
            }
            do {
                _ = try PromptInferenceSettings(
                    temperature: temperature,
                    topP: topP,
                    topK: topK,
                    maxTokens: maxTokens
                ).validated()
            } catch {
                throw ValidationError("invalid inference setting: \(error)")
            }
            if meetingType != nil || allMeetingTypes {
                throw ValidationError(
                    "Meeting-type policies no longer control prompt execution. Use --label LABEL or "
                        + "--all-labels with --available/--unavailable. Configure automatic execution "
                        + "separately with --source meeting --auto-run/--no-auto-run."
                )
            }
            if label != nil && allLabels {
                throw ValidationError("--label and --all-labels are mutually exclusive")
            }
            if available && unavailable {
                throw ValidationError("--available and --unavailable are mutually exclusive")
            }
            let hasPolicyTarget = label != nil || allLabels
            if (available || unavailable) && !hasPolicyTarget {
                throw ValidationError("--available/--unavailable require --label or --all-labels")
            }
            if hasPolicyTarget {
                if visible || hidden || source != nil || autoRun || noAutoRun || model != nil || activeModel
                    || hasInferenceOptions || providerDefaultSettings
                    || includeMeetingNotes || noIncludeMeetingNotes || collection != nil || noCollection
                {
                    throw ValidationError("label availability must be configured separately from prompt settings and source auto-run")
                }
                if !(available || unavailable) {
                    throw ValidationError("a label policy requires --available or --unavailable")
                }
            }
            // Auto-run requires visible (mirrors PromptRepository.toggleAutoRun).
            // Reject the contradictory combo explicitly so the user doesn't get a
            // silent precedence surprise where one flag overrides the other.
            if hidden && autoRun {
                throw ValidationError("--hidden and --auto-run cannot be combined (auto-run requires visible)")
            }
            if source != nil {
                if visible || hidden || collection != nil || noCollection {
                    throw ValidationError(
                        "--source can only be combined with --auto-run or --no-auto-run; update collection membership separately"
                    )
                }
                if !(autoRun || noAutoRun) {
                    throw ValidationError("--source requires --auto-run or --no-auto-run")
                }
            }
            if !(visible || hidden || autoRun || noAutoRun || model != nil || activeModel
                || hasInferenceOptions || providerDefaultSettings || hasPolicyTarget
                || includeMeetingNotes || noIncludeMeetingNotes || collection != nil || noCollection)
            {
                throw ValidationError("specify at least one setting to change")
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
                let collectionChangeSpecified = collection != nil || noCollection
                let collectionID = try collection.map(fullPromptCollectionID)
                let targetCollection = try collectionID.map {
                    try requirePromptCollection(
                        id: $0,
                        repository: PromptCollectionRepository(dbQueue: db.dbQueue)
                    )
                }

                let meetingNotesFlagSpecified = includeMeetingNotes || noIncludeMeetingNotes
                var prompt: Prompt
                if meetingNotesFlagSpecified {
                    // A full UUID remains an explicit identity, even when a
                    // result happens to use that UUID as its display name.
                    if let id = UUID(uuidString: idOrName.trimmingCharacters(in: .whitespacesAndNewlines)),
                        let exact = try repo.fetch(id: id) {
                        prompt = exact
                    } else {
                        do {
                            prompt = try findPrompt(idOrName: idOrName, repo: repo, category: .result)
                        } catch CLILookupError.notFound(_) {
                            // Widen only to explain a transform-only match.
                            // Never replace an ambiguous result lookup.
                            prompt = try findPrompt(idOrName: idOrName, repo: repo, categories: [.result, .transform])
                        }
                    }
                } else {
                    prompt = try findPrompt(idOrName: idOrName, repo: repo, categories: [.result, .transform])
                }
                if meetingNotesFlagSpecified, prompt.category != .result {
                    throw ValidationError("meeting-note context is only available for result prompts")
                }

                if label != nil || allLabels {
                    guard prompt.category == .result else {
                        throw ValidationError("label policies apply only to result prompts")
                    }
                    let labelID = try label.map {
                        try findMeetingLabel(
                            $0, repo: MeetingLabelRepository(dbQueue: db.dbQueue), includeArchived: true
                        ).id
                    }
                    let policy = try PromptLabelPolicyRepository(dbQueue: db.dbQueue).setAvailability(
                        promptId: prompt.id, labelId: labelID, isAvailable: available
                    )
                    if json { try printJSON(policy) }
                    else { print("Updated label policy for '\(prompt.name)'.") }
                    return
                }

                if let model {
                    prompt.modelOverride = model.trimmingCharacters(in: .whitespacesAndNewlines)
                } else if activeModel {
                    prompt.modelOverride = nil
                }
                if providerDefaultSettings {
                    prompt.inferenceSettings = nil
                } else if temperature != nil || topP != nil || topK != nil || maxTokens != nil
                    || thinkingMode != nil || reasoningEffort != nil
                {
                    var settings = prompt.inferenceSettings ?? PromptInferenceSettings()
                    if let temperature { settings.temperature = temperature }
                    if let topP { settings.topP = topP }
                    if let topK { settings.topK = topK }
                    if let maxTokens { settings.maxTokens = maxTokens }
                    if let thinkingMode {
                        settings.thinkingMode = PromptInferenceSettings.ThinkingMode(rawValue: thinkingMode)!
                    }
                    if let reasoningEffort {
                        settings.reasoningEffort = PromptInferenceSettings.ReasoningEffort(rawValue: reasoningEffort)!
                    }
                    prompt.inferenceSettings = try settings.validated()
                }
                if let targetCollection {
                    prompt.collectionId = targetCollection.id
                } else if noCollection {
                    prompt.collectionId = nil
                }

                if let source {
                    let desiredModelOverride = prompt.modelOverride
                    let desiredInferenceSettings = prompt.inferenceSettings
                    let desiredCollectionID = prompt.collectionId
                    try repo.setAutoRun(id: prompt.id, source: source.sourceType, enabled: autoRun)
                    prompt = try repo.fetch(id: prompt.id) ?? prompt
                    if prompt.modelOverride != desiredModelOverride
                        || prompt.inferenceSettings != desiredInferenceSettings
                        || prompt.collectionId != desiredCollectionID
                    {
                        prompt.modelOverride = desiredModelOverride
                        prompt.inferenceSettings = desiredInferenceSettings
                        prompt.collectionId = desiredCollectionID
                        prompt.updatedAt = Date()
                        prompt = try PromptEditingService(dbQueue: db.dbQueue).save(prompt)
                    }
                } else if visible || hidden || autoRun || noAutoRun || model != nil || activeModel
                    || providerDefaultSettings || temperature != nil || topP != nil || topK != nil
                    || maxTokens != nil || thinkingMode != nil || reasoningEffort != nil || collectionChangeSpecified
                {
                    Self.applyFlags(
                        to: &prompt,
                        visible: visible,
                        hidden: hidden,
                        autoRun: autoRun,
                        noAutoRun: noAutoRun
                    )

                    prompt.updatedAt = Date()
                    prompt = try PromptEditingService(dbQueue: db.dbQueue).save(prompt)
                }

                if includeMeetingNotes || noIncludeMeetingNotes {
                    try repo.setIncludeMeetingNotes(id: prompt.id, enabled: includeMeetingNotes)
                    prompt = try repo.fetch(id: prompt.id) ?? prompt
                }

                if json {
                    try printJSON(try promptCLIRecord(prompt, db: db))
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
            abstract: "Soft-delete a prompt. Built-ins and custom prompts use the same lifecycle."
        )

        @Argument(help: "Prompt ID, ID prefix, or name.")
        var idOrName: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let db = try makeDatabaseManager(database: database)
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let prompt = try findPrompt(
                    idOrName: idOrName,
                    repo: repo,
                    categories: [.result, .transform]
                )
                let deleted = try PromptEditingService(dbQueue: db.dbQueue).softDelete(id: prompt.id)
                guard deleted else { throw PromptCLIError.deleteFailed(prompt.name) }
                let affected = try repo.fetchIncludingDeleted(id: prompt.id) ?? prompt
                if json {
                    try printJSON(try promptCLIRecord(affected, db: db))
                } else {
                    print("Deleted prompt '\(prompt.name)'")
                }
            }
        }
    }

    struct RestoreDeletedSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore-deleted",
            abstract: "Restore a soft-deleted prompt."
        )

        @Argument(help: "Deleted prompt UUID, UUID prefix, or exact name.") var idOrName: String
        @Flag(name: .long, help: "Emit JSON instead of human-readable output.") var json = false
        @Option(help: "Path to SQLite database file (defaults to the app database).") var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                let db = try makeDatabaseManager(database: database)
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let prompt = try findDeletedPrompt(idOrName: idOrName, repo: repo)
                let restored = try PromptEditingService(dbQueue: db.dbQueue).restoreDeleted(id: prompt.id)
                guard restored else { throw PromptCLIError.restoreFailed(prompt.name) }
                let resolved = try repo.fetch(id: prompt.id) ?? prompt
                if json { try printJSON(try promptCLIRecord(resolved, db: db)) }
                else { print("Restored prompt '\(prompt.name)'") }
            }
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

        @Flag(
            name: .long,
            help:
                "Emit a structured JSON envelope (output, provider, model, usage, stopReason, latencyMs, effectiveSettings) instead of plain text."
        )
        var json: Bool = false

        @Option(name: .long, help: "Extra instructions appended to the prompt for this run.")
        var extra: String?

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if json && stream {
                throw ValidationError(
                    "--json with --stream is not yet supported. Run without --stream for the envelope, or omit --json for token streaming."
                )
            }
        }

        func run() async throws {
            try await emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let promptRepo = PromptRepository(dbQueue: db.dbQueue)
                let transcriptionRepo = TranscriptionRepository(dbQueue: db.dbQueue)
                let resultRepo = PromptResultRepository(dbQueue: db.dbQueue)
                let speakerAttributionReader = SpeakerAttributionReadService(dbQueue: db.dbQueue)

                let prompt = try findPrompt(idOrName: promptIdOrName, repo: promptRepo)
                let automaticTranscript = try findTranscription(id: transcription, repo: transcriptionRepo)
                let projection = try speakerAttributionReader.resolve(transcription: automaticTranscript)
                let transcript = projection.effectiveTranscription

                let resolution = try PromptLabelApplicabilityResolver.resolve(
                    prompt: prompt,
                    sourceType: transcript.sourceType,
                    transcriptionLabelIDs: TranscriptionMeetingLabelRepository(dbQueue: db.dbQueue)
                        .labelIDs(for: transcript.id),
                    policies: PromptLabelPolicyRepository(dbQueue: db.dbQueue)
                        .fetchPolicies(promptId: prompt.id)
                )
                guard resolution.isAvailable else {
                    throw PromptCLIError.promptUnavailable(prompt.name, resolution.reason.rawValue)
                }

                let transcriptText = TranscriptAIContextFormatter.format(projection: projection)
                guard !transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw PromptCLIError.emptyTranscript(transcript.fileName)
                }

                let trimmedExtra = extra?.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalizedExtra = (trimmedExtra?.isEmpty == false) ? trimmedExtra : nil
                let assembly = PromptSystemPromptAssembler.assembleDetailed(
                    promptContent: prompt.content,
                    extraInstructions: normalizedExtra,
                    includeMeetingNotes: prompt.includeMeetingNotes,
                    userNotes: transcript.userNotes,
                    transcript: transcriptText
                )
                let systemPrompt = assembly.systemPrompt

                var effectiveLLM = llm
                if let modelOverride = prompt.modelOverride {
                    effectiveLLM.model = modelOverride
                }
                let execution = try effectiveLLM.buildExecutionContext()
                let service = LLMService(
                    client: execution.client,
                    contextResolver: StaticLLMExecutionContextResolver(context: execution.context)
                )

                var output = ""
                var jsonResult: LLMResult?
                var effectiveSettings: PromptInferenceSettings?
                var providerSnapshot: String?
                var modelSnapshot: String?
                if json {
                    let result = try await service.generatePromptResultDetailed(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt,
                        inferenceSettings: prompt.inferenceSettings,
                        modelOverride: prompt.modelOverride
                    )
                    output = result.output
                    jsonResult = result
                    effectiveSettings = result.effectiveSettings
                    providerSnapshot = result.provider
                    modelSnapshot = result.model
                } else if stream {
                    let eventStream = service.generatePromptResultDetailedStream(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt,
                        inferenceSettings: prompt.inferenceSettings,
                        modelOverride: prompt.modelOverride
                    )
                    var terminal: LLMStreamTerminal?
                    for try await event in eventStream {
                        switch event {
                        case .text(let token):
                            print(token, terminator: "")
                            output += token
                        case .completed(let receipt):
                            terminal = receipt
                        }
                    }
                    print()
                    guard let terminal else {
                        throw LLMError.streamingError("prompt result stream ended without terminal metadata")
                    }
                    effectiveSettings = terminal.effectiveSettings
                    providerSnapshot = terminal.provider
                    modelSnapshot = terminal.model
                } else {
                    let result = try await service.generatePromptResultDetailed(
                        transcript: transcriptText,
                        systemPrompt: systemPrompt,
                        inferenceSettings: prompt.inferenceSettings,
                        modelOverride: prompt.modelOverride
                    )
                    output = result.output
                    effectiveSettings = result.effectiveSettings
                    providerSnapshot = result.provider
                    modelSnapshot = result.model
                    print(output)
                }

                if !noStore {
                    let result = makeStoredPromptRunResult(
                        transcript: transcript,
                        prompt: prompt,
                        extraInstructions: normalizedExtra,
                        output: output,
                        userNotesSnapshot: assembly.effectiveUserNotes,
                        effectiveSettings: effectiveSettings,
                        providerSnapshot: providerSnapshot,
                        modelSnapshot: modelSnapshot
                    )
                    try resultRepo.save(result)
                    await refreshMeetingArtifacts(
                        transcriptionID: transcript.id,
                        attributionReader: speakerAttributionReader,
                        resultRepo: resultRepo,
                        db: db
                    )
                    // Status messages on stderr so stdout stays grep-able as the prompt output.
                    FileHandle.standardError.write(
                        Data("\nSaved PromptResult \(result.id.uuidString.prefix(8))\n".utf8))
                }

                if let jsonResult {
                    try printJSON(jsonResult)
                }
            }
        }
    }
}

func makeStoredPromptRunResult(
    transcript: Transcription,
    prompt: Prompt,
    extraInstructions: String?,
    output: String,
    userNotesSnapshot: String?,
    effectiveSettings: PromptInferenceSettings?,
    providerSnapshot: String? = nil,
    modelSnapshot: String? = nil
) -> PromptResult {
    PromptResult(
        transcriptionId: transcript.id,
        promptId: prompt.id,
        promptVersionId: prompt.activeVersionId,
        promptName: prompt.name,
        promptContent: prompt.content,
        extraInstructions: extraInstructions,
        content: output,
        userNotesSnapshot: userNotesSnapshot,
        includeMeetingNotesSnapshot: prompt.includeMeetingNotes,
        inferenceSettingsSnapshot: effectiveSettings,
        providerSnapshot: providerSnapshot,
        modelSnapshot: modelSnapshot
    )
}

/// Refreshes current meeting artifacts without failing an already stored prompt result.
func refreshMeetingArtifacts(
    transcriptionID: UUID,
    attributionReader: any SpeakerAttributionReading,
    resultRepo: PromptResultRepositoryProtocol,
    db: DatabaseManager
) async {
    do {
        // Provider latency may outlive edits to this meeting. The input receipt
        // stays immutable, but derived files must use the current database row.
        guard let projection = try attributionReader.resolve(transcriptionId: transcriptionID),
              projection.automaticTranscription.sourceType == .meeting
        else { return }
        let promptResults = try resultRepo.fetchAll(transcriptionId: transcriptionID)
        let classification = try MeetingClassificationService(dbQueue: db.dbQueue)
            .classification(for: transcriptionID)
        _ = try await MeetingArtifactStore().materialize(
            projection: projection,
            promptResults: promptResults,
            classification: MeetingArtifactClassificationSnapshot(classification)
        )
    } catch {
        printErr("Warning: meeting artifact refresh failed: \(error.localizedDescription)")
    }
}

// MARK: - Helpers

private func promptCollectionRepository(database: String?) throws -> PromptCollectionRepository {
    let db = try makeDatabaseManager(database: database)
    return PromptCollectionRepository(dbQueue: db.dbQueue)
}

private func fullPromptCollectionID(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        throw ValidationError("Prompt collection IDs must be full UUIDs.")
    }
    return id
}

private func requirePromptCollection(
    id: UUID,
    repository: PromptCollectionRepository
) throws -> PromptCollection {
    guard let collection = try repository.fetch(id: id) else {
        throw PromptCollectionRepositoryError.collectionNotFound(id)
    }
    return collection
}

private struct PromptCollectionDeleteResult: Encodable {
    let deleted = true
    let id: UUID
    let name: String
}

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
    if p.includeMeetingNotes { badges.append("meeting notes") }
    return badges.isEmpty ? "" : "  [\(badges.joined(separator: ", "))]"
}

private func findPromptVersion(
    number: Int,
    prompt: Prompt,
    repo: PromptVersionRepositoryProtocol
) throws -> PromptVersion {
    guard let version = try repo.fetchAll(promptId: prompt.id).first(where: { $0.versionNumber == number }) else {
        throw PromptCLIError.versionNotFound(prompt.name, number)
    }
    return version
}

private func findDeletedPrompt(idOrName: String, repo: PromptRepository) throws -> Prompt {
    let trimmed = idOrName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CLILookupError.emptyID }
    if let id = UUID(uuidString: trimmed), let prompt = try repo.fetchIncludingDeleted(id: id), prompt.deletedAt != nil {
        return prompt
    }
    let deleted = try repo.fetchDeleted().filter { [.result, .transform].contains($0.category) }
    if let prefix = uuidPrefixSearchKey(trimmed) {
        let matches = deleted.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { throw CLILookupError.ambiguous("Multiple deleted prompts match '\(trimmed)'.") }
    }
    let matches = deleted.filter { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }
    if matches.count == 1 { return matches[0] }
    if matches.count > 1 { throw CLILookupError.ambiguous("Multiple deleted prompts named '\(trimmed)'.") }
    if let error = shortUUIDPrefixErrorIfApplicable(trimmed) { throw error }
    throw CLILookupError.notFound("No deleted prompt matching '\(trimmed)'.")
}

private func printPromptVersion(_ version: PromptVersion, promptName: String) {
    print("Prompt:    \(promptName)")
    print("Version:   \(version.versionNumber)")
    print("Origin:    \(version.origin.rawValue)")
    print("Created:   \(formatPromptVersionDate(version.createdAt))")
    if let model = version.modelOverride { print("Model:     \(model)") }
    if let note = version.changeNote { print("Note:      \(note)") }
    print()
    print(version.content)
}

private func formatPromptVersionDate(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func renderPromptDiff(_ diff: PromptVersionDiff) -> String {
    var output: [String] = []
    for line in diff.markdown.lines where line.kind != .unchanged {
        switch line.kind {
        case .removed:
            output.append("-\(line.oldLineNumber ?? 0) \(line.oldText ?? "")")
        case .added:
            output.append("+\(line.newLineNumber ?? 0) \(line.newText ?? "")")
        case .modified:
            output.append("-\(line.oldLineNumber ?? 0) \(line.oldText ?? "")")
            output.append("+\(line.newLineNumber ?? 0) \(line.newText ?? "")")
        case .unchanged:
            break
        }
    }
    for change in diff.inferenceSettings {
        output.append("~ settings.\(change.field.rawValue): \(describeSetting(change.oldValue)) -> \(describeSetting(change.newValue))")
    }
    if let model = diff.modelOverride {
        output.append("~ modelOverride: \(model.oldValue ?? "default") -> \(model.newValue ?? "default")")
    }
    return output.isEmpty ? "No changes." : output.joined(separator: "\n")
}

private func describeSetting(_ value: PromptInferenceSettingValue?) -> String {
    guard let value else { return "default" }
    switch value {
    case .decimal(let value): return String(value)
    case .integer(let value): return String(value)
    case .thinkingMode(let value): return value.rawValue
    case .reasoningEffort(let value): return value.rawValue
    }
}

private struct PromptCLIRecord: Encodable {
    let id: UUID
    let name: String
    let content: String
    let category: Prompt.Category
    let isBuiltIn: Bool
    let isVisible: Bool
    let isAutoRun: Bool
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date
    let keyboardShortcut: String?
    let runningLabel: String?
    let appliesToSources: Set<Transcription.SourceType>?
    let inferenceSettings: PromptInferenceSettings?
    let includeMeetingNotes: Bool
    let activeVersionId: UUID?
    let activeVersionNumber: Int?
    let modelOverride: String?
    let canonicalKey: String?
    let lastAppliedCanonicalRevision: Int?
    let userCustomizedAt: Date?
    let deletedAt: Date?
    let collectionId: UUID?

    init(prompt: Prompt, activeVersionNumber: Int?) {
        id = prompt.id
        name = prompt.name
        content = prompt.content
        category = prompt.category
        isBuiltIn = prompt.isBuiltIn
        isVisible = prompt.isVisible
        isAutoRun = prompt.isAutoRun
        sortOrder = prompt.sortOrder
        createdAt = prompt.createdAt
        updatedAt = prompt.updatedAt
        keyboardShortcut = prompt.keyboardShortcut
        runningLabel = prompt.runningLabel
        appliesToSources = prompt.appliesToSources
        inferenceSettings = prompt.inferenceSettings
        includeMeetingNotes = prompt.includeMeetingNotes
        activeVersionId = prompt.activeVersionId
        self.activeVersionNumber = activeVersionNumber
        modelOverride = prompt.modelOverride
        canonicalKey = prompt.canonicalKey
        lastAppliedCanonicalRevision = prompt.lastAppliedCanonicalRevision
        userCustomizedAt = prompt.userCustomizedAt
        deletedAt = prompt.deletedAt
        collectionId = prompt.collectionId
    }
}

private func promptCLIRecord(_ prompt: Prompt, db: DatabaseManager) throws -> PromptCLIRecord {
    let versionNumber = try prompt.activeVersionId.flatMap {
        try PromptVersionRepository(dbQueue: db.dbQueue).fetch(id: $0)?.versionNumber
    }
    return PromptCLIRecord(prompt: prompt, activeVersionNumber: versionNumber)
}

private struct PromptDiffRecord: Encodable {
    let promptId: UUID
    let promptName: String
    let fromVersion: Int
    let toVersion: Int
    let hasChanges: Bool
    let lines: [Line]
    let inferenceSettings: [Setting]
    let modelOverride: ValueChange?

    struct Line: Encodable {
        let kind: String
        let oldLineNumber: Int?
        let newLineNumber: Int?
        let oldText: String?
        let newText: String?
    }

    struct Setting: Encodable {
        let field: String
        let oldValue: String?
        let newValue: String?
    }

    struct ValueChange: Encodable {
        let oldValue: String?
        let newValue: String?
    }

    init(prompt: Prompt, from: PromptVersion, to: PromptVersion, diff: PromptVersionDiff) {
        promptId = prompt.id
        promptName = prompt.name
        fromVersion = from.versionNumber
        toVersion = to.versionNumber
        hasChanges = diff.hasChanges
        lines = diff.markdown.lines.map {
            Line(
                kind: $0.kind.rawValue,
                oldLineNumber: $0.oldLineNumber,
                newLineNumber: $0.newLineNumber,
                oldText: $0.oldText,
                newText: $0.newText
            )
        }
        inferenceSettings = diff.inferenceSettings.map {
            Setting(
                field: $0.field.rawValue,
                oldValue: $0.oldValue.map(describeSetting),
                newValue: $0.newValue.map(describeSetting)
            )
        }
        modelOverride = diff.modelOverride.map {
            ValueChange(oldValue: $0.oldValue, newValue: $0.newValue)
        }
    }
}

private enum PromptCLIError: Error, LocalizedError {
    case deleteFailed(String)
    case restoreFailed(String)
    case versionNotFound(String, Int)
    case promptUnavailable(String, String)
    case emptyTranscript(String)

    var errorDescription: String? {
        switch self {
        case .deleteFailed(let name):
            return "Delete failed for prompt '\(name)'."
        case .restoreFailed(let name):
            return "Restore failed for prompt '\(name)'."
        case .versionNotFound(let name, let version):
            return "Prompt '\(name)' has no version \(version)."
        case .promptUnavailable(let name, let reason):
            return "Prompt '\(name)' is unavailable for this transcription (\(reason))."
        case .emptyTranscript(let fileName):
            return "Transcription '\(fileName)' has no text to run a prompt against."
        }
    }
}
