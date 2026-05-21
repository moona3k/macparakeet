import XCTest
@testable import MacParakeetCore

final class SubtitleLLMLayoutPlannerTests: XCTestCase {

    // MARK: - Helpers

    private func words(_ n: Int) -> [WordTimestamp] {
        (0..<n).map { i in
            WordTimestamp(word: "w\(i)", startMs: i * 100, endMs: i * 100 + 80, confidence: 0.99)
        }
    }

    private func unit(_ start: Int, _ end: Int) -> SentenceUnit {
        SentenceUnit(startIndex: start, endIndex: end, text: "", endsWithStrongPunctuation: true)
    }

    // MARK: - Happy path

    func testHappyPathProducesCuesWithCorrectTiming() async {
        let ws = words(6)
        let units = [unit(0, 2), unit(3, 5)]
        let llm = ScriptedLLM(responses: [
            #"{"cues":[{"start":0,"end":2},{"start":3,"end":5}]}"#
        ])
        let planner = SubtitleLLMLayoutPlanner(
            llmService: llm,
            chunkTargetWords: 100,
            maxConcurrency: 1
        )
        let results = await planner.plan(words: ws, units: units, config: .default)
        XCTAssertEqual(results.count, 1)
        let cues = results[0].cues
        XCTAssertNotNil(cues)
        XCTAssertEqual(cues?.count, 2)
        XCTAssertEqual(cues?[0].text, "w0 w1 w2")
        XCTAssertEqual(cues?[0].startMs, 0)
        XCTAssertEqual(cues?[0].endMs, ws[2].endMs)
        XCTAssertEqual(cues?[1].text, "w3 w4 w5")
        XCTAssertEqual(cues?[1].startMs, ws[3].startMs)
        XCTAssertEqual(cues?[1].endMs, ws[5].endMs)
    }

    // MARK: - Failure modes → nil cues

    func testMalformedJSONFallsBack() async {
        let ws = words(4)
        let units = [unit(0, 3)]
        let llm = ScriptedLLM(responses: ["this is not JSON"])
        let planner = SubtitleLLMLayoutPlanner(llmService: llm, chunkTargetWords: 100, maxConcurrency: 1)
        let results = await planner.plan(words: ws, units: units, config: .default)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].cues, "Malformed JSON should yield nil cues for the chunk")
        XCTAssertTrue(results[0].didFallBack)
    }

    func testLLMThrowingFallsBack() async {
        let ws = words(4)
        let units = [unit(0, 3)]
        let llm = FailingLLM()
        let planner = SubtitleLLMLayoutPlanner(llmService: llm, chunkTargetWords: 100, maxConcurrency: 1)
        let results = await planner.plan(words: ws, units: units, config: .default)
        XCTAssertEqual(results.count, 1)
        XCTAssertNil(results[0].cues)
    }

    func testCoverageGapFallsBack() async {
        // Response covers words 0–1 then 4–5, skipping 2–3.
        let ws = words(6)
        let units = [unit(0, 5)]
        let llm = ScriptedLLM(responses: [
            #"{"cues":[{"start":0,"end":1},{"start":4,"end":5}]}"#
        ])
        let planner = SubtitleLLMLayoutPlanner(llmService: llm, chunkTargetWords: 100, maxConcurrency: 1)
        let results = await planner.plan(words: ws, units: units, config: .default)
        XCTAssertNil(results[0].cues)
    }

    // MARK: - Chunking

    func testMakeChunksMath() async {
        let ws = words(12)
        let units = [unit(0, 2), unit(3, 5), unit(6, 8), unit(9, 11)]
        let llm = ScriptedLLM(responses: [])
        let planner = SubtitleLLMLayoutPlanner(llmService: llm, chunkTargetWords: 5, maxConcurrency: 1)
        let chunks = planner.makeChunks(words: ws, units: units)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0].startIndex, 0)
        XCTAssertEqual(chunks[0].endIndex, 5)
        XCTAssertEqual(chunks[0].words.count, 6)
        XCTAssertEqual(chunks[1].startIndex, 6)
        XCTAssertEqual(chunks[1].endIndex, 11)
        XCTAssertEqual(chunks[1].words.count, 6)
    }

    func testChunkingRespectsSentenceUnits() async {
        // 12 words split into 4 sentence units of 3 words each. With
        // chunkTargetWords=5, the planner should produce 4 chunks:
        // [units 0,1] → 6 words (≥5), flush. Then [units 2,3] → 6 words.
        let ws = words(12)
        let units = [unit(0, 2), unit(3, 5), unit(6, 8), unit(9, 11)]
        let llm = ScriptedLLM(responses: [
            #"{"cues":[{"start":0,"end":5}]}"#,
            #"{"cues":[{"start":0,"end":5}]}"#,
        ])
        let planner = SubtitleLLMLayoutPlanner(llmService: llm, chunkTargetWords: 5, maxConcurrency: 1)
        let results = await planner.plan(words: ws, units: units, config: .default)
        XCTAssertEqual(results.count, 2, "Expected 2 chunks each holding 2 sentence units")
        XCTAssertEqual(results[0].chunkStartIndex, 0)
        XCTAssertEqual(results[0].chunkEndIndex, 5)
        XCTAssertEqual(results[1].chunkStartIndex, 6)
        XCTAssertEqual(results[1].chunkEndIndex, 11)
    }

    // MARK: - Progress

    func testProgressFiresForEveryChunk() async {
        let ws = words(20)
        let units = [unit(0, 9), unit(10, 19)]
        let llm = ScriptedLLM(responses: [
            #"{"cues":[{"start":0,"end":9}]}"#,
            #"{"cues":[{"start":0,"end":9}]}"#,
        ])
        let planner = SubtitleLLMLayoutPlanner(llmService: llm, chunkTargetWords: 10, maxConcurrency: 1)
        let progress = ProgressRecorder()
        _ = await planner.plan(
            words: ws,
            units: units,
            config: .default,
            onProgress: { d, t in progress.record(done: d, total: t) }
        )
        let snaps = progress.snapshot()
        XCTAssertEqual(snaps.count, 2)
        XCTAssertEqual(snaps.last?.done, 2)
        XCTAssertEqual(snaps.last?.total, 2)
    }
}

// MARK: - Test doubles

/// Returns one canned response per chunk call (round-robins if more
/// chunks than responses).
private final class ScriptedLLM: LLMServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var callCount = 0

    init(responses: [String]) { self.responses = responses }

    func transform(text: String, prompt: String) async throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !responses.isEmpty else { return "{}" }
        let r = responses[callCount % responses.count]
        callCount += 1
        return r
    }

    // Stubs for the rest of the protocol.
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult {
        let out = try await transform(text: text, prompt: prompt)
        return LLMResult(output: out, provider: "test", model: "test", latencyMs: 0)
    }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult {
        LLMFormatterResult(
            result: LLMResult(output: "", provider: "test", model: "test", latencyMs: 0),
            operationID: "test",
            inputChars: 0,
            outputChars: 0,
            inputTruncated: false,
            defaultPromptUsed: defaultPromptUsed,
            messageCount: 0
        )
    }
}

private final class FailingLLM: LLMServiceProtocol, @unchecked Sendable {
    func transform(text: String, prompt: String) async throws -> String {
        throw LLMError.notConfigured
    }
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { throw LLMError.notConfigured }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) async throws -> String { throw LLMError.notConfigured }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { throw LLMError.notConfigured }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { throw LLMError.notConfigured }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage]) async throws -> LLMResult { throw LLMError.notConfigured }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult { throw LLMError.notConfigured }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult { throw LLMError.notConfigured }
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Snap { let done: Int; let total: Int }
    private let lock = NSLock()
    private var snaps: [Snap] = []
    func record(done: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        snaps.append(Snap(done: done, total: total))
    }
    func snapshot() -> [Snap] {
        lock.lock(); defer { lock.unlock() }
        return snaps
    }
}
