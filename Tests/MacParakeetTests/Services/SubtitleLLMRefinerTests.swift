import XCTest
@testable import MacParakeetCore

final class SubtitleLLMRefinerTests: XCTestCase {

    // MARK: - Parser

    func testParseResponseExtractsTaggedLines() {
        let response = """
        [CUE 1] hello there
        [CUE 2] how are you
        [CUE 3] doing today
        """
        let parsed = SubtitleLLMRefiner.parseResponse(
            response,
            expectedCount: 3,
            fallback: ["a", "b", "c"]
        )
        XCTAssertEqual(parsed, ["hello there", "how are you", "doing today"])
    }

    func testParseResponseTolerantOfExtraProse() {
        let response = """
        Sure! Here are the refined cues:

        [CUE 1] hello there
        [CUE 2] how are you

        Let me know if that helps.
        """
        let parsed = SubtitleLLMRefiner.parseResponse(
            response,
            expectedCount: 2,
            fallback: ["a", "b"]
        )
        XCTAssertEqual(parsed, ["hello there", "how are you"])
    }

    func testParseResponseFallsBackForMissingTags() {
        let response = """
        [CUE 1] only the first one
        """
        let parsed = SubtitleLLMRefiner.parseResponse(
            response,
            expectedCount: 3,
            fallback: ["a", "b", "c"]
        )
        XCTAssertEqual(parsed, ["only the first one", "b", "c"])
    }

    func testParseResponseFallsBackOnGarbageInput() {
        let response = "I refuse to follow the format."
        let parsed = SubtitleLLMRefiner.parseResponse(
            response,
            expectedCount: 2,
            fallback: ["original 1", "original 2"]
        )
        XCTAssertEqual(parsed, ["original 1", "original 2"])
    }

    func testParseResponseIgnoresOutOfRangeIndices() {
        let response = """
        [CUE 1] valid
        [CUE 99] out of range
        """
        let parsed = SubtitleLLMRefiner.parseResponse(
            response,
            expectedCount: 2,
            fallback: ["a", "b"]
        )
        XCTAssertEqual(parsed, ["valid", "b"])
    }

    // MARK: - Refine integration

    func testRefineFiresProgressForEveryBatch() async throws {
        let llm = TaggedEchoLLM()
        let refiner = SubtitleLLMRefiner(llmService: llm, batchSize: 4, maxConcurrency: 2)

        let cues = (0..<10).map {
            ExportService.SubtitleCue(startMs: $0 * 1000, endMs: $0 * 1000 + 500, text: "cue \($0)", speakerId: nil)
        }

        let progress = ProgressRecorder()
        _ = try await refiner.refine(
            cues: cues,
            config: .default,
            onProgress: { done, total in progress.record(done: done, total: total) }
        )

        let snapshots = progress.snapshot()
        // 10 cues / batchSize 4 → 3 batches
        XCTAssertEqual(snapshots.count, 3)
        XCTAssertEqual(snapshots.last?.total, 3)
        XCTAssertEqual(snapshots.last?.done, 3)
        let dones = snapshots.map(\.done)
        XCTAssertEqual(dones, dones.sorted())
    }

    func testRefinePreservesTimingsAndOrder() async throws {
        let llm = TaggedEchoLLM()
        let refiner = SubtitleLLMRefiner(llmService: llm, batchSize: 3, maxConcurrency: 2)

        let cues = (0..<7).map {
            ExportService.SubtitleCue(startMs: $0 * 1000, endMs: $0 * 1000 + 500, text: "cue \($0)", speakerId: nil)
        }
        let result = try await refiner.refine(cues: cues, config: .default)

        XCTAssertEqual(result.count, cues.count)
        for (i, cue) in result.enumerated() {
            XCTAssertEqual(cue.startMs, cues[i].startMs)
            XCTAssertEqual(cue.endMs, cues[i].endMs)
        }
    }

    // MARK: - Sanitisation

    func testCleanTextStripsHTMLTags() {
        let dirty = "From there, we're gonna take a little<br>active recovery"
        XCTAssertEqual(SubtitleLLMRefiner.cleanText(dirty), "From there, we're gonna take a little active recovery")
    }

    func testCleanTextStripsMarkupKeepsContent() {
        let dirty = "<i>Welcome</i> to <b>class</b>"
        XCTAssertEqual(SubtitleLLMRefiner.cleanText(dirty), "Welcome to class")
    }

    func testRefineReWrapsLongOneLineLLMOutput() async throws {
        let longText = "What is going on, Echelon, and welcome in to your intervals in"
        let llm = FixedLLM(refinedText: longText)
        let refiner = SubtitleLLMRefiner(llmService: llm, batchSize: 4, maxConcurrency: 1)

        let cues = (0..<3).map {
            ExportService.SubtitleCue(startMs: $0 * 1000, endMs: $0 * 1000 + 500, text: "placeholder \($0)", speakerId: nil)
        }
        let result = try await refiner.refine(cues: cues, config: .default)

        // Cue 0 should have been re-wrapped into two lines (max 42 chars/line).
        XCTAssertTrue(result[0].text.contains("\n"),
            "Long single-line LLM output should be wrapped into two lines, got: \(result[0].text)")
        let lines = result[0].text.split(separator: "\n").map(String.init)
        for line in lines {
            XCTAssertLessThanOrEqual(line.count, 42,
                "Each line should fit within maxCharsPerLine after re-wrap, got \(line.count) chars: \(line)")
        }
    }

    func testRefineStripsBRTagsBeforeWrapping() async throws {
        let dirty = "From there, we're gonna take a little<br>active recovery"
        let llm = FixedLLM(refinedText: dirty)
        let refiner = SubtitleLLMRefiner(llmService: llm, batchSize: 4, maxConcurrency: 1)

        let cues = (0..<3).map {
            ExportService.SubtitleCue(startMs: $0 * 1000, endMs: $0 * 1000 + 500, text: "placeholder", speakerId: nil)
        }
        let result = try await refiner.refine(cues: cues, config: .default)

        // No `<br>` should survive into the cue text.
        XCTAssertFalse(result[0].text.contains("<br>"),
            "<br> tag should be stripped from refined text, got: \(result[0].text)")
        XCTAssertFalse(result[0].text.contains("<"),
            "No HTML tags should remain in refined text")
    }

    func testRefineSkipsWhenTooFewCues() async throws {
        let llm = FailingLLM()
        let refiner = SubtitleLLMRefiner(llmService: llm, batchSize: 8, maxConcurrency: 4)
        let cues = [
            ExportService.SubtitleCue(startMs: 0, endMs: 500, text: "a", speakerId: nil),
            ExportService.SubtitleCue(startMs: 500, endMs: 1000, text: "b", speakerId: nil),
        ]
        let result = try await refiner.refine(cues: cues, config: .default)
        XCTAssertEqual(result.map(\.text), ["a", "b"])
        XCTAssertEqual(llm.callCount, 0)
    }
}

// MARK: - Test doubles

/// Echoes the `[CUE N] text` lines found inside the prompt's "CUES TO REFINE"
/// block back to the caller. Lets us verify the refiner threads cue text
/// through to the right index without any real LLM round-trip.
private final class TaggedEchoLLM: LLMServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var callCount = 0

    func transform(text: String, prompt: String) async throws -> String {
        lock.lock(); callCount += 1; lock.unlock()
        var output: [String] = []
        var inCueBlock = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("CUES TO REFINE:") { inCueBlock = true; continue }
            if inCueBlock {
                if s.isEmpty { break }
                output.append(s)
            }
        }
        return output.joined(separator: "\n")
    }

    // Unused protocol surface — minimal stubs.
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
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

/// Returns the same refined text for every cue in the batch — useful for
/// asserting how the refiner sanitises / wraps LLM output downstream.
private final class FixedLLM: LLMServiceProtocol, @unchecked Sendable {
    private let refinedText: String
    init(refinedText: String) { self.refinedText = refinedText }

    func transform(text: String, prompt: String) async throws -> String {
        var output: [String] = []
        var inCueBlock = false
        var cueNum = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("CUES TO REFINE:") { inCueBlock = true; continue }
            if inCueBlock {
                if s.isEmpty { break }
                cueNum += 1
                output.append("[CUE \(cueNum)] \(refinedText)")
            }
        }
        return output.joined(separator: "\n")
    }

    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { "" }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { "" }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { "" }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult { LLMResult(output: "", provider: "test", model: "test", latencyMs: 0) }
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
    private let lock = NSLock()
    private(set) var callCount = 0

    func transform(text: String, prompt: String) async throws -> String {
        lock.lock(); callCount += 1; lock.unlock()
        throw LLMError.notConfigured
    }

    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String { throw LLMError.notConfigured }
    func chat(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> String { throw LLMError.notConfigured }
    func formatTranscript(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> String { throw LLMError.notConfigured }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func chatStream(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult { throw LLMError.notConfigured }
    func chatDetailed(question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource) async throws -> LLMResult { throw LLMError.notConfigured }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult { throw LLMError.notConfigured }
    func formatTranscriptDetailed(transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool) async throws -> LLMFormatterResult { throw LLMError.notConfigured }
}

private final class ProgressRecorder: @unchecked Sendable {
    struct Snapshot { let done: Int; let total: Int }
    private let lock = NSLock()
    private var snapshots: [Snapshot] = []

    func record(done: Int, total: Int) {
        lock.lock(); defer { lock.unlock() }
        snapshots.append(Snapshot(done: done, total: total))
    }

    func snapshot() -> [Snapshot] {
        lock.lock(); defer { lock.unlock() }
        return snapshots
    }
}
