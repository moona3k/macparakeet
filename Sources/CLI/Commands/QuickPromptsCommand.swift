import ArgumentParser
import Foundation
import MacParakeetCore

/// `macparakeet-cli quick-prompts` — manage the live meeting Ask tab pills
/// (starter and follow-up prompts). Mirrors `prompts` shape for familiarity,
/// adds `export` / `import` for portable JSON round-tripping (versioned wire
/// format; see `QuickPromptBundle`).
struct QuickPromptsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "quick-prompts",
        abstract: "Manage the live meeting Ask tab pills (starter + follow-up).",
        subcommands: [
            ListSubcommand.self,
            ShowSubcommand.self,
            AddSubcommand.self,
            SetSubcommand.self,
            DeleteSubcommand.self,
            RestoreDefaultsSubcommand.self,
            ExportSubcommand.self,
            ImportSubcommand.self,
        ],
        defaultSubcommand: ListSubcommand.self
    )
}

// MARK: - Shared

enum QuickPromptKindArg: String, ExpressibleByArgument {
    case starter
    case followUp = "follow-up"

    var domain: QuickPrompt.Kind {
        switch self {
        case .starter:  return .starter
        case .followUp: return .followUp
        }
    }
}

/// Resolve a quick prompt by exact UUID, UUID prefix, or case-insensitive label.
/// Names are checked only after no UUID-prefix match was found, mirroring
/// `findPrompt`. Throws `CLILookupError` on miss / ambiguity.
func findQuickPrompt(idOrLabel: String, repo: QuickPromptRepository) throws -> QuickPrompt {
    let trimmed = idOrLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CLILookupError.emptyID }

    if let uuid = UUID(uuidString: trimmed), let p = try repo.fetch(id: uuid) {
        return p
    }

    let all = try repo.fetchAll()
    let lowered = trimmed.lowercased()

    if let prefix = quickPromptUUIDPrefixSearchKey(trimmed) {
        let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw CLILookupError.ambiguous("Multiple quick prompts match '\(trimmed)' as ID prefix. Be more specific.")
        }
    }

    let labelMatches = all.filter { $0.label.lowercased() == lowered }
    if labelMatches.count == 1 { return labelMatches[0] }
    if labelMatches.count > 1 {
        throw CLILookupError.ambiguous("Multiple quick prompts labeled '\(trimmed)'. Use ID instead.")
    }
    if let error = quickPromptShortPrefixErrorIfApplicable(trimmed) { throw error }

    throw CLILookupError.notFound("No quick prompt matching '\(trimmed)'")
}

private func quickPromptUUIDPrefixSearchKey(_ value: String) -> String? {
    let lowered = value.lowercased()
    guard lowered.count >= 4,
          lowered.allSatisfy({ $0 == "-" || $0.isHexDigit })
    else { return nil }
    return lowered
}

private func quickPromptShortPrefixErrorIfApplicable(_ value: String) -> CLILookupError? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.count < 4,
          trimmed.allSatisfy({ $0 == "-" || $0.isHexDigit })
    else { return nil }
    return .shortUUIDPrefix(minimumLength: 4)
}

private func renderBadges(_ p: QuickPrompt) -> String {
    var badges: [String] = ["\(p.kind.rawValue)"]
    if p.isBuiltIn { badges.append("built-in") }
    if !p.isVisible { badges.append("hidden") }
    if let group = p.groupLabel { badges.append("group: \(group)") }
    return "  [\(badges.joined(separator: ", "))]"
}

private struct QuickPromptWriteResult: Encodable {
    let ok: Bool
    let prompt: QuickPrompt
}

enum QuickPromptCLIError: Error, LocalizedError {
    case cannotDeleteBuiltIn(String)
    case deleteFailed(String)
    case emptyBody
    case readFailed(String, underlying: Error)
    case writeFailed(String, underlying: Error)
    case importSchemaError(String)
    case importCancelled

    var errorDescription: String? {
        switch self {
        case .cannotDeleteBuiltIn(let label):
            return "Cannot delete built-in quick prompt '\(label)'. Use `quick-prompts set <id> --hidden` to hide it instead."
        case .deleteFailed(let label):
            return "Delete failed for quick prompt '\(label)'."
        case .emptyBody:
            return "Prompt body is empty (provide --prompt, --from-file, or pipe via stdin)."
        case .readFailed(let path, let underlying):
            return "Failed to read '\(path)': \(underlying.localizedDescription)"
        case .writeFailed(let path, let underlying):
            return "Failed to write '\(path)': \(underlying.localizedDescription)"
        case .importSchemaError(let message):
            return "Import schema error: \(message)"
        case .importCancelled:
            return "Import cancelled."
        }
    }
}

// MARK: - List

extension QuickPromptsCommand {
    struct ListSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list",
            abstract: "List quick prompts."
        )

        @Option(name: .long, help: "Filter by kind: starter or follow-up.")
        var kind: QuickPromptKindArg?

        @Flag(name: .long, help: "Only visible prompts.")
        var visibleOnly: Bool = false

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = QuickPromptRepository(dbQueue: db.dbQueue)

                var prompts: [QuickPrompt]
                if let kind = kind?.domain {
                    prompts = visibleOnly
                        ? try repo.fetchVisible(kind: kind)
                        : try repo.fetchAll(kind: kind)
                } else {
                    prompts = try repo.fetchAll()
                    if visibleOnly { prompts = prompts.filter { $0.isVisible } }
                }

                if json {
                    try printJSON(prompts)
                    return
                }

                if prompts.isEmpty {
                    print("No quick prompts found.")
                    return
                }
                for p in prompts {
                    print("\(p.id.uuidString.prefix(8))  \(p.label)\(renderBadges(p))")
                }
                print()
                print("\(prompts.count) quick prompt(s)")
            }
        }
    }
}

// MARK: - Show

extension QuickPromptsCommand {
    struct ShowSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "show",
            abstract: "Show a quick prompt's full content."
        )

        @Argument(help: "Quick prompt ID, ID prefix, or label.")
        var idOrLabel: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = QuickPromptRepository(dbQueue: db.dbQueue)
                let p = try findQuickPrompt(idOrLabel: idOrLabel, repo: repo)

                if json {
                    try printJSON(p)
                    return
                }

                print("ID:        \(p.id.uuidString)")
                print("Kind:      \(p.kind.rawValue)")
                print("Label:     \(p.label)\(renderBadges(p))")
                if let group = p.groupLabel { print("Group:     \(group)") }
                print("Updated:   \(ISO8601DateFormatter().string(from: p.updatedAt))")
                print()
                print(p.prompt)
            }
        }
    }
}

// MARK: - Add

extension QuickPromptsCommand {
    struct AddSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a custom quick prompt."
        )

        @Option(name: .long, help: "Pill kind: starter or follow-up.")
        var kind: QuickPromptKindArg

        @Option(name: .long, help: "Display label shown on the pill (short).")
        var label: String

        @Option(name: .long, help: "Full prompt body sent to the LLM. Mutually exclusive with --from-file.")
        var prompt: String?

        @Option(name: .long, help: "Path to a file containing the prompt body.")
        var fromFile: String?

        @Option(name: .long, help: "Optional group label (starters only — e.g. CATCH UP, CAPTURE, CHALLENGE).")
        var group: String?

        @Flag(name: .long, help: "Insert as hidden (visibility off).")
        var hidden: Bool = false

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if prompt != nil && fromFile != nil {
                throw ValidationError("--prompt and --from-file are mutually exclusive")
            }
            if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--label must not be empty")
            }
            if kind.domain == .followUp && group != nil {
                throw ValidationError("--group is only valid for starter prompts")
            }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = QuickPromptRepository(dbQueue: db.dbQueue)

                let body: String
                if let prompt {
                    body = prompt
                } else if let fromFile {
                    do {
                        body = try String(contentsOfFile: expandTilde(fromFile), encoding: .utf8)
                    } catch {
                        throw QuickPromptCLIError.readFailed(fromFile, underlying: error)
                    }
                } else {
                    let data = FileHandle.standardInput.readDataToEndOfFile()
                    body = String(data: data, encoding: .utf8) ?? ""
                }
                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw QuickPromptCLIError.emptyBody
                }

                let nextSortOrder: Int = {
                    let existing = (try? repo.fetchAll(kind: kind.domain)) ?? []
                    return (existing.map(\.sortOrder).max() ?? -1) + 1
                }()

                let normalizedGroup: String? = {
                    guard let raw = group else { return nil }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }()

                let p = QuickPrompt(
                    kind: kind.domain,
                    label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                    prompt: body,
                    groupLabel: normalizedGroup,
                    sortOrder: nextSortOrder,
                    isVisible: !hidden,
                    isBuiltIn: false
                )
                try repo.save(p)

                if json {
                    try printJSON(QuickPromptWriteResult(ok: true, prompt: p))
                } else {
                    print("Added quick prompt '\(p.label)' (\(p.id.uuidString.prefix(8)))")
                }
            }
        }
    }
}

// MARK: - Set

extension QuickPromptsCommand {
    struct SetSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "set",
            abstract: "Update a quick prompt's fields or visibility."
        )

        @Argument(help: "Quick prompt ID, ID prefix, or label.")
        var idOrLabel: String

        @Option(name: .long, help: "Replace the display label.")
        var label: String?

        @Option(name: .long, help: "Replace the prompt body.")
        var prompt: String?

        @Option(name: .long, help: "Replace the group label (starters only). Pass empty string to clear.")
        var group: String?

        @Option(name: .long, help: "Replace the sort order (integer; lower = earlier).")
        var sortOrder: Int?

        @Flag(name: .long, help: "Make visible.")
        var visible: Bool = false

        @Flag(name: .long, help: "Hide.")
        var hidden: Bool = false

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if visible && hidden {
                throw ValidationError("--visible and --hidden are mutually exclusive")
            }
            if let label, label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--label must not be empty")
            }
            if let prompt, prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ValidationError("--prompt must not be empty")
            }
            if label == nil && prompt == nil && group == nil && sortOrder == nil && !visible && !hidden {
                throw ValidationError("specify at least one field to change (--label / --prompt / --group / --sort-order / --visible / --hidden)")
            }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = QuickPromptRepository(dbQueue: db.dbQueue)

                var p = try findQuickPrompt(idOrLabel: idOrLabel, repo: repo)
                if group != nil && p.kind == .followUp {
                    throw ValidationError("--group is only valid for starter prompts")
                }

                if let label {
                    p.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                if let prompt {
                    p.prompt = prompt
                }
                if let group {
                    let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
                    p.groupLabel = trimmed.isEmpty ? nil : trimmed
                }
                if let sortOrder {
                    p.sortOrder = sortOrder
                }
                if visible { p.isVisible = true }
                if hidden  { p.isVisible = false }

                p.updatedAt = Date()
                try repo.save(p)

                if json {
                    try printJSON(QuickPromptWriteResult(ok: true, prompt: p))
                } else {
                    print("Updated '\(p.label)':\(renderBadges(p))")
                }
            }
        }
    }
}

// MARK: - Delete

extension QuickPromptsCommand {
    struct DeleteSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "delete",
            abstract: "Delete a custom quick prompt (built-ins cannot be deleted)."
        )

        @Argument(help: "Quick prompt ID, ID prefix, or label.")
        var idOrLabel: String

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = QuickPromptRepository(dbQueue: db.dbQueue)

                let p = try findQuickPrompt(idOrLabel: idOrLabel, repo: repo)
                if p.isBuiltIn {
                    throw QuickPromptCLIError.cannotDeleteBuiltIn(p.label)
                }
                let deleted = try repo.delete(id: p.id)
                guard deleted else { throw QuickPromptCLIError.deleteFailed(p.label) }

                if json {
                    struct DeleteResult: Encodable { let ok: Bool; let id: UUID; let label: String }
                    try printJSON(DeleteResult(ok: true, id: p.id, label: p.label))
                } else {
                    print("Deleted quick prompt '\(p.label)'")
                }
            }
        }
    }
}

// MARK: - Restore Defaults

extension QuickPromptsCommand {
    struct RestoreDefaultsSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore-defaults",
            abstract: "Reset built-in quick prompts to canonical values (preserves visibility, leaves customs alone)."
        )

        @Option(name: .long, help: "Limit restore to one kind: starter or follow-up.")
        var kind: QuickPromptKindArg?

        @Option(name: .long, help: "Limit restore to a single built-in by ID. Mutually exclusive with --kind.")
        var id: String?

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func validate() throws {
            if kind != nil && id != nil {
                throw ValidationError("--kind and --id are mutually exclusive")
            }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = QuickPromptRepository(dbQueue: db.dbQueue)

                if let id {
                    let p = try findQuickPrompt(idOrLabel: id, repo: repo)
                    guard p.isBuiltIn else {
                        throw ValidationError("'\(p.label)' is not a built-in quick prompt; nothing to restore.")
                    }
                    try repo.restoreBuiltInDefault(id: p.id)
                    if json {
                        struct R: Encodable { let ok: Bool; let id: UUID; let label: String }
                        try printJSON(R(ok: true, id: p.id, label: p.label))
                    } else {
                        print("Restored '\(p.label)' to built-in defaults.")
                    }
                } else {
                    try repo.restoreBuiltInDefaults(kind: kind?.domain)
                    if json {
                        struct R: Encodable { let ok: Bool; let kind: String? }
                        try printJSON(R(ok: true, kind: kind?.rawValue))
                    } else {
                        let scope = kind?.rawValue ?? "all kinds"
                        print("Restored built-in defaults (\(scope)).")
                    }
                }
            }
        }
    }
}

// MARK: - Export

extension QuickPromptsCommand {
    struct ExportSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "export",
            abstract: "Export quick prompts as a versioned JSON bundle."
        )

        @Option(name: .long, help: "Output file path. If omitted, writes JSON to stdout.")
        var out: String?

        @Option(name: .long, help: "Limit export to one kind: starter or follow-up.")
        var kind: QuickPromptKindArg?

        @Flag(name: .long, help: "Include built-in pills in the export. Default: customs only.")
        var includeBuiltins: Bool = false

        @Flag(name: .long, help: "Emit JSON envelope on failure (success always writes the bundle JSON).")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = QuickPromptRepository(dbQueue: db.dbQueue)

                var prompts: [QuickPrompt]
                if let kind = kind?.domain {
                    prompts = try repo.fetchAll(kind: kind)
                } else {
                    prompts = try repo.fetchAll()
                }
                if !includeBuiltins {
                    prompts = prompts.filter { !$0.isBuiltIn }
                }

                let bundle = QuickPromptBundle(from: prompts, exportedAt: Date(), appVersion: nil)
                let data = try cliJSONEncoder.encode(bundle)

                if let out {
                    let path = expandTilde(out)
                    let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    do {
                        try data.write(to: URL(fileURLWithPath: path))
                    } catch {
                        throw QuickPromptCLIError.writeFailed(out, underlying: error)
                    }
                    printErr("Wrote \(prompts.count) quick prompt(s) to \(path)")
                } else {
                    if let s = String(data: data, encoding: .utf8) {
                        print(s)
                    }
                }
            }
        }
    }
}

// MARK: - Import

extension QuickPromptsCommand {
    struct ImportSubcommand: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "import",
            abstract: "Import a quick prompts bundle from a JSON file."
        )

        @Argument(help: "Path to the bundle JSON file.")
        var path: String

        @Option(name: .long, help: "Import mode: merge (default; UPSERT by id, preserve untouched rows) or replace (wipe customs, re-seed built-ins, then apply).")
        var mode: ModeArg = .merge

        @Flag(name: .long, help: "Show planned changes without writing.")
        var dryRun: Bool = false

        @Flag(name: .long, help: "Skip the confirmation prompt for --mode replace. Implied by --json.")
        var yes: Bool = false

        @Flag(name: .long, help: "Emit JSON instead of human-readable output.")
        var json: Bool = false

        @Option(help: "Path to SQLite database file (defaults to the app database).")
        var database: String?

        enum ModeArg: String, ExpressibleByArgument {
            case merge, replace
            var domain: QuickPromptImport.Mode {
                switch self {
                case .merge:   return .merge
                case .replace: return .replace
                }
            }
        }

        func run() throws {
            try emitJSONOrRethrow(json: json) {
                try AppPaths.ensureDirectories()
                let resolvedPath = expandTilde(path)
                let data: Data
                do {
                    data = try Data(contentsOf: URL(fileURLWithPath: resolvedPath))
                } catch {
                    throw QuickPromptCLIError.readFailed(path, underlying: error)
                }

                let bundle: QuickPromptBundle
                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    bundle = try decoder.decode(QuickPromptBundle.self, from: data)
                } catch {
                    throw QuickPromptCLIError.importSchemaError(error.localizedDescription)
                }

                do {
                    try bundle.validate()
                } catch let validationError as QuickPromptBundleError {
                    throw QuickPromptCLIError.importSchemaError(validationError.localizedDescription)
                }

                if mode.domain == .replace && !yes && !json && !dryRun {
                    let banner = "About to delete all custom quick prompts and re-seed built-ins, then apply \(bundle.prompts.count) prompt(s) from '\(path)'."
                    printErr(banner)
                    printErr("Type 'yes' to continue, anything else to abort:")
                    let response = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                    guard response == "yes" else {
                        throw QuickPromptCLIError.importCancelled
                    }
                }

                let db = try DatabaseManager(path: resolvedDatabasePath(database))
                let repo = QuickPromptRepository(dbQueue: db.dbQueue)
                let summary: QuickPromptImport.Summary
                do {
                    summary = try repo.applyImport(bundle, mode: mode.domain, dryRun: dryRun)
                } catch let importError as QuickPromptImportError {
                    throw QuickPromptCLIError.importSchemaError(importError.localizedDescription)
                }

                if json {
                    struct ImportResult: Encodable {
                        let ok: Bool
                        let mode: String
                        let dryRun: Bool
                        let added: Int
                        let updated: Int
                        let deleted: Int
                        let unchanged: Int
                    }
                    let result = ImportResult(
                        ok: true,
                        mode: mode.rawValue,
                        dryRun: dryRun,
                        added: summary.added,
                        updated: summary.updated,
                        deleted: summary.deleted,
                        unchanged: summary.unchanged
                    )
                    try printJSON(result)
                } else {
                    let prefix = dryRun ? "[dry-run] " : ""
                    print("\(prefix)added: \(summary.added), updated: \(summary.updated), deleted: \(summary.deleted), unchanged: \(summary.unchanged)")
                }
            }
        }
    }
}
