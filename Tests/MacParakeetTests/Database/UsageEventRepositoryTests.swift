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

        book.setOverride(UsagePrice(inputPerMillion: 1, outputPerMillion: 2), forModel: row.model)
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
}
