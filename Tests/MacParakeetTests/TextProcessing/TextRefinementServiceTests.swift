import XCTest
@testable import MacParakeetCore

final class TextRefinementServiceTests: XCTestCase {
    func testCleanModeReturnsDeterministicText() async {
        let service = TextRefinementService()
        let result = await service.refine(
            rawText: "um hello world",
            mode: .clean,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.path, .deterministic)
    }

    func testFormalModeUsesLLMWhenAvailable() async {
        let mockLLM = MockLLMService()
        await mockLLM.configureResponse(text: "Hello world from LLM.")
        let service = TextRefinementService(llmService: mockLLM)

        let result = await service.refine(
            rawText: "hello world",
            mode: .formal,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "Hello world from LLM.")
        XCTAssertEqual(result.path, .llm)
        let requests = await mockLLM.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests[0].prompt.contains("Rewrite"))
    }

    func testFormalModeFallsBackWhenLLMFails() async {
        let mockLLM = MockLLMService()
        await mockLLM.configureError(LLMServiceError.generationFailed("boom"))
        let service = TextRefinementService(llmService: mockLLM)

        let result = await service.refine(
            rawText: "um hello world",
            mode: .formal,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "Hello world")
        XCTAssertEqual(result.path, .llmFallback)
        XCTAssertNotNil(result.fallbackReason)
    }

    // MARK: - Preamble stripping

    func testStripPreambleCertainly() {
        let input = "Certainly! Here's a formal version of your text:\n\n\"The project is on track.\""
        XCTAssertEqual(TextRefinementService.stripPreamble(input), "The project is on track.")
    }

    func testStripPreambleHereIs() {
        let input = "Here is a rewritten version:\n\nThe project is on track."
        XCTAssertEqual(TextRefinementService.stripPreamble(input), "The project is on track.")
    }

    func testStripPreambleCleanTextUnchanged() {
        let input = "The project is on track."
        XCTAssertEqual(TextRefinementService.stripPreamble(input), "The project is on track.")
    }

    func testStripPreambleSmartQuotes() {
        let input = "\u{201C}The project is on track.\u{201D}"
        XCTAssertEqual(TextRefinementService.stripPreamble(input), "The project is on track.")
    }

    func testStripPreambleSureHereIs() {
        let input = "Sure. Here's the rewritten text:\n\nI am going to proceed with the next step."
        XCTAssertEqual(TextRefinementService.stripPreamble(input), "I am going to proceed with the next step.")
    }

    func testFormalModeSkipsLLMWhenDeterministicTextIsEmpty() async {
        let mockLLM = MockLLMService()
        await mockLLM.configureResponse(text: "Should not be used")
        let service = TextRefinementService(llmService: mockLLM)

        let result = await service.refine(
            rawText: "um uh uhh",
            mode: .formal,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.path, .deterministic)
        let requests = await mockLLM.requests
        XCTAssertEqual(requests.count, 0)
    }
}
