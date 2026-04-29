import ArgumentParser
import Foundation
import MacParakeetCore

let macParakeetAppDefaultsSuiteName = "com.macparakeet.MacParakeet"
let cliValidationMisuseExitCode = ExitCode(2)

func macParakeetAppDefaults() -> UserDefaults {
    UserDefaults(suiteName: macParakeetAppDefaultsSuiteName) ?? .standard
}

func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

// MARK: - Database Path Resolution

func resolvedDatabasePath(_ database: String?) -> String {
    let opt = database?.trimmingCharacters(in: .whitespacesAndNewlines)
    if let opt, !opt.isEmpty {
        let resolved = expandTilde(opt)
        let dir = URL(fileURLWithPath: resolved).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return resolved
    }
    return AppPaths.databasePath
}

// MARK: - Lookup Errors

enum CLILookupError: Error, LocalizedError {
    case notFound(String)
    case ambiguous(String)
    case emptyID
    case shortUUIDPrefix(minimumLength: Int)

    var errorDescription: String? {
        switch self {
        case .notFound(let msg): return msg
        case .ambiguous(let msg): return msg
        case .emptyID: return "ID must not be empty."
        case .shortUUIDPrefix(let minimumLength):
            return "UUID prefixes must be at least \(minimumLength) characters."
        }
    }
}

enum CLIInputError: Error, LocalizedError {
    case empty

    var errorDescription: String? {
        switch self {
        case .empty: return "Input is empty."
        }
    }
}

private let minimumUUIDPrefixLength = 4

private func isUUIDPrefixCandidate(_ value: String) -> Bool {
    value.allSatisfy { char in
        char == "-" || char.isHexDigit
    }
}

private func uuidPrefixSearchKey(_ value: String) -> String? {
    let lowered = value.lowercased()
    guard lowered.count >= minimumUUIDPrefixLength,
          isUUIDPrefixCandidate(lowered)
    else {
        return nil
    }
    return lowered
}

private func shortUUIDPrefixErrorIfApplicable(_ value: String) -> CLILookupError? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          trimmed.count < minimumUUIDPrefixLength,
          isUUIDPrefixCandidate(trimmed)
    else {
        return nil
    }
    return .shortUUIDPrefix(minimumLength: minimumUUIDPrefixLength)
}

// MARK: - Transcription Lookup (shared by export, delete, favorite, unfavorite)

func findTranscription(id: String, repo: TranscriptionRepository) throws -> Transcription {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw CLILookupError.emptyID
    }

    // Try exact UUID first
    if let uuid = UUID(uuidString: trimmed), let t = try repo.fetch(id: uuid) {
        return t
    }

    let lowered = trimmed.lowercased()
    if let prefix = uuidPrefixSearchKey(trimmed) {
        let matches = try repo.fetchByIDPrefix(prefix)

        if matches.count == 1 { return matches[0] }
        if matches.count > 1 {
            throw CLILookupError.ambiguous("Multiple transcriptions match '\(trimmed)'. Be more specific.")
        }
    }

    let nameMatches = try repo.fetchByFileName(lowered)
    if nameMatches.count == 1 { return nameMatches[0] }
    if nameMatches.count > 1 {
        throw CLILookupError.ambiguous("Multiple transcriptions named '\(trimmed)'. Use ID instead.")
    }
    if let error = shortUUIDPrefixErrorIfApplicable(trimmed) { throw error }

    throw CLILookupError.notFound("No transcription matching '\(trimmed)'")
}

func findMeeting(idOrName: String, repo: TranscriptionRepository) throws -> Transcription {
    let trimmed = idOrName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw CLILookupError.emptyID }

    if let uuid = UUID(uuidString: trimmed),
       let transcription = try repo.fetch(id: uuid),
       transcription.sourceType == .meeting {
        return transcription
    }

    if let prefix = uuidPrefixSearchKey(trimmed) {
        let prefixMatches = try repo.fetchBySourceType(.meeting, idPrefix: prefix)
        if prefixMatches.count == 1 { return prefixMatches[0] }
        if prefixMatches.count > 1 {
            throw CLILookupError.ambiguous("Multiple meetings match '\(trimmed)'. Be more specific.")
        }
    }

    let nameMatches = try repo.fetchBySourceType(.meeting, fileName: trimmed)
    if nameMatches.count == 1 { return nameMatches[0] }
    if nameMatches.count > 1 {
        throw CLILookupError.ambiguous("Multiple meetings named '\(trimmed)'. Use ID instead.")
    }
    if let error = shortUUIDPrefixErrorIfApplicable(trimmed) { throw error }

    throw CLILookupError.notFound("No meeting matching '\(trimmed)'")
}

// MARK: - Dictation Lookup

func findDictation(id: String, repo: DictationRepository) throws -> Dictation {
    let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw CLILookupError.emptyID
    }

    if let uuid = UUID(uuidString: trimmed), let d = try repo.fetch(id: uuid) {
        return d
    }

    guard let prefix = uuidPrefixSearchKey(trimmed) else {
        throw shortUUIDPrefixErrorIfApplicable(trimmed) ?? CLILookupError.notFound("No dictation matching '\(trimmed)'")
    }

    let all = try repo.fetchAll()
    let matches = all.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }

    guard let match = matches.first else {
        throw CLILookupError.notFound("No dictation matching '\(trimmed)'")
    }
    guard matches.count == 1 else {
        throw CLILookupError.ambiguous("Multiple dictations match '\(trimmed)'. Be more specific.")
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

    if let prefix = uuidPrefixSearchKey(trimmed) {
        let prefixMatches = all.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        if prefixMatches.count == 1 { return prefixMatches[0] }
        if prefixMatches.count > 1 {
            throw CLILookupError.ambiguous("Multiple prompts match '\(trimmed)' as ID prefix. Be more specific.")
        }
    }

    let nameMatches = all.filter { $0.name.lowercased() == lowered }
    if nameMatches.count == 1 { return nameMatches[0] }
    if nameMatches.count > 1 {
        throw CLILookupError.ambiguous("Multiple prompts named '\(trimmed)'. Use ID instead.")
    }
    if let error = shortUUIDPrefixErrorIfApplicable(trimmed) { throw error }

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

/// Write a status / progress message to stderr so it doesn't pollute stdout
/// for callers piping `--json` output to `jq`, scripts, or skill manifests.
/// Append a trailing newline.
func printErr(_ s: String) {
    try? FileHandle.standardError.write(contentsOf: Data((s + "\n").utf8))
}

// MARK: - Failure envelope (--json contract)

/// Public failure envelope emitted to stdout when a `--json` command fails.
/// Pairs with the success envelopes (`LLMResult`, `LLMTestConnectionResult`,
/// etc.) after argument parsing succeeds. Downstream agents parsing executed
/// `--json` commands see one of two JSON shapes: an `ok: true` success object
/// or this `ok: false` failure object. Either way, the exit code is the
/// source of truth for branching; the envelope is the source of truth for
/// *why* it failed.
public struct CLIErrorEnvelope: Encodable {
    public let ok: Bool   // always false
    public let error: String
    public let errorType: String
}

/// Stable, low-cardinality string keys for the `errorType` field. Picking
/// readable strings (over an enum surfaced as int) so the contract stays
/// usable from `jq`, shell scripts, and skill manifests.
enum CLIErrorType {
    static let auth = "auth"
    static let config = "config"
    static let connection = "connection"
    static let context = "context"
    static let inputEmpty = "input_empty"
    static let inputMissing = "input_missing"
    static let invalidResponse = "invalid_response"
    static let lookup = "lookup"
    static let model = "model"
    static let provider = "provider"
    static let rateLimit = "rate_limit"
    static let runtime = "runtime"
    static let streaming = "streaming"
    static let truncated = "truncated"
    static let validation = "validation"

    static func key(for error: Error) -> String {
        if let llm = error as? LLMError {
            switch llm {
            case .notConfigured: return config
            case .connectionFailed: return connection
            case .authenticationFailed: return auth
            case .rateLimited: return rateLimit
            case .modelNotFound: return model
            case .contextTooLong: return context
            case .formatterTruncated, .formatterEmptyResponse: return truncated
            case .providerError: return provider
            case .streamingError: return streaming
            case .invalidResponse: return invalidResponse
            case .cliError: return runtime
            }
        }
        if error is CLILookupError { return lookup }
        if error is CLIInputError { return inputEmpty }
        // ArgumentParser surfaces `validate()` failures as `ValidationError`.
        // The taxonomy has carried the `validation` value since 1.2.0; map
        // ValidationError to it so downstream agents can branch on user
        // misuse without regexing the human-readable description.
        if error is ValidationError { return validation }
        return runtime
    }
}

extension CLIErrorEnvelope {
    init(error: Error) {
        let message: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            message = description
        } else {
            message = String(describing: error)
        }
        self.init(ok: false, error: message, errorType: CLIErrorType.key(for: error))
    }
}

/// Wrap a `--json`-aware CLI body. On error: when `json` is true, emit a
/// `CLIErrorEnvelope` on stdout and exit non-zero; otherwise re-throw so
/// the existing plain-text path (printErr / ArgumentParser) handles it.
///
/// Exit code follows the public CLI contract documented in
/// `Sources/CLI/CHANGELOG.md`:
///
/// - `ExitCode.success` and `CleanExit` (e.g. `--help`) pass through.
/// - `ExitCode.*` thrown from the body means the inner code already handled
///   its own user-visible output; pass through unchanged so we don't
///   double-print on the JSON channel.
/// - User-misuse errors (`ValidationError`, `CLIInputError`) exit `2`.
/// - Everything else exits `1` (runtime failure).
///
/// Note: errors thrown during ArgumentParser's parse + `validate()` phase
/// occur *before* `run()` and therefore cannot reach this wrapper. Those
/// surface through ArgumentParser's plain-text stderr path; the JSON
/// envelope contract applies only to errors emitted after argument parsing
/// succeeds.
func emitJSONOrRethrow(json: Bool, _ body: () throws -> Void) throws {
    do {
        try body()
    } catch let exit as ExitCode {
        throw exit
    } catch let cleanExit as CleanExit {
        throw cleanExit
    } catch {
        try rethrowWithOptionalJSONEnvelope(error, json: json)
    }
}

func emitJSONOrRethrow(json: Bool, _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let exit as ExitCode {
        throw exit
    } catch let cleanExit as CleanExit {
        throw cleanExit
    } catch {
        try rethrowWithOptionalJSONEnvelope(error, json: json)
    }
}

private func rethrowWithOptionalJSONEnvelope(_ error: Error, json: Bool) throws {
    guard json else { throw error }
    let envelope = CLIErrorEnvelope(error: error)
    try? printJSON(envelope)
    if error is ValidationError || error is CLIInputError {
        throw cliValidationMisuseExitCode
    }
    throw ExitCode.failure
}
