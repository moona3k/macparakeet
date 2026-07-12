import ArgumentParser
import Foundation
import MacParakeetCore

extension CardSource: ExpressibleByArgument {}

struct CardsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cards",
        abstract: "List or generate compact per-recording knowledge cards.",
        subcommands: [CardsListCommand.self, CardsGenerateCommand.self]
    )
}

struct CardsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List knowledge cards with deterministic recording metadata."
    )

    @Option(help: "Only recordings at or after this ISO-8601 timestamp or local date (start of day).")
    var since: String?

    @Option(help: "Only recordings at or before this ISO-8601 timestamp or local date (end of day).")
    var until: String?

    @Option(help: "Filter source: meeting, file, or url.")
    var source: CardSource?

    @Option(name: .shortAndLong, help: "Maximum number of cards.")
    var limit: Int = 100

    @Flag(name: .long, help: "Emit the card array as JSON.")
    var json = false

    @Flag(name: .long, help: "Emit one compact JSON card per line.")
    var ndjson = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func validate() throws {
        guard limit >= 0 else { throw ValidationError("--limit must be >= 0.") }
        guard !(json && ndjson) else {
            throw ValidationError("--json and --ndjson are mutually exclusive.")
        }
        _ = try since.map { try parseSearchDate($0, boundary: .since) }
        _ = try until.map { try parseSearchDate($0, boundary: .until) }
    }

    func run() async throws {
        try emitJSONOrRethrow(json: json || ndjson) {
            let db = try makeDatabaseManager(database: database)
            let rows = try CardRepository(dbQueue: db.dbQueue).list(
                CardListQuery(
                    since: try since.map { try parseSearchDate($0, boundary: .since) },
                    until: try until.map { try parseSearchDate($0, boundary: .until) },
                    source: source,
                    limit: limit
                ))
            if json {
                try printJSON(rows)
            } else if ndjson {
                for row in rows {
                    try printCardNDJSON(row)
                }
            } else if rows.isEmpty {
                print("No knowledge cards found. Run `macparakeet-cli cards generate --stale`.")
            } else {
                for row in rows {
                    print("[\(ISO8601DateFormatter().string(from: row.date))] \(row.title) (\(row.source.rawValue))")
                    print("  \(row.synopsis)")
                }
            }
        }
    }
}

struct CardsGenerateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "generate",
        abstract: "Generate or backfill knowledge cards with the configured LLM provider."
    )

    @Flag(name: .long, help: "Regenerate every completed recording, including fresh cards.")
    var all = false

    @Flag(name: .long, help: "Generate only missing or stale cards.")
    var stale = false

    @Argument(help: "One transcription UUID, UUID prefix, or exact title to regenerate.")
    var id: String?

    @Flag(name: .long, help: "Emit the aggregate generation report as JSON.")
    var json = false

    @Option(help: "Path to SQLite database file (defaults to the app database).")
    var database: String?

    func validate() throws {
        let selectionCount = (all ? 1 : 0) + (stale ? 1 : 0) + (id == nil ? 0 : 1)
        guard selectionCount == 1 else {
            throw ValidationError("Choose exactly one of --all, --stale, or a transcription ID.")
        }
    }

    func run() async throws {
        try await emitJSONOrRethrow(json: json) {
            let db = try makeDatabaseManager(database: database)
            let transcriptions = TranscriptionRepository(dbQueue: db.dbQueue)
            let cardRepository = CardRepository(dbQueue: db.dbQueue)
            let selectedIDs: [UUID]
            let selection: String
            let force: Bool
            if let id {
                let transcription = try findTranscription(id: id, repo: transcriptions)
                guard transcription.status == .completed else {
                    throw ValidationError("Knowledge cards require a completed transcription.")
                }
                selectedIDs = [transcription.id]
                selection = transcription.id.uuidString
                force = true
            } else {
                selectedIDs = try cardRepository.completedTranscriptionIDs()
                selection = all ? "all" : "stale"
                force = all
            }

            let segmentRepository = SegmentRepository(dbQueue: db.dbQueue)
            let generator = CardGenerationService(
                transcriptionRepository: transcriptions,
                segmentRepository: segmentRepository,
                cardRepository: cardRepository,
                completionProvider: LLMService()
            )
            var report = CardsGenerationReport(selection: selection, selected: selectedIDs.count)
            for (index, transcriptionID) in selectedIDs.enumerated() {
                printErr("[\(index + 1)/\(selectedIDs.count)] \(transcriptionID.uuidString)")
                do {
                    let outcome = try await withStandardOutputRedirectedToStandardError {
                        try await generator.generate(transcriptionId: transcriptionID, force: force)
                    }
                    report.processed += 1
                    if outcome.wasSkipped {
                        report.skipped += 1
                        printErr("  fresh; skipped")
                    } else {
                        report.generated += 1
                        report.add(outcome.usage)
                        let tokens = outcome.usage?.totalTokens.map(String.init) ?? "unknown"
                        printErr("  generated; tokens=\(tokens); estimated_cost_usd=unavailable")
                    }
                } catch is CancellationError {
                    throw ExitCode(130)
                } catch {
                    report.processed += 1
                    report.failed += 1
                    report.failures.append(
                        CardsGenerationFailure(
                            transcriptionId: transcriptionID,
                            error: error.localizedDescription
                        ))
                    printErr("  failed: \(error.localizedDescription)")
                }
            }

            if json {
                try printJSON(report)
            } else {
                print(
                    "Processed \(report.processed): generated \(report.generated), "
                        + "skipped \(report.skipped), failed \(report.failed)."
                )
                print(
                    "Token usage: \(report.totalTokens.map(String.init) ?? "unavailable"); estimated cost: unavailable."
                )
            }
            if report.exitCode != .success {
                throw report.exitCode
            }
        }
    }
}

struct CardsGenerationFailure: Encodable {
    let transcriptionId: UUID
    let error: String
}

struct CardsGenerationReport: Encodable {
    let selection: String
    let selected: Int
    var processed = 0
    var generated = 0
    var skipped = 0
    var failed = 0
    var promptTokens: Int?
    var completionTokens: Int?
    var totalTokens: Int?
    var failures: [CardsGenerationFailure] = []

    var exitCode: ExitCode {
        failed > 0 ? .failure : .success
    }

    private enum CodingKeys: String, CodingKey {
        case selection, selected, processed, generated, skipped, failed
        case promptTokens, completionTokens, totalTokens, estimatedCostUSD, failures
    }

    init(selection: String, selected: Int) {
        self.selection = selection
        self.selected = selected
    }

    mutating func add(_ usage: LLMUsage?) {
        promptTokens = Self.sum(promptTokens, usage?.promptTokens)
        completionTokens = Self.sum(completionTokens, usage?.completionTokens)
        totalTokens = Self.sum(totalTokens, usage?.totalTokens)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selection, forKey: .selection)
        try container.encode(selected, forKey: .selected)
        try container.encode(processed, forKey: .processed)
        try container.encode(generated, forKey: .generated)
        try container.encode(skipped, forKey: .skipped)
        try container.encode(failed, forKey: .failed)
        try container.encode(promptTokens, forKey: .promptTokens)
        try container.encode(completionTokens, forKey: .completionTokens)
        try container.encode(totalTokens, forKey: .totalTokens)
        try container.encodeNil(forKey: .estimatedCostUSD)
        try container.encode(failures, forKey: .failures)
    }

    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}

private func printCardNDJSON(_ row: CardListItem) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(row)
    guard let line = String(data: data, encoding: .utf8) else {
        throw CocoaError(.fileWriteInapplicableStringEncoding)
    }
    print(line)
}
