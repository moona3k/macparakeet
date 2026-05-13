import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli transforms` — manage and run user-defined Transforms
/// (ADR-022) headlessly. Built so an agent operator can provision a fresh
/// device, dispatch a saved prompt against arbitrary text from CI, and
/// verify the dispatch table without launching the GUI.
///
/// Versus `llm transform --prompt "..."` (which is the raw-prompt ad-hoc
/// primitive), `transforms run <name>` invokes the effective saved Transform:
/// prompt body plus workbench rules, custom instructions, and enabled writing
/// samples.
struct TransformsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transforms",
        abstract: "Manage and run user-defined Transforms (saved prompt + hotkey rewrite shortcuts).",
        subcommands: [
            ListSubcommand.self,
            ShowSubcommand.self,
            RunSubcommand.self,
            CreateSubcommand.self,
            DeleteSubcommand.self,
            HistorySubcommand.self,
        ],
        defaultSubcommand: ListSubcommand.self
    )
}

// MARK: - List

extension TransformsCommand {
    struct ListSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List Transforms with their bound shortcuts."
        )

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let transforms = try repo
                    .fetchVisible(category: .transform)
                    .sorted(by: { $0.sortOrder < $1.sortOrder })

                if json {
                    try printJSON(transforms.map(TransformDTO.init(prompt:)))
                    return
                }

                if transforms.isEmpty {
                    print("No Transforms found.")
                    return
                }

                for t in transforms {
                    let badge = t.isBuiltIn ? " [built-in]" : ""
                    let shortcut = t.shortcut?.displayString ?? "—"
                    print("\(t.id.uuidString.prefix(8))  \(shortcut.padding(toLength: 12, withPad: " ", startingAt: 0))  \(t.name)\(badge)")
                }
                print()
                print("\(transforms.count) Transform(s)")
            }
        }
    }
}

// MARK: - Show

extension TransformsCommand {
    struct ShowSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a Transform's full prompt body and bound shortcut."
        )

        @Argument(help: "Transform ID, ID prefix, or name.")
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
                let transform = try findTransform(idOrName: idOrName, repo: repo)

                if json {
                    try printJSON(TransformDTO(prompt: transform))
                    return
                }

                print("ID:        \(transform.id.uuidString)")
                print("Name:      \(transform.name)\(transform.isBuiltIn ? " [built-in]" : "")")
                print("Shortcut:  \(transform.shortcut?.displayString ?? "—")")
                print("Running:   \(transform.derivedRunningLabel)")
                print("Updated:   \(ISO8601DateFormatter().string(from: transform.updatedAt))")
                print()
                print(transform.content)
            }
        }
    }
}

// MARK: - Run

extension TransformsCommand {
    struct RunSubcommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a saved Transform against text from a file or stdin."
        )

        @OptionGroup var llm: LLMInlineOptions

        @Argument(help: "Transform ID, ID prefix, or name.")
        var idOrName: String

        @Option(name: .shortAndLong, help: "Path to text file to transform. Use '-' for stdin.")
        var input: String

        @Flag(name: .long, help: "Stream the response token by token. Incompatible with --json.")
        var stream: Bool = false

        @Flag(name: .long, help: "Emit a structured JSON envelope instead of plain text.")
        var json: Bool = false

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
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let profileRepo = TransformProfileRepository(dbQueue: db.dbQueue)
                let writingSampleRepo = WritingSampleRepository(dbQueue: db.dbQueue)
                let transform = try findTransform(idOrName: idOrName, repo: repo)
                let prompt = try assembledTransformPrompt(
                    transform: transform,
                    profileRepo: profileRepo,
                    writingSampleRepo: writingSampleRepo
                )

                let text = try readInput(input)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw CLIInputError.empty
                }

                let execution = try llm.buildExecutionContext()
                let service = LLMService(
                    client: execution.client,
                    contextResolver: StaticLLMExecutionContextResolver(context: execution.context)
                )

                if json {
                    let result = try await service.transformDetailed(text: text, prompt: prompt)
                    try printJSON(result)
                } else if stream {
                    let tokenStream = service.transformStream(text: text, prompt: prompt)
                    for try await token in tokenStream {
                        print(token, terminator: "")
                    }
                    print()
                } else {
                    print(try await service.transform(text: text, prompt: prompt))
                }
            }
        }
    }
}

// MARK: - Create

extension TransformsCommand {
    struct CreateSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create",
            abstract: "Headless-install a new Transform with an optional bound shortcut."
        )

        @Option(name: .long, help: "Transform name (must be unique across Transforms).")
        var name: String

        @Option(name: .long, help: "Prompt body text. Mutually exclusive with --from-file.")
        var prompt: String?

        @Option(name: .long, help: "Path to a file containing the prompt body.")
        var fromFile: String?

        @Option(name: .long, help: "Keyboard shortcut, e.g. 'opt+1', 'cmd+shift+P'. Modifier required.")
        var shortcut: String?

        @Option(name: .long, help: "Optional running-pill label. Defaults to a 'Naming…' heuristic.")
        var runningLabel: String?

        @Flag(name: .long, help: "Emit a JSON envelope on success.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if prompt != nil && fromFile != nil {
                throw ValidationError("--prompt and --from-file are mutually exclusive.")
            }
            if prompt == nil && fromFile == nil {
                throw ValidationError("Provide a prompt body via --prompt or --from-file.")
            }
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--name must not be empty.")
            }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)

                let body: String
                if let p = prompt {
                    body = p
                } else if let path = fromFile {
                    body = try String(contentsOfFile: path, encoding: .utf8)
                } else {
                    throw ValidationError("Provide a prompt body via --prompt or --from-file.")
                }

                let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

                let existing = try repo.fetchAll()
                if existing.contains(where: { $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
                    throw CLITransformsError.duplicateName(trimmedName)
                }

                let shortcutValue: KeyboardShortcut?
                if let s = shortcut {
                    guard let parsed = KeyboardShortcut.parse(s) else {
                        throw CLITransformsError.invalidShortcut(s)
                    }
                    guard parsed.hasModifier else {
                        throw CLITransformsError.shortcutMissingModifier
                    }
                    guard !parsed.isMacOSDeadKey else {
                        throw CLITransformsError.shortcutMacOSDeadKey
                    }
                    if let duplicate = existing.first(where: { prompt in
                        guard prompt.category == .transform,
                              let shortcut = prompt.shortcut
                        else { return false }
                        return shortcutsMatch(shortcut, parsed)
                    }) {
                        throw CLITransformsError.duplicateShortcut(
                            parsed.displayString,
                            duplicate.name
                        )
                    }
                    let appHotkeyCollision = appHotkeyCollision(for: parsed)
                    if let appHotkeyCollision {
                        throw appHotkeyCollision
                    }
                    shortcutValue = parsed
                } else {
                    shortcutValue = nil
                }

                let now = Date()
                let transform = Prompt(
                    id: UUID(),
                    name: trimmedName,
                    content: body,
                    category: .transform,
                    isBuiltIn: false,
                    isVisible: true,
                    isAutoRun: false,
                    sortOrder: 200,
                    createdAt: now,
                    updatedAt: now,
                    keyboardShortcut: shortcutValue?.encodedString(),
                    runningLabel: runningLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
                )
                try repo.save(transform)

                if json {
                    try printJSON(TransformDTO(prompt: transform))
                } else {
                    print("Created Transform \(transform.id.uuidString.prefix(8))  \(transform.name)")
                    if let shortcutValue {
                        print("Bound to \(shortcutValue.displayString)")
                    } else {
                        print("Dormant (no shortcut bound)")
                    }
                }
            }
        }
    }
}

// MARK: - Delete

extension TransformsCommand {
    struct DeleteSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a custom Transform. Built-ins are protected."
        )

        @Argument(help: "Transform ID, ID prefix, or name.")
        var idOrName: String

        @Flag(name: .long, help: "Emit a JSON envelope on success.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = PromptRepository(dbQueue: db.dbQueue)
                let transform = try findTransform(idOrName: idOrName, repo: repo)

                if transform.isBuiltIn {
                    throw CLITransformsError.deleteBuiltIn(transform.name)
                }

                let deleted = try repo.delete(id: transform.id)
                guard deleted else {
                    throw CLITransformsError.notFound(idOrName)
                }

                if json {
                    struct DeleteResult: Encodable { let deleted: Bool; let id: String; let name: String }
                    try printJSON(DeleteResult(deleted: true, id: transform.id.uuidString, name: transform.name))
                } else {
                    print("Deleted Transform \(transform.id.uuidString.prefix(8))  \(transform.name)")
                }
            }
        }
    }
}

// MARK: - History

extension TransformsCommand {
    struct HistorySubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "history",
            abstract: "Inspect and manage local Transform history.",
            subcommands: [
                ListSubcommand.self,
                ShowSubcommand.self,
                DeleteSubcommand.self,
                ClearSubcommand.self,
            ],
            defaultSubcommand: ListSubcommand.self
        )

        struct ListSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "list",
                abstract: "List saved Transform runs, newest first."
            )

            @Option(help: "Maximum number of history rows to print.")
            var limit: Int = 20

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func validate() throws {
                guard limit > 0 else {
                    throw ValidationError("--limit must be greater than zero.")
                }
            }

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let repo = try transformHistoryRepo(database: database)
                    let entries = try repo.fetchRecent(limit: limit)

                    if json {
                        try printJSON(entries.map(TransformHistoryDTO.init(entry:)))
                        return
                    }

                    if entries.isEmpty {
                        print("No Transform history found.")
                        return
                    }

                    let formatter = ISO8601DateFormatter()
                    for entry in entries {
                        print("\(entry.id.uuidString.prefix(8))  \(formatter.string(from: entry.createdAt))  \(entry.transformName)  \(entry.sourceAppDisplayName)")
                        print("  \(singleLinePreview(entry.outputText, maxLength: 140))")
                    }
                    print()
                    print("\(entries.count) Transform history item(s)")
                }
            }
        }

        struct ShowSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "show",
                abstract: "Show one saved Transform run."
            )

            @Argument(help: "History item ID or ID prefix.")
            var idPrefix: String

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let repo = try transformHistoryRepo(database: database)
                    let entry = try findTransformHistoryEntry(idPrefix: idPrefix, repo: repo)

                    if json {
                        try printJSON(TransformHistoryDTO(entry: entry))
                        return
                    }

                    let formatter = ISO8601DateFormatter()
                    print("ID:           \(entry.id.uuidString)")
                    print("Transform:    \(entry.transformName)")
                    if let transformId = entry.transformId {
                        print("Transform ID: \(transformId.uuidString)")
                    }
                    print("Source app:   \(entry.sourceAppDisplayName)")
                    print("Capture:      \(entry.capturePath)")
                    print("Replacement:  \(entry.replacementPath)")
                    print("LLM:          \(entry.llmElapsedMs)ms")
                    print("Total:        \(entry.totalElapsedMs)ms")
                    print("Created:      \(formatter.string(from: entry.createdAt))")
                    print()
                    print("Input:")
                    print(entry.inputText)
                    print()
                    print("Output:")
                    print(entry.outputText)
                }
            }
        }

        struct DeleteSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "delete",
                abstract: "Delete one saved Transform history item."
            )

            @Argument(help: "History item ID or ID prefix.")
            var idPrefix: String

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let repo = try transformHistoryRepo(database: database)
                    let entry = try findTransformHistoryEntry(idPrefix: idPrefix, repo: repo)
                    guard try repo.delete(id: entry.id) else {
                        throw CLITransformHistoryError.deleteFailed(entry.id.uuidString)
                    }

                    if json {
                        try printJSON(TransformHistoryDeleteResult(ok: true, id: entry.id.uuidString))
                    } else {
                        print("Deleted Transform history item \(entry.id.uuidString.prefix(8))")
                    }
                }
            }
        }

        struct ClearSubcommand: ParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "clear",
                abstract: "Clear all local Transform history."
            )

            @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
            var json: Bool = false

            @Option(help: "Path to SQLite database file (defaults to the app database).")
            var database: String?

            func run() throws {
                try emitJSONOrRethrow(json: json) {
                    let repo = try transformHistoryRepo(database: database)
                    let deletedCount = try repo.count()
                    try repo.deleteAll()

                    if json {
                        try printJSON(TransformHistoryClearResult(ok: true, deletedCount: deletedCount))
                    } else {
                        print("Cleared \(deletedCount) Transform history item(s)")
                    }
                }
            }
        }
    }
}

// MARK: - Lookup helper

private func findTransform(idOrName: String, repo: PromptRepository) throws -> Prompt {
    let all = try repo.fetchVisible(category: .transform)
    // Exact UUID match
    if let uuid = UUID(uuidString: idOrName), let match = all.first(where: { $0.id == uuid }) {
        return match
    }
    // ID prefix
    let prefix = idOrName.lowercased()
    let prefixMatches = all.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
    if prefixMatches.count == 1 {
        return prefixMatches[0]
    }
    if prefixMatches.count > 1 {
        throw CLITransformsError.ambiguous(idOrName, prefixMatches.map(\.name))
    }
    // Case-insensitive name match
    if let nameMatch = all.first(where: { $0.name.caseInsensitiveCompare(idOrName) == .orderedSame }) {
        return nameMatch
    }
    throw CLITransformsError.notFound(idOrName)
}

private func transformHistoryRepo(database: String?) throws -> TransformHistoryRepository {
    try AppPaths.ensureDirectories()
    let db = try DatabaseManager(path: resolvedDatabasePath(database))
    return TransformHistoryRepository(dbQueue: db.dbQueue)
}

private let transformHistoryIDPrefixMinimumLength = 4

private func findTransformHistoryEntry(idPrefix: String, repo: TransformHistoryRepositoryProtocol) throws -> TransformHistoryEntry {
    let trimmed = idPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw CLITransformHistoryError.notFound(idPrefix)
    }

    if let uuid = UUID(uuidString: trimmed), let exact = try repo.fetch(id: uuid) {
        return exact
    }

    guard trimmed.count >= transformHistoryIDPrefixMinimumLength else {
        throw CLITransformHistoryError.prefixTooShort(
            min: transformHistoryIDPrefixMinimumLength,
            provided: trimmed
        )
    }

    let matches = try repo.fetch(idPrefix: trimmed)
    if matches.count == 1 {
        return matches[0]
    }
    if matches.count > 1 {
        throw CLITransformHistoryError.ambiguous(trimmed, matches.map { String($0.id.uuidString.prefix(8)) })
    }
    throw CLITransformHistoryError.notFound(trimmed)
}

private func singleLinePreview(_ text: String, maxLength: Int) -> String {
    let collapsed = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > maxLength else { return collapsed }
    return String(collapsed.prefix(max(0, maxLength - 1))) + "..."
}

func assembledTransformPrompt(
    transform: Prompt,
    profileRepo: TransformProfileRepositoryProtocol,
    writingSampleRepo: WritingSampleRepositoryProtocol
) throws -> String {
    let profile = try profileRepo.fetch(promptId: transform.id)
    let samples = profile?.useWritingSamples == true ? try writingSampleRepo.fetchAll() : []
    return TransformPromptAssembler.assemble(
        prompt: transform,
        profile: profile,
        writingSamples: samples
    )
}

// MARK: - DTO + errors

/// Snake-cased DTO for the `--json` envelope so CLI consumers don't have to
/// learn about the internal `Prompt` shape (which conflates `.result` rows
/// with this surface).
struct TransformDTO: Encodable {
    let id: String
    let name: String
    let shortcut: String?
    let runningLabel: String?
    let isBuiltIn: Bool
    let prompt: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortcut
        case runningLabel = "running_label"
        case isBuiltIn = "is_built_in"
        case prompt
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(prompt: Prompt) {
        self.id = prompt.id.uuidString
        self.name = prompt.name
        self.shortcut = prompt.shortcut?.displayString
        self.runningLabel = prompt.runningLabel
        self.isBuiltIn = prompt.isBuiltIn
        self.prompt = prompt.content
        self.createdAt = prompt.createdAt
        self.updatedAt = prompt.updatedAt
    }
}

struct TransformHistoryDTO: Encodable {
    let id: String
    let transformId: String?
    let transformName: String
    let inputText: String
    let outputText: String
    let sourceAppBundleID: String?
    let sourceAppName: String?
    let capturePath: String
    let replacementPath: String
    let llmElapsedMs: Int
    let totalElapsedMs: Int
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case transformId = "transform_id"
        case transformName = "transform_name"
        case inputText = "input_text"
        case outputText = "output_text"
        case sourceAppBundleID = "source_app_bundle_id"
        case sourceAppName = "source_app_name"
        case capturePath = "capture_path"
        case replacementPath = "replacement_path"
        case llmElapsedMs = "llm_elapsed_ms"
        case totalElapsedMs = "total_elapsed_ms"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(entry: TransformHistoryEntry) {
        id = entry.id.uuidString
        transformId = entry.transformId?.uuidString
        transformName = entry.transformName
        inputText = entry.inputText
        outputText = entry.outputText
        sourceAppBundleID = entry.sourceAppBundleID
        sourceAppName = entry.sourceAppName
        capturePath = entry.capturePath
        replacementPath = entry.replacementPath
        llmElapsedMs = entry.llmElapsedMs
        totalElapsedMs = entry.totalElapsedMs
        createdAt = entry.createdAt
        updatedAt = entry.updatedAt
    }
}

struct TransformHistoryDeleteResult: Encodable {
    let ok: Bool
    let id: String
}

struct TransformHistoryClearResult: Encodable {
    let ok: Bool
    let deletedCount: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case deletedCount = "deleted_count"
    }
}

enum CLITransformsError: Error, CustomStringConvertible {
    case notFound(String)
    case ambiguous(String, [String])
    case duplicateName(String)
    case invalidShortcut(String)
    case shortcutMissingModifier
    case shortcutMacOSDeadKey
    case duplicateShortcut(String, String)
    case shortcutConflictsWithDictation(String)
    case shortcutConflictsWithMeeting(String)
    case shortcutConflictsWithAppHotkey(String, String)
    case deleteBuiltIn(String)

    var description: String {
        switch self {
        case .notFound(let q):
            return "No Transform found matching “\(q)”."
        case .ambiguous(let q, let names):
            return "“\(q)” matches multiple Transforms: \(names.joined(separator: ", ")). Use a longer ID prefix."
        case .duplicateName(let n):
            return "A prompt named “\(n)” already exists."
        case .invalidShortcut(let s):
            return "Couldn't parse shortcut “\(s)”. Try forms like 'opt+1', 'cmd+shift+P', 'ctrl+opt+space'."
        case .shortcutMissingModifier:
            return "Shortcut must include a modifier key (cmd, opt, ctrl, or shift)."
        case .shortcutMacOSDeadKey:
            return "This shortcut produces a special character on Mac. Pick another combo."
        case .duplicateShortcut(let shortcut, let name):
            return "Shortcut “\(shortcut)” is already used by Transform “\(name)”."
        case .shortcutConflictsWithDictation(let shortcut):
            return "Shortcut “\(shortcut)” conflicts with your dictation hotkey."
        case .shortcutConflictsWithMeeting(let shortcut):
            return "Shortcut “\(shortcut)” conflicts with your meeting recording hotkey."
        case .shortcutConflictsWithAppHotkey(let shortcut, let name):
            return "Shortcut “\(shortcut)” conflicts with your \(name) hotkey."
        case .deleteBuiltIn(let n):
            return "Cannot delete the built-in Transform “\(n)”. Reset it via the GUI or override its prompt body with `transforms create --name ...`."
        }
    }
}

enum CLITransformHistoryError: Error, CustomStringConvertible, LocalizedError {
    case notFound(String)
    case ambiguous(String, [String])
    case prefixTooShort(min: Int, provided: String)
    case deleteFailed(String)

    var description: String {
        switch self {
        case .notFound(let value):
            return "No Transform history item matching '\(value)'"
        case .ambiguous(let value, let matches):
            return "Ambiguous Transform history ID '\(value)' (matches: \(matches.joined(separator: ", ")))"
        case .prefixTooShort(let min, let provided):
            return "Transform history ID prefix '\(provided)' is too short. Use at least \(min) characters."
        case .deleteFailed(let value):
            return "Failed to delete Transform history item '\(value)'"
        }
    }

    var errorDescription: String? { description }
}

private func shortcutsMatch(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
    lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
}

private func appHotkeyCollision(for shortcut: KeyboardShortcut) -> CLITransformsError? {
    let defaults = macParakeetAppDefaults()
    let candidate = shortcut.hotkeyTrigger
    let reservedHotkeys: [(name: String, trigger: HotkeyTrigger)] = [
        ("dictation", HotkeyTrigger.current(defaults: defaults)),
        ("push-to-talk", HotkeyTrigger.current(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey,
            fallback: .defaultPushToTalk
        )),
        ("meeting recording", HotkeyTrigger.current(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.meetingDefaultsKey,
            fallback: .defaultMeetingRecording
        )),
        ("file transcription", HotkeyTrigger.current(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.fileTranscriptionDefaultsKey,
            fallback: .disabled
        )),
        ("YouTube transcription", HotkeyTrigger.current(
            defaults: defaults,
            defaultsKey: HotkeyTrigger.youtubeTranscriptionDefaultsKey,
            fallback: .disabled
        )),
    ]
    if let match = reservedHotkeys.first(where: { !$0.trigger.isDisabled && candidate.overlaps(with: $0.trigger) }) {
        return .shortcutConflictsWithAppHotkey(shortcut.displayString, match.name)
    }

    return nil
}
