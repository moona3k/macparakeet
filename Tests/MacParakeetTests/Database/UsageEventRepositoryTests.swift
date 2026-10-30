import XCTest

@testable import MacParakeetCore

final class UsageEventRepositoryTests: XCTestCase {
    private var repo: UsageEventRepository!
    private var manager: DatabaseManager!

    override func setUp() async throws {
        manager = try DatabaseManager()
        repo = UsageEventRepository(dbQueue: manager.dbQueue)
    }

    func testSummaryGroupsByModelAndRespectsPeriod() throws {
        let now = Date()
        let old = now.addingTimeInterval(-40 * 86_400)
        try repo.save(
            UsageEvent(
                kind: .llm, provider: "openai", model: "gpt-4o", promptTokens: 1_000, completionTokens: 200,
                createdAt: now))
        try repo.save(
            UsageEvent(
                kind: .llm, provider: "openai", model: "gpt-4o", promptTokens: 500, completionTokens: 100,
                tokensEstimated: true, createdAt: now))
        try repo.save(
            UsageEvent(
                kind: .llm, provider: "openai", model: "gpt-4o", promptTokens: 9_000, completionTokens: 9_000,
                createdAt: old))
        try repo.save(
            UsageEvent(
                kind: .cloudSpeech, provider: "api.openai.com", model: "whisper-1", audioMs: 120_000, createdAt: now))

        let recent = try repo.summary(since: now.addingTimeInterval(-30 * 86_400))
        let ai = try XCTUnwrap(recent.first { $0.kind == .llm })
        XCTAssertEqual(ai.requests, 2)
        XCTAssertEqual(ai.promptTokens, 1_500)
        XCTAssertEqual(ai.completionTokens, 300)
        XCTAssertTrue(ai.tokensEstimated)
        XCTAssertEqual(recent.first { $0.kind == .cloudSpeech }?.audioMs, 120_000)

        let all = try repo.summary(since: nil)
        XCTAssertEqual(all.first { $0.kind == .llm }?.requests, 3)

        try repo.deleteAll()
        XCTAssertTrue(try repo.summary(since: nil).isEmpty)
    }

    func testSpeechEngineUsageCountsCompletedTranscriptions() throws {
        let transcriptions = TranscriptionRepository(dbQueue: manager.dbQueue)
        try transcriptions.save(
            Transcription(
                fileName: "a", durationMs: 60_000, status: .completed, engine: "parakeet", engineVariant: "v3"))
        try transcriptions.save(
            Transcription(
                fileName: "b", durationMs: 30_000, status: .completed, engine: "parakeet", engineVariant: "v3"))
        try transcriptions.save(
            Transcription(fileName: "c", durationMs: 99_000, status: .error, engine: "parakeet", engineVariant: "v3"))

        let rows = try repo.speechEngineUsage(since: nil)
        XCTAssertEqual(rows, [SpeechEngineUsageRow(engine: "parakeet", variant: "v3", items: 2, audioMs: 90_000)])
    }

    func testSummaryKeepsLocalAndRemoteUsageSeparateWithDistinctIdentities() throws {
        for local in [true, false] {
            try repo.save(
                UsageEvent(
                    kind: .llm, provider: "openaiCompatible", model: "shared-model", isLocal: local,
                    promptTokens: local ? 10 : 20))
        }
        let rows = try repo.summary(since: nil)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.id)).count, 2)
        XCTAssertEqual(rows.first { $0.isLocal }?.promptTokens, 10)
        XCTAssertEqual(rows.first { !$0.isLocal }?.promptTokens, 20)
        XCTAssertTrue(rows.allSatisfy { $0.requests == 1 })
    }

    func testSpeechEngineUsageExcludesUncompletedDictationsAndRespectsPeriod() throws {
        let dictations = DictationRepository(dbQueue: manager.dbQueue)
        let now = Date()
        for status in [Dictation.DictationStatus.recording, .processing, .cancelled, .error] {
            try dictations.save(Dictation(durationMs: 90_000, rawTranscript: "", status: status))
        }
        try dictations.save(
            Dictation(
                createdAt: now, durationMs: 1_000, rawTranscript: "Complete", status: .completed,
                engine: "parakeet", engineVariant: "v3"))
        try dictations.save(
            Dictation(
                createdAt: now.addingTimeInterval(-40 * 86_400), durationMs: 2_000, rawTranscript: "Old",
                status: .completed))
        XCTAssertEqual(
            try repo.speechEngineUsage(since: now.addingTimeInterval(-86_400)),
            [SpeechEngineUsageRow(engine: "parakeet", variant: "v3", items: 1, audioMs: 1_000)])
        let all = try repo.speechEngineUsage(since: nil)
        XCTAssertEqual(all.first { $0.engine == "unknown" }?.items, 1, "Completed legacy rows remain countable")
        XCTAssertEqual(all.reduce(0) { $0 + $1.items }, 2)
    }

    func testPriceBookEstimatesAndOverrides() {
        let suite = "test.usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = UsagePriceBook(defaults: defaults)
        let row = UsageSummaryRow(
            kind: .llm, provider: "openai", model: "gpt-4o-mini-2024-07-18", isLocal: false, requests: 1,
            promptTokens: 1_000_000, completionTokens: 1_000_000, tokensEstimated: false, audioMs: 0)

        XCTAssertEqual(
            book.price(for: row)?.cost(for: row) ?? 0, 0.75, accuracy: 0.0001, "Longest prefix wins: mini, not gpt-4o")

        book.setOverride(UsagePrice(inputPerMillion: 1, outputPerMillion: 2), for: row)
        XCTAssertEqual(book.price(for: row)?.cost(for: row) ?? 0, 3, accuracy: 0.0001)

        var unknown = row
        unknown.model = "some-new-model"
        XCTAssertNil(book.price(for: unknown), "Unknown paid models have no price rather than a guessed one")
        unknown.isLocal = true
        XCTAssertEqual(book.price(for: unknown)?.cost(for: unknown), 0)

        let speech = UsageSummaryRow(
            kind: .cloudSpeech, provider: "api.openai.com", model: "whisper-1", isLocal: false, requests: 1,
            promptTokens: 0, completionTokens: 0, tokensEstimated: false, audioMs: 600_000)
        XCTAssertEqual(book.price(for: speech)?.cost(for: speech) ?? 0, 0.06, accuracy: 0.0001)
    }

    func testOverridesAreScopedAndLegacyPricesRequireProviderConfirmation() throws {
        let suite = "test.usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = UsagePriceBook(defaults: defaults)
        let original = UsageSummaryRow(
            kind: .llm, provider: "openai", model: "gpt-4o-mini", isLocal: false, requests: 1,
            promptTokens: 1_000_000, completionTokens: 0, tokensEstimated: false, audioMs: 0)
        var other = original
        other.provider = "openaiCompatible"
        let legacy = UsagePrice(inputPerMillion: 7, outputPerMillion: 9)
        book.setOverride(legacy, forModel: original.model)
        let legacyData = defaults.data(forKey: UsagePriceBook.overridesKey)
        XCTAssertNil(book.price(for: original), "A model-only override has no proven provider")
        XCTAssertNil(book.price(for: other))
        XCTAssertEqual(book.legacyOverride(forModel: original.model), legacy)

        XCTAssertTrue(book.setOverride(legacy, for: original))
        XCTAssertEqual(book.price(for: original), legacy)
        XCTAssertNil(book.price(for: other))
        XCTAssertTrue(book.setOverride(UsagePrice(inputPerMillion: 2), for: other))
        XCTAssertEqual(book.price(for: other)?.inputPerMillion, 2)
        XCTAssertEqual(book.price(for: original), legacy)
        XCTAssertEqual(defaults.data(forKey: UsagePriceBook.overridesKey), legacyData)

        var local = original
        local.isLocal = true
        XCTAssertEqual(book.price(for: local), UsagePrice())
        XCTAssertNotEqual(local.id, original.id)
        var speech = original
        speech.kind = .cloudSpeech
        XCTAssertNil(book.price(for: speech), "An AI price cannot become an audio price")

        XCTAssertTrue(book.setOverride(nil, for: original))
        XCTAssertNil(book.price(for: original), "Removing the scoped price does not silently reuse legacy data")
        XCTAssertEqual(book.price(for: other)?.inputPerMillion, 2)
        XCTAssertEqual(defaults.data(forKey: UsagePriceBook.overridesKey), legacyData)
    }

    func testBuiltInPricesRequireMatchingProviderKindAndModelBoundary() {
        let suite = "test.usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = UsagePriceBook(defaults: defaults)
        var row = UsageSummaryRow(
            kind: .llm, provider: "openrouter", model: "openai/gpt-4o-mini", isLocal: false, requests: 1,
            promptTokens: 1, completionTokens: 1, tokensEstimated: false, audioMs: 0)
        XCTAssertNil(book.price(for: row), "A reseller does not inherit the original provider's price")
        row.provider = "openaiCompatible"
        row.model = "gpt-4o-mini"
        XCTAssertNil(book.price(for: row))
        row.provider = "anthropic"
        XCTAssertNil(book.price(for: row))
        row.provider = "openai"
        row.model = "gpt-4ocean"
        XCTAssertNil(book.price(for: row))
        row.model = "gpt-4o-transcribe"
        XCTAssertNil(book.price(for: row), "Audio models must not fall back to a shorter AI-model prefix")
        row.kind = .cloudSpeech
        row.provider = "api.openai.com"
        XCTAssertEqual(book.price(for: row)?.audioPerMinute, 0.006)
    }

    func testInvalidPricesCannotOverwriteAValidScopedPrice() {
        let suite = "test.usage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let book = UsagePriceBook(defaults: defaults)
        let row = UsageSummaryRow(
            kind: .llm, provider: "custom", model: "model", isLocal: false, requests: 1,
            promptTokens: 1, completionTokens: 1, tokensEstimated: false, audioMs: 0)
        let valid = UsagePrice(inputPerMillion: 1)
        XCTAssertTrue(book.setOverride(valid, for: row))
        for invalid in [-1.0, Double.infinity, Double.nan] {
            XCTAssertFalse(book.setOverride(UsagePrice(inputPerMillion: invalid), for: row))
            XCTAssertEqual(book.price(for: row), valid)
        }
    }
}
