import XCTest
import OSLog
@testable import MacParakeetCore

final class MeetingTitleGeneratorTests: XCTestCase {
    func testShouldReplaceTimestampFallbackMeetingTitles() {
        XCTAssertTrue(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting"))
        XCTAssertTrue(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting Jun 17, 2026 at 09:59"))
        XCTAssertTrue(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting June 17, 2026 at 9:59 AM"))
        XCTAssertTrue(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting 6/17/2026"))
    }

    func testShouldPreserveCustomOrCalendarMeetingTitles() {
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Customer Expansion Review"))
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Weekly Product Sync"))
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting Notes for Acme"))
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting Product Review"))
        // A deliberate calendar/custom title that merely contains a year must not
        // be mistaken for the timestamp fallback and overwritten.
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting 2026 Budget Planning"))
        XCTAssertFalse(MeetingTitleGenerator.shouldReplaceFallbackMeetingTitle("Meeting Q1 2026 Kickoff"))
    }

    func testValidatedTitleNormalizesSimpleProviderResponses() throws {
        XCTAssertEqual(
            try MeetingTitleGenerator.validatedTitle(from: #"  "Product Roadmap Review."  "#),
            "Product Roadmap Review"
        )
        XCTAssertEqual(
            try MeetingTitleGenerator.validatedTitle(from: "- Customer Onboarding Risks"),
            "Customer Onboarding Risks"
        )
        XCTAssertEqual(
            try MeetingTitleGenerator.validatedTitle(from: "1. Mobile Beta Launch"),
            "Mobile Beta Launch"
        )
    }

    func testValidatedTitleAcceptsTopicYears() throws {
        for title in [
            "2027 Budget Review", "Q3 2026 Revenue Forecast", "CAPEX Plan for 2027", "План бюджета на 2027 год",
            "May 2027 Budget Review", "MAY 2027 Budget Review", "Budget Review for Sept. 2027",
        ] {
            XCTAssertEqual(try MeetingTitleGenerator.validatedTitle(from: title), title)
        }
    }

    func testValidatedTitleAcceptsMoreThanEightWordsWithinCharacterLimit() throws {
        for title in [
            "Plan for the next phase of the customer rollout",
            "План работы по проекту и задачи команды на следующий год",
        ] {
            XCTAssertEqual(try MeetingTitleGenerator.validatedTitle(from: title), title)
        }
    }

    func testValidatedTitleRejectsLowConfidenceResponses() {
        XCTAssertThrowsError(try MeetingTitleGenerator.validatedTitle(from: "Meeting"))
        XCTAssertThrowsError(try MeetingTitleGenerator.validatedTitle(from: "Discussion"))
        XCTAssertThrowsError(try MeetingTitleGenerator.validatedTitle(from: "NO_TITLE"))
        XCTAssertThrowsError(try MeetingTitleGenerator.validatedTitle(from: "Meeting Jun 17, 2026"))
        XCTAssertThrowsError(try MeetingTitleGenerator.validatedTitle(from: "Product Review\nCustomer Followup"))
        XCTAssertThrowsError(try MeetingTitleGenerator.validatedTitle(from: "One"))
        XCTAssertThrowsError(try MeetingTitleGenerator.validatedTitle(from: String(repeating: "Long topic ", count: 8)))
    }

    func testValidatedTitlePreservesCharacterLimitAndSpecificReasons() throws {
        let atLimit = "Budget " + String(repeating: "a", count: 63)
        XCTAssertEqual(try MeetingTitleGenerator.validatedTitle(from: atLimit), atLimit)
        let cases: [(String, MeetingTitleGenerator.RejectionReason)] = [
            (" ", .empty),
            ("Title one\nTitle two", .multiline),
            (atLimit + "a", .tooLong),
            ("One", .tooFewWords),
            ("NO_TITLE", .generic),
            ("Meeting notes", .generic),
            ("There is not enough context here", .generic),
            ("Meeting Jun 17, 2026", .dateTime),
            ("Meeting June 17", .dateTime),
            ("May 2027", .dateTime),
            ("Meeting May 2027", .dateTime),
            ("MEETING MAY 2027", .dateTime),
            ("June 17th, 2026", .dateTime),
            ("Meeting 17th June 2026", .dateTime),
            ("Meeting 17.06.2026", .dateTime),
            ("17.06.2026 Budget Review", .dateTime),
            ("Meeting 17-06-2026", .dateTime),
            ("Meeting 2026/06/17", .dateTime),
            ("Meeting 17 June 2026", .dateTime),
            ("Meeting 6/17/2026", .dateTime),
            ("Meeting 2026-06-17", .dateTime),
            ("Meeting at 10:01 AM", .dateTime),
        ]
        for (raw, reason) in cases {
            XCTAssertThrowsError(try MeetingTitleGenerator.validatedTitle(from: raw)) { error in
                XCTAssertEqual(error as? MeetingTitleGenerator.RejectionReason, reason, raw)
            }
        }
        XCTAssertEqual(try MeetingTitleGenerator.validatedTitle(from: "May Hiring Plan"), "May Hiring Plan")
        XCTAssertEqual(try MeetingTitleGenerator.validatedTitle(from: "Version 1.2.3 Rollout"), "Version 1.2.3 Rollout")
    }

    func testGenerationAcceptsTopicTitleWithoutRetry() async throws {
        let service = MockLLMService()
        service.summarizeResult = "Q3 2026 Revenue Forecast"
        let result = try await generate(makeGenerator(service))
        XCTAssertEqual(result, service.summarizeResult)
        XCTAssertEqual(service.summarizeCallCount, 1)
    }

    func testGenerationRetriesConnectionTimeoutAndCLIFailuresOnce() async throws {
        for error in [LLMError.connectionFailed("offline"), .requestTimedOut, .cliError("DNS failure")] {
            let service = MockLLMService()
            service.promptResultsQueue = [.failure(error), .success("2027 Budget Review")]
            let result = try await generate(makeGenerator(service))
            XCTAssertEqual(result, "2027 Budget Review")
            XCTAssertEqual(service.summarizeCallCount, 2)
        }
    }

    func testGenerationStopsAfterSecondFailure() async throws {
        let service = MockLLMService()
        service.errorToThrow = LLMError.cliError("offline")
        let result = try await generate(makeGenerator(service))
        XCTAssertNil(result)
        XCTAssertEqual(service.summarizeCallCount, 2)
    }

    func testGenerationDoesNotRetryPermanentFailures() async throws {
        for error in [
            LLMError.notConfigured, .authenticationFailed(nil), .contextTooLong, .rateLimited, .invalidResponse,
        ] {
            let service = MockLLMService()
            service.errorToThrow = error
            let result = try await generate(makeGenerator(service))
            XCTAssertNil(result)
            XCTAssertEqual(service.summarizeCallCount, 1)
        }
    }

    func testGenerationDoesNotRetryRejectedResponses() async throws {
        let service = MockLLMService()
        service.summarizeResult = "NO_TITLE"
        let result = try await generate(makeGenerator(service))
        XCTAssertNil(result)
        XCTAssertEqual(service.summarizeCallCount, 1)
    }

    func testGenerationSkipsDisabledMissingProviderShortTranscriptAndCustomTitles() async throws {
        let service = MockLLMService()
        let disabled = try await generate(makeGenerator(service, shouldGenerate: { false }))
        let noProvider = try await generate(makeGenerator(nil))
        let short = try await makeGenerator(service).generateTitle(transcript: "Too short", currentTitle: "Meeting")
        let custom = try await generate(makeGenerator(service), currentTitle: "Meeting 2026 Budget Planning")
        XCTAssertNil(disabled)
        XCTAssertNil(noProvider)
        XCTAssertNil(short)
        XCTAssertNil(custom)
        XCTAssertEqual(service.summarizeCallCount, 0)
    }

    func testGenerationPropagatesProviderCancellationWithoutRetry() async {
        let service = MockLLMService()
        service.errorToThrow = CancellationError()
        do {
            _ = try await generate(makeGenerator(service))
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(service.summarizeCallCount, 1)
    }

    func testCancellationAfterProviderReturnsDoesNotPublishOrRetry() async {
        for response: Result<String, Error> in [.success("2027 Budget Review"), .failure(LLMError.cliError("offline"))]
        {
            let service = MockLLMService()
            service.promptResultsQueue = [response]
            service.generatePromptResultHook = { withUnsafeCurrentTask { $0?.cancel() } }
            let generator = makeGenerator(service)
            let task = Task {
                try await generator.generateTitle(transcript: Self.transcript, currentTitle: "Meeting")
            }
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(service.summarizeCallCount, 1)
        }
    }

    func testGenerationRechecksOptOutBeforeRetryAndBeforeReturningTitle() async throws {
        for response: Result<String, Error> in [.success("2027 Budget Review"), .failure(LLMError.cliError("offline"))]
        {
            let enabled = TitleGenerationSwitch()
            let service = MockLLMService()
            service.promptResultsQueue = [response]
            service.generatePromptResultHook = { enabled.disable() }
            let result = try await generate(makeGenerator(service, shouldGenerate: { enabled.isEnabled }))
            XCTAssertNil(result)
            XCTAssertEqual(service.summarizeCallCount, 1)
        }
    }

    private static let transcript = "We discussed the budget for the upcoming year and agreed on the hiring plan."

    private func generate(_ generator: MeetingTitleGenerator, currentTitle: String = "Meeting") async throws -> String?
    {
        try await generator.generateTitle(transcript: Self.transcript, currentTitle: currentTitle)
    }

    private func makeGenerator(
        _ service: LLMServiceProtocol?, shouldGenerate: @escaping @Sendable () -> Bool = { true }
    ) -> MeetingTitleGenerator {
        MeetingTitleGenerator(
            llmService: service, shouldGenerate: shouldGenerate,
            logger: Logger(subsystem: "com.macparakeet.tests", category: "MeetingTitleGeneratorTests")
        )
    }
}

private final class TitleGenerationSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = true

    var isEnabled: Bool { lock.withLock { enabled } }
    func disable() { lock.withLock { enabled = false } }
}
