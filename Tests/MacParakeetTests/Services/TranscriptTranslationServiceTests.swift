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
            "[1] Hallo\n[1] Nochmal\nextra detail\n[2] Welt\ncontinued",
            expectedCount: 2
        )
        XCTAssertEqual(parsed, [0: "Hallo", 1: "Welt continued"])
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

    func testOversizedSegmentUsesBoundedRequestsAndReassemblesOriginalMetadata() async throws {
        var requests: [String] = []
        llm.promptResultHandler = { transcript, _ in
            requests.append(transcript)
            return "[1] part-\(requests.count)"
        }
        let source = TranslationSourceSegment(
            startMs: 1_000, endMs: 15_000, speakerId: "speaker-1", text: String(repeating: "word ", count: 1_100))
        let batches = BatchRecorder()

        let result = try await service.translate([source], to: .german) { batch in
            await batches.record(batch.count)
        }

        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(
            requests.allSatisfy { $0.dropFirst("[1] ".count).count <= TranscriptTranslationService.maxBatchCharacters })
        let sourceParts = requests.map { String($0.dropFirst("[1] ".count)) }
        XCTAssertEqual(sourceParts.joined(separator: " "), source.text.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(
            result,
            [TranslatedSegment(startMs: 1_000, endMs: 15_000, speakerId: "speaker-1", text: "part-1 part-2 part-3")])
        let counts = await batches.counts
        XCTAssertEqual(counts, [1], "Progress remains one completed original segment")
    }

    func testFailureInLaterLongSegmentPartPublishesNoPartialOriginalSegment() async {
        var calls = 0
        llm.promptResultHandler = { _, _ in
            calls += 1
            if calls == 1 { return "[1] First part" }
            throw LLMError.contextTooLong
        }
        let batches = BatchRecorder()
        do {
            _ = try await service.translate(
                [TranslationSourceSegment(text: String(repeating: "x", count: 5_000))], to: .german
            ) { batch in
                await batches.record(batch.count)
            }
            XCTFail("Expected later part failure")
        } catch LLMError.contextTooLong {
            // A failed later chunk must not publish the earlier partial text.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(calls, 2)
        let counts = await batches.counts
        XCTAssertTrue(counts.isEmpty)
    }

    func testCancellationFromFinalProgressCallbackDoesNotReturnSuccess() async {
        llm.promptResultHandler = echoTranslations(prefix: "DE:")
        let service = self.service!
        let task = Task {
            try await service.translate([TranslationSourceSegment(text: "Hello")], to: .german) { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            XCTFail("Cancellation while publishing the final batch must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testTranslateMarkdownPreservesTrailingHardBreakSpacesAndTabs() async throws {
        llm.promptResultHandler = echoTranslations(prefix: "DE:")
        let markdown = "  First line  \nSecond line\t\n\n```swift\nlet x = 1  \n```"
        let result = try await service.translateMarkdown(markdown, to: .german)
        XCTAssertEqual(result, "  DE:First line  \nDE:Second line\t\n\n```swift\nlet x = 1  \n```")
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

    func testTranslateMarkdownKeepsShorterMixedAndInfoBearingFencesInsideCode() async throws {
        llm.promptResultHandler = echoTranslations(prefix: "DE:")
        for marker in ["`", "~"] {
            let opposite = marker == "`" ? "~" : "`"
            let fence = String(repeating: marker, count: 4)
            let lines = [
                "Before",
                fence + "swift",
                "private code before shorter fence",
                String(repeating: marker, count: 3),
                "private code after shorter fence",
                String(repeating: opposite, count: 4),
                "private code after different marker",
                fence + " not a closing fence",
                "private code after info-bearing fence",
                String(repeating: marker, count: 5) + " \t",
                "After",
            ]
            let result = try await service.translateMarkdown(lines.joined(separator: "\n"), to: .german)
            var expected = lines
            expected[0] = "DE:Before"
            expected[expected.count - 1] = "DE:After"
            XCTAssertEqual(result, expected.joined(separator: "\n"), "Fence marker: \(marker)")
            XCTAssertEqual(llm.lastSummaryTranscript, "[1] Before\n[2] After", "Code must never reach the provider")
        }
    }

    func testTranslateMarkdownUnclosedFenceKeepsRemainingCodeLocal() async throws {
        llm.promptResultHandler = echoTranslations(prefix: "DE:")
        let markdown = "Before\n````\nprivate code\n```\nstill private code"
        let result = try await service.translateMarkdown(markdown, to: .german)
        XCTAssertEqual(result, "DE:Before\n````\nprivate code\n```\nstill private code")
        XCTAssertEqual(llm.lastSummaryTranscript, "[1] Before")
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
