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
        XCTAssertTrue((requests[0].systemPrompt ?? "").lowercased().contains("formal professional tone"))
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

    // MARK: - Preamble handling

    func testFormalModeFallsBackWhenLLMReturnsAssistantPreamble() async {
        let mockLLM = MockLLMService()
        await mockLLM.configureResponse(text: "Certainly! Here's a formal version of your text:\n\nThe project is on track.")
        let service = TextRefinementService(llmService: mockLLM)

        let result = await service.refine(
            rawText: "um the project is on track",
            mode: .formal,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "The project is on track")
        XCTAssertEqual(result.path, .llmFallback)
        XCTAssertEqual(result.fallbackReason, "LLM output contained assistant preamble")
    }

    func testFormalModeKeepsLegitimateCertainlySentence() async {
        let mockLLM = MockLLMService()
        await mockLLM.configureResponse(text: "Certainly this sentence should stay as-is.")
        let service = TextRefinementService(llmService: mockLLM)

        let result = await service.refine(
            rawText: "hello world",
            mode: .formal,
            customWords: [],
            snippets: []
        )

        XCTAssertEqual(result.text, "Certainly this sentence should stay as-is.")
        XCTAssertEqual(result.path, .llm)
    }

    func testHasAssistantPreambleDetectsCommonChatter() {
        let input = "Sure. Here's the rewritten text:\n\nI am going to proceed with the next step."
        XCTAssertTrue(TextRefinementService.hasAssistantPreamble(input))
    }

    func testHasAssistantPreambleIgnoresLegitimateLeadingPhrases() {
        XCTAssertFalse(TextRefinementService.hasAssistantPreamble("Here is what I think: we should merge now."))
        XCTAssertFalse(TextRefinementService.hasAssistantPreamble("Certainly this sentence should stay as-is."))
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
