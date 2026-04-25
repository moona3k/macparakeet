import Foundation
import MacParakeetCore

let macParakeetAppDefaultsSuiteName = "com.macparakeet.MacParakeet"

func macParakeetAppDefaults() -> UserDefaults {
    UserDefaults(suiteName: macParakeetAppDefaultsSuiteName) ?? .standard
}

// MARK: - Database Path Resolution

func resolvedDatabasePath(_ database: String?) -> String {
    let opt = database?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let opt, !opt.isEmpty {
        let dir = URL(fileURLWithPath: opt).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return opt
    }
    return AppPaths.databasePath
}

// MARK: - Lookup Errors

enum CLILookupError: Error, LocalizedError {
    case notFound(String)
    case ambiguous(String)
    case emptyID

    var errorDescription: String? {
        switch self {
        case .notFound(let msg): return msg
        case .ambiguous(let msg): return msg
        case .emptyID: return "ID must not be empty."
        }
    }
}

// MARK: - Transcription Lookup (shared by export, delete, favorite, unfavorite)

func findTranscription(id: String, repo: TranscriptionRepository) throws -> Transcription {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLILookupError.emptyID
    }

    // Try exact UUID first
    if let uuid = UUID(uuidString: id), let t = try repo.fetch(id: uuid) {
        return t
    }

    // Prefix match
    let all = try repo.fetchAll()
    let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }

    guard let match = matches.first else {
        throw CLILookupError.notFound("No transcription matching '\(id)'")
    }
    guard matches.count == 1 else {
        throw CLILookupError.ambiguous("Multiple transcriptions match '\(id)'. Be more specific.")
    }
    return match
}

// MARK: - Dictation Lookup

func findDictation(id: String, repo: DictationRepository) throws -> Dictation {
    guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw CLILookupError.emptyID
    }

    if let uuid = UUID(uuidString: id), let d = try repo.fetch(id: uuid) {
        return d
    }

    let all = try repo.fetchAll()
    let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(id.lowercased()) }

    guard let match = matches.first else {
        throw CLILookupError.notFound("No dictation matching '\(id)'")
    }
    guard matches.count == 1 else {
        throw CLILookupError.ambiguous("Multiple dictations match '\(id)'. Be more specific.")
    }
    return match
}

// MARK: - Prompt Lookup

/// Resolves a prompt by exact UUID, UUID prefix, or case-insensitive name.
/// Names are checked only when no UUID-prefix match was found, so an ambiguous
/// prefix surfaces as such instead of silently falling through to a name match.
func findPrompt(idOrName: String, repo: PromptRepository) throws -> Prompt {
    let trimmed = idOrName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CLILookupError.emptyID }

    if let uuid = UUID(uuidString: trimmed), let prompt = try repo.fetch(id: uuid) {
        return prompt
    }

    let all = try repo.fetchAll()
    let lowered = trimmed.lowercased()

    let prefixMatches = all.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
    if prefixMatches.count == 1 { return prefixMatches[0] }
    if prefixMatches.count > 1 {
        throw CLILookupError.ambiguous("Multiple prompts match '\(trimmed)' as ID prefix. Be more specific.")
    }

    let nameMatches = all.filter { $0.name.lowercased() == lowered }
    if nameMatches.count == 1 { return nameMatches[0] }
    if nameMatches.count > 1 {
        throw CLILookupError.ambiguous("Multiple prompts named '\(trimmed)'. Use ID instead.")
    }

    throw CLILookupError.notFound("No prompt matching '\(trimmed)'")
}

// MARK: - JSON Output

/// Single source of truth for CLI JSON output. Matches the convention established
/// by `calendar upcoming --json`: ISO-8601 dates, sorted keys, pretty-printed.
let cliJSONEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

func printJSON<T: Encodable>(_ value: T) throws {
    let data = try cliJSONEncoder.encode(value)
    if let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}
