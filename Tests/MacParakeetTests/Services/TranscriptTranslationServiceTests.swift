import XCTest
@testable import MacParakeetCore

final class TranscriptTranslationServiceTests: XCTestCase {
    private var llm: MockLLMService!
    private var service: TranscriptTranslationService!

    override func setUp() {
        llm = MockLLMService()
        service = TranscriptTranslationService(llmService: llm)
    }

    /// Echoes every numbered input line back as `[n] <prefix><text>`.
    private func echoTranslations(prefix: String) -> (String, String?) throws -> String {
        { transcript, _ in
            transcript.split(separator: "\n").map { line in
                let close = line.firstIndex(of: "]")!
                let marker = line[...close]
                let text = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                return "\(marker) \(prefix)\(text)"
            }.joined(separator: "\n")
        }
    }

    // MARK: - Parsing

    func testParseNumberedLinesMapsMarkersToZeroBasedIndexes() {
        let parsed = TranscriptTranslationService.parseNumberedLines(
            "[1] Hallo\n[2] Wie geht es dir?",
            expectedCount: 2
        )
        XCTAssertEqual(parsed, [0: "Hallo", 1: "Wie geht es dir?"])
    }

    func testParseNumberedLinesIgnoresPreambleAndOutOfRangeMarkers() {
        let parsed = TranscriptTranslationService.parseNumberedLines(
            "Here is the translation:\n[1] Hallo\n[7] Extra\n[2] Welt",
            expectedCount: 2
        )
        XCTAssertEqual(parsed, [0: "Hallo", 1: "Welt"])
    }

    func testParseNumberedLinesJoinsContinuationLines() {
        let parsed = TranscriptTranslationService.parseNumberedLines(
            "[1] Erste Zeile\nFortsetzung\n[2] Zweite",
            expectedCount: 2
        )
        XCTAssertEqual(parsed[0], "Erste Zeile Fortsetzung")
        XCTAssertEqual(parsed[1], "Zweite")
    }

    func testParseNumberedLinesAcceptsPersianDigitMarkers() {
        let parsed = TranscriptTranslationService.parseNumberedLines(
            "[۱] سلام\n[۲] حال شما چطور است؟",
            expectedCount: 2
        )
        XCTAssertEqual(parsed, [0: "سلام", 1: "حال شما چطور است؟"])
    }

    func testParseNumberedLinesKeepsFirstOccurrenceOfRepeatedMarker() {
        let parsed = TranscriptTranslationService.parseNumberedLines(
            "[1] Hallo\n[1] Nochmal",
            expectedCount: 1
        )
        XCTAssertEqual(parsed, [0: "Hallo"])
    }

    // MARK: - Batching

    func testBatchRangesSplitOnSegmentCountAndCoverEverySegment() {
        let segments = (0..<95).map { TranslationSourceSegment(text: "line \($0)") }
        let ranges = TranscriptTranslationService.batchRanges(for: segments)

        XCTAssertEqual(ranges.map(\.count), [40, 40, 15])
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, 95)
    }

    func testBatchRangesSplitOnCharacterBudget() {
        let long = String(repeating: "a", count: 1_000)
        let segments = (0..<5).map { _ in TranslationSourceSegment(text: long) }
        let ranges = TranscriptTranslationService.batchRanges(for: segments)

        XCTAssertEqual(ranges.map(\.count), [2, 2, 1])
    }

    func testBatchRangesKeepsOversizedSegmentInItsOwnBatch() {
        let segments = [
            TranslationSourceSegment(text: String(repeating: "a", count: 5_000)),
            TranslationSourceSegment(text: "short"),
        ]
        XCTAssertEqual(TranscriptTranslationService.batchRanges(for: segments), [0..<1, 1..<2])
    }

    // MARK: - Translating

    func testTranslatePreservesTimingSpeakerAndOrderAcrossBatches() async throws {
        llm.promptResultHandler = echoTranslations(prefix: "DE:")
        let segments = (0..<50).map {
            TranslationSourceSegment(startMs: $0 * 1000, endMs: $0 * 1000 + 900, speakerId: "S1", text: "line \($0)")
        }
        let batches = BatchRecorder()

        let result = try await service.translate(segments, to: .german) { batch in
            await batches.record(batch.count)
        }

        XCTAssertEqual(result.count, 50)
        XCTAssertEqual(result[0], TranslatedSegment(startMs: 0, endMs: 900, speakerId: "S1", text: "DE:line 0"))
        XCTAssertEqual(result[49].text, "DE:line 49")
        XCTAssertEqual(result[49].startMs, 49_000)
        XCTAssertEqual(llm.summarizeCallCount, 2)
        let recorded = await batches.counts
        XCTAssertEqual(recorded, [40, 10])
    }

    func testTranslateNamesTargetLanguageInSystemPrompt() async throws {
        llm.promptResultHandler = echoTranslations(prefix: "")
        _ = try await service.translate([TranslationSourceSegment(text: "Hello")], to: .persian)

        let prompt = try XCTUnwrap(llm.lastSummarySystemPrompt)
        XCTAssertTrue(prompt.contains("Persian"))
        XCTAssertTrue(prompt.contains("فارسی"))
        XCTAssertEqual(llm.lastSummaryTranscript, "[1] Hello")
    }

    func testTranslateRetriesOnlyTheMissingLines() async throws {
        var calls: [String] = []
        llm.promptResultHandler = { transcript, _ in
            calls.append(transcript)
            // First response drops line 2; the retry receives it renumbered as [1].
            return calls.count == 1 ? "[1] eins\n[3] drei" : "[1] zwei"
        }
        let segments = ["one", "two", "three"].map { TranslationSourceSegment(text: $0) }

        let result = try await service.translate(segments, to: .german)

        XCTAssertEqual(result.map(\.text), ["eins", "zwei", "drei"])
        XCTAssertEqual(calls, ["[1] one\n[2] two\n[3] three", "[1] two"])
    }

    func testTranslateThrowsWhenLinesAreStillMissingAfterRetry() async {
        llm.promptResultHandler = { _, _ in "I cannot translate this." }

        do {
            _ = try await service.translate([TranslationSourceSegment(text: "one")], to: .english)
            XCTFail("Expected incompleteResponse")
        } catch {
            XCTAssertEqual(error as? TranscriptTranslationError, .incompleteResponse)
        }
    }

    func testTranslateFlattensNewlinesInsideASegment() async throws {
        llm.promptResultHandler = echoTranslations(prefix: "")
        _ = try await service.translate([TranslationSourceSegment(text: "first\nsecond")], to: .english)
        XCTAssertEqual(llm.lastSummaryTranscript, "[1] first second")
    }

    // MARK: - Markdown

    func testTranslateMarkdownKeepsStructureAndSkipsCodeAndBlankLines() async throws {
        llm.promptResultHandler = echoTranslations(prefix: "DE:")
        let markdown = """
            ## Summary

            - First point
              - Nested point
            ---
            ```
            let code = 1
            ```
            Closing line.
            """

        let result = try await service.translateMarkdown(markdown, to: .german)

        XCTAssertEqual(
            result,
            """
            DE:## Summary

            DE:- First point
              DE:- Nested point
            ---
            ```
            let code = 1
            ```
            DE:Closing line.
            """
        )
        XCTAssertEqual(
            llm.lastSummaryTranscript,
            "[1] ## Summary\n[2] - First point\n[3] - Nested point\n[4] Closing line."
        )
    }

    func testTranslateMarkdownWithNothingToTranslateMakesNoRequest() async throws {
        let result = try await service.translateMarkdown("\n---\n", to: .german)
        XCTAssertEqual(result, "\n---\n")
        XCTAssertEqual(llm.summarizeCallCount, 0)
    }
}

private actor BatchRecorder {
    private(set) var counts: [Int] = []
    func record(_ count: Int) { counts.append(count) }
}
