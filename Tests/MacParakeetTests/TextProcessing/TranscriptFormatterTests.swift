import XCTest
@testable import MacParakeetCore
import OSLog

final class TranscriptFormatterTests: XCTestCase {
    private let logger = Logger(subsystem: "com.macparakeet.tests", category: "TranscriptFormatterTests")

    func testSkippedWhenFormatterDisabledDoesNotCallLLM() async throws {
        let mockLLMService = MockLLMService()
        let formatter = makeFormatter(llmService: mockLLMService, shouldUseAIFormatter: { false })

        let outcome = try await format(formatter, text: "hello world")

        XCTAssertNil(outcome.text)
        XCTAssertNil(outcome.run)
        XCTAssertNil(outcome.resolution)
        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 0)
    }

    func testTranscriptionLaneSkipsWhenInputExceedsMaxInputChars() async throws {
        let mockLLMService = MockLLMService()
        let formatter = makeFormatter(llmService: mockLLMService)
        let longText = String(repeating: "a", count: AIFormatter.maxTranscriptionInputChars + 1)

        let outcome = try await format(
            formatter,
            text: longText,
            lane: .transcription
        )

        XCTAssertNil(outcome.text)
        XCTAssertNil(outcome.run)
        XCTAssertNil(outcome.resolution)
        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 0)
    }

    func testDictationLaneFormatsLongInputWithoutCap() async throws {
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "  formatted long transcript  "
        let formatter = makeFormatter(llmService: mockLLMService)
        let longText = String(repeating: "a", count: AIFormatter.maxTranscriptionInputChars + 1)

        let outcome = try await format(
            formatter,
            text: longText,
            lane: .dictation
        )

        XCTAssertEqual(outcome.text, "formatted long transcript")
        XCTAssertNotNil(outcome.run)
        XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 1)
        XCTAssertEqual(mockLLMService.lastFormattedTranscript, longText)
    }

    func testSuccessReturnsTrimmedTextRunAndResolution() async throws {
        let mockLLMService = MockLLMService()
        mockLLMService.formatTranscriptResult = "\ncleaned text\n"
        let formatter = makeFormatter(llmService: mockLLMService)
        let dictationID = UUID()
        let profileID = UUID()
        let resolution = AIFormatterPromptResolution(
            promptTemplate: "Rewrite for Slack.",
            matchKind: .exactApp,
            profileID: profileID,
            profileName: "Slack",
            profileOrigin: .custom
        )

        let outcome = try await format(
            formatter,
            text: "raw text",
            runSource: LLMRunSource(dictationId: dictationID),
            lane: .dictation,
            promptTemplate: resolution.promptTemplate,
            resolution: resolution
        )

        XCTAssertEqual(outcome.text, "cleaned text")
        let run = try XCTUnwrap(outcome.run)
        XCTAssertEqual(run.feature, .formatterDictation)
        XCTAssertEqual(run.status, .succeeded)
        XCTAssertEqual(run.dictationId, dictationID)
        XCTAssertEqual(run.inputChars, "raw text".count)
        XCTAssertEqual(outcome.resolution, resolution)
        XCTAssertEqual(mockLLMService.lastFormatterSource, .dictation)
        XCTAssertEqual(mockLLMService.lastFormatterPromptTemplate, resolution.promptTemplate)
        XCTAssertEqual(mockLLMService.lastFormatterDefaultPromptUsed, false)
    }

    func testFailureReturnsFallbackOutcomeFailedRunAndPostsWarning() async throws {
        let mockLLMService = MockLLMService()
        mockLLMService.errorToThrow = LLMError.formatterTruncated
        let formatter = makeFormatter(llmService: mockLLMService)
        let transcriptionID = UUID()
        let warningPosted = expectation(description: "AI formatter warning posted")
        var warningMessage: String?
        let observer = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterWarning,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "transcription" else { return }
            warningMessage = notification.userInfo?["message"] as? String
            warningPosted.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let outcome = try await format(
            formatter,
            text: "hello world",
            runSource: LLMRunSource(transcriptionId: transcriptionID),
            lane: .transcription
        )

        await fulfillment(of: [warningPosted], timeout: 1.0)
        XCTAssertNil(outcome.text)
        XCTAssertNil(outcome.resolution)
        XCTAssertEqual(warningMessage, "AI formatter output was incomplete. Used standard cleanup.")
        let run = try XCTUnwrap(outcome.run)
        XCTAssertEqual(run.feature, .formatterTranscription)
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.transcriptionId, transcriptionID)
        XCTAssertEqual(run.inputChars, "hello world".count)
        XCTAssertEqual(run.outputChars, 0)
        XCTAssertEqual(run.defaultPromptUsed, true)
        XCTAssertNotNil(run.errorType)
    }

    func testCancellationErrorIsRethrown() async throws {
        let mockLLMService = MockLLMService()
        mockLLMService.errorToThrow = CancellationError()
        let formatter = makeFormatter(llmService: mockLLMService)

        do {
            _ = try await format(formatter, text: "hello world")
            XCTFail("Expected cancellation to be rethrown")
        } catch is CancellationError {
            XCTAssertEqual(mockLLMService.formatTranscriptCallCount, 1)
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testDictationLanePostsLifecycleNotifications() async throws {
        let mockLLMService = MockLLMService()
        let formatter = makeFormatter(llmService: mockLLMService)
        let started = expectation(description: "AI formatter start posted")
        let finished = expectation(description: "AI formatter finish posted")
        var events: [String] = []
        let startObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterDidStart,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "dictation" else { return }
            events.append("start")
            started.fulfill()
        }
        let finishObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterDidFinish,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "dictation" else { return }
            events.append("finish")
            finished.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(startObserver)
            NotificationCenter.default.removeObserver(finishObserver)
        }

        _ = try await format(
            formatter,
            text: "hello world",
            lane: .dictation
        )

        await fulfillment(of: [started, finished], timeout: 1.0)
        XCTAssertEqual(events, ["start", "finish"])
    }

    func testTranscriptionLaneDoesNotPostLifecycleNotifications() async throws {
        let mockLLMService = MockLLMService()
        let formatter = makeFormatter(llmService: mockLLMService)
        let started = expectation(description: "AI formatter start not posted")
        started.isInverted = true
        let finished = expectation(description: "AI formatter finish not posted")
        finished.isInverted = true
        let startObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterDidStart,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "transcription" else { return }
            started.fulfill()
        }
        let finishObserver = NotificationCenter.default.addObserver(
            forName: .macParakeetAIFormatterDidFinish,
            object: nil,
            queue: nil
        ) { notification in
            guard let source = notification.userInfo?["source"] as? String, source == "transcription" else { return }
            finished.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(startObserver)
            NotificationCenter.default.removeObserver(finishObserver)
        }

        _ = try await format(
            formatter,
            text: "hello world",
            lane: .transcription
        )

        await fulfillment(of: [started, finished], timeout: 0.1)
    }

    private func makeFormatter(
        llmService: LLMServiceProtocol?,
        shouldUseAIFormatter: @escaping @Sendable () -> Bool = { true }
    ) -> TranscriptFormatter {
        TranscriptFormatter(
            llmService: llmService,
            shouldUseAIFormatter: shouldUseAIFormatter,
            logger: logger
        )
    }

    private func format(
        _ formatter: TranscriptFormatter,
        text: String,
        runSource: LLMRunSource? = LLMRunSource(dictationId: UUID()),
        lane: TranscriptFormatter.Lane = .dictation,
        promptTemplate: String = AIFormatter.defaultPromptTemplate,
        resolution: AIFormatterPromptResolution? = nil
    ) async throws -> FormatterOutcome {
        try await formatter.format(
            text,
            runSource: runSource,
            lane: lane,
            resolvePrompt: { (promptTemplate, resolution) }
        )
    }
}
