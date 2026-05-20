import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli transforms` — manage and run user-defined Transforms
/// (ADR-022) headlessly. Built so an agent operator can provision a fresh
/// device, dispatch a saved prompt against arbitrary text from CI, and
/// verify the dispatch table without launching the GUI.
///
/// Versus `llm transform --prompt "..."` (which is the raw-prompt ad-hoc
/// primitive), `transforms run <name>` invokes the **saved** prompt body
/// stored in the prompts table.
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
                let historyRepo = TransformHistoryRepository(dbQueue: db.dbQueue)
                let transform = try findTransform(idOrName: idOrName, repo: repo)

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
                    let result = try await service.transformDetailed(text: text, prompt: transform.content)
                    try saveCLITransformHistory(
                        repo: historyRepo,
                        transform: transform,
                        inputText: text,
                        outputText: result.output,
                        inputPath: input,
                        llmElapsedMs: result.latencyMs,
                        totalElapsedMs: result.latencyMs
                    )
                    try printJSON(result)
                } else if stream {
                    let startedAt = Date()
                    var output = ""
                    let tokenStream = service.transformStream(text: text, prompt: transform.content)
                    for try await token in tokenStream {
                        output += token
                        print(token, terminator: "")
                    }
                    print()
                    let elapsedMs = elapsedMilliseconds(since: startedAt)
                    try saveCLITransformHistory(
                        repo: historyRepo,
                        transform: transform,
                        inputText: text,
                        outputText: output,
                        inputPath: input,
                        llmElapsedMs: elapsedMs,
                        totalElapsedMs: elapsedMs
                    )
                } else {
                    let result = try await service.transformDetailed(text: text, prompt: transform.content)
                    try saveCLITransformHistory(
                        repo: historyRepo,
                        transform: transform,
                        inputText: text,
                        outputText: result.output,
                        inputPath: input,
                        llmElapsedMs: result.latencyMs,
                        totalElapsedMs: result.latencyMs
                    )
                    print(result.output)
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

        @Option(name: .long, help: "Transform name (must be unique across prompts).")
        var name: String

        @Option(name: .long, help: "Prompt body text. Mutually exclusive with --from-file.")
        var prompt: String?

        @Option(name: .long, help: "Path to a file containing the prompt body.")
        var fromFile: String?

        @Option(name: .long, help: "Keyboard shortcut, e.g. 'opt+1', 'cmd+shift+P'. Modifier required.")
        var shortcut: String?

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
                    keyboardShortcut: shortcutValue?.encodedString()
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
                        print("  \(singleLineHistoryPreview(entry.outputText, maxLength: 140))")
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

// MARK: - History helpers

private let transformHistoryIDPrefixMinimumLength = 4

private func transformHistoryRepo(database: String?) throws -> TransformHistoryRepository {
    try AppPaths.ensureDirectories()
    let db = try DatabaseManager(path: resolvedDatabasePath(database))
    return TransformHistoryRepository(dbQueue: db.dbQueue)
}

private func saveCLITransformHistory(
    repo: TransformHistoryRepositoryProtocol,
    transform: Prompt,
    inputText: String,
    outputText: String,
    inputPath: String,
    llmElapsedMs: Int,
    totalElapsedMs: Int
) throws {
    try repo.save(TransformHistoryEntry(
        transformId: transform.id,
        transformName: transform.name,
        inputText: inputText,
        outputText: outputText,
        sourceAppName: "macparakeet-cli",
        capturePath: inputPath == "-" ? "stdin" : "file",
        replacementPath: "stdout",
        llmElapsedMs: llmElapsedMs,
        totalElapsedMs: totalElapsedMs
    ))
}

private func elapsedMilliseconds(since startedAt: Date) -> Int {
    max(0, Int(Date().timeIntervalSince(startedAt) * 1_000))
}

private func findTransformHistoryEntry(
    idPrefix: String,
    repo: TransformHistoryRepositoryProtocol
) throws -> TransformHistoryEntry {
    let trimmed = idPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw CLITransformHistoryError.notFound(idPrefix)
    }

    if let uuid = UUID(uuidString: trimmed), let exact = try repo.fetch(id: uuid) {
        return exact
    }

    // Length and hex-character validation against the hyphenless form so
    // inputs like "12--" don't pass length-only checks then silently miss
    // and "12zz" surfaces as a clearer error than "too short".
    let normalized = trimmed.replacingOccurrences(of: "-", with: "")
    let hexCharacters = Set("0123456789abcdefABCDEF")
    let isHex = !normalized.isEmpty && normalized.allSatisfy { hexCharacters.contains($0) }
    if !isHex {
        throw CLITransformHistoryError.invalidPrefix(
            min: transformHistoryIDPrefixMinimumLength,
            provided: trimmed,
            reason: .nonHex
        )
    }
    guard normalized.count >= transformHistoryIDPrefixMinimumLength else {
        throw CLITransformHistoryError.invalidPrefix(
            min: transformHistoryIDPrefixMinimumLength,
            provided: trimmed,
            reason: .tooShort
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

private func singleLineHistoryPreview(_ text: String, maxLength: Int) -> String {
    let collapsed = text
        .replacingOccurrences(of: "\n", with: " ")
        .replacingOccurrences(of: "\t", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard collapsed.count > maxLength else { return collapsed }
    return String(collapsed.prefix(max(0, maxLength - 1))) + "..."
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

enum CLITransformHistoryError: Error, CustomStringConvertible, LocalizedError {
    case notFound(String)
    case ambiguous(String, [String])
    case invalidPrefix(min: Int, provided: String, reason: InvalidPrefixReason)
    case deleteFailed(String)

    enum InvalidPrefixReason {
        case tooShort
        case nonHex
    }

    var description: String {
        switch self {
        case .notFound(let value):
            return "No Transform history item matching '\(value)'"
        case .ambiguous(let value, let matches):
            return "Ambiguous Transform history ID '\(value)' (matches: \(matches.joined(separator: ", ")))"
        case .invalidPrefix(let min, let provided, let reason):
            switch reason {
            case .tooShort:
                return "Transform history ID prefix '\(provided)' is too short. Use at least \(min) hex characters."
            case .nonHex:
                return "Transform history ID prefix '\(provided)' contains non-hex characters. Use \(min)+ hex characters (0-9, a-f), optionally with hyphens."
            }
        case .deleteFailed(let value):
            return "Failed to delete Transform history item '\(value)'"
        }
    }

    var errorDescription: String? { description }
}

// MARK: - Lookup helper

private let transformIDPrefixMinimumLength = 4

private func findTransform(idOrName: String, repo: PromptRepository) throws -> Prompt {
    let query = idOrName.trimmingCharacters(in: .whitespacesAndNewlines)
    let all = try repo.fetchVisible(category: .transform)
    // Exact UUID match
    if let uuid = UUID(uuidString: query), let match = all.first(where: { $0.id == uuid }) {
        return match
    }
    // ID prefix. Dashes are optional. Prefix lookup intentionally precedes
    // name lookup so an ambiguous machine identifier never silently resolves
    // to a same-text custom name.
    if let prefix = normalizedUUIDPrefix(query) {
        let prefixMatches = all.filter {
            $0.id.uuidString
                .lowercased()
                .filter { $0 != "-" }
                .hasPrefix(prefix)
        }
        if prefixMatches.count == 1 {
            return prefixMatches[0]
        }
        if prefixMatches.count > 1 {
            throw CLITransformsError.ambiguous(query, prefixMatches.map(\.name))
        }
    }
    // Case-insensitive name match
    let nameMatches = all.filter { $0.name.caseInsensitiveCompare(query) == .orderedSame }
    if nameMatches.count == 1 {
        return nameMatches[0]
    }
    if nameMatches.count > 1 {
        throw CLITransformsError.ambiguous(query, nameMatches.map(\.name))
    }
    throw CLITransformsError.notFound(query)
}

private func normalizedUUIDPrefix(_ raw: String) -> String? {
    let lowercased = raw.lowercased()
    guard lowercased.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
    let normalized = lowercased.filter { $0 != "-" }
    guard normalized.count >= transformIDPrefixMinimumLength else { return nil }
    return normalized
}

// MARK: - DTO + errors

/// Snake-cased DTO for the `--json` envelope so CLI consumers don't have to
/// learn about the internal `Prompt` shape (which conflates `.result` rows
/// with this surface).
struct TransformDTO: Encodable {
    let id: String
    let name: String
    let shortcut: String?
    let isBuiltIn: Bool
    let prompt: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case shortcut
        case isBuiltIn = "is_built_in"
        case prompt
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(prompt: Prompt) {
        self.id = prompt.id.uuidString
        self.name = prompt.name
        self.shortcut = prompt.shortcut?.displayString
        self.isBuiltIn = prompt.isBuiltIn
        self.prompt = prompt.content
        self.createdAt = prompt.createdAt
        self.updatedAt = prompt.updatedAt
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
        case .shortcutConflictsWithAppHotkey(let shortcut, let name):
            return "Shortcut “\(shortcut)” conflicts with your \(name) hotkey."
        case .deleteBuiltIn(let n):
            return "Cannot delete the built-in Transform “\(n)”. Reset or edit it in the Transforms tab."
        }
    }

    var errorType: String {
        switch self {
        case .notFound, .ambiguous:
            return CLIErrorType.lookup
        case .duplicateName,
             .invalidShortcut,
             .shortcutMissingModifier,
             .shortcutMacOSDeadKey,
             .duplicateShortcut,
             .shortcutConflictsWithAppHotkey,
             .deleteBuiltIn:
            return CLIErrorType.validation
        }
    }

    var isValidationMisuse: Bool {
        switch self {
        case .notFound, .ambiguous:
            return false
        case .duplicateName,
             .invalidShortcut,
             .shortcutMissingModifier,
             .shortcutMacOSDeadKey,
             .duplicateShortcut,
             .shortcutConflictsWithAppHotkey,
             .deleteBuiltIn:
            return true
        }
    }
}

private func shortcutsMatch(_ lhs: KeyboardShortcut, _ rhs: KeyboardShortcut) -> Bool {
    lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
}

private func appHotkeyCollision(for shortcut: KeyboardShortcut) -> CLITransformsError? {
    let defaults = macParakeetAppDefaults()
    let candidate = shortcut.hotkeyTrigger
    let reservedHotkeys: [(name: String, trigger: HotkeyTrigger)] = [
        (
            "hands-free dictation",
            HotkeyTrigger.current(defaults: defaults)
        ),
        (
            "push-to-talk",
            HotkeyTrigger.current(
                defaults: defaults,
                defaultsKey: HotkeyTrigger.pushToTalkDefaultsKey,
                fallback: .defaultPushToTalk
            )
        ),
        (
            "meeting recording",
            HotkeyTrigger.current(
                defaults: defaults,
                defaultsKey: HotkeyTrigger.meetingDefaultsKey,
                fallback: .defaultMeetingRecording
            )
        ),
        (
            "file transcription",
            HotkeyTrigger.current(
                defaults: defaults,
                defaultsKey: HotkeyTrigger.fileTranscriptionDefaultsKey,
                fallback: .disabled
            )
        ),
        (
            "YouTube transcription",
            HotkeyTrigger.current(
                defaults: defaults,
                defaultsKey: HotkeyTrigger.youtubeTranscriptionDefaultsKey,
                fallback: .disabled
            )
        ),
    ]
    for reserved in reservedHotkeys where !reserved.trigger.isDisabled {
        if candidate.overlaps(with: reserved.trigger) {
            return .shortcutConflictsWithAppHotkey(shortcut.displayString, reserved.name)
        }
    }

    return nil
}
