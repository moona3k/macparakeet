import XCTest
@testable import MacParakeetCore

final class LLMPromptBuilderTests: XCTestCase {
    func testFormalRefinePromptIncludesInput() {
        let task = LLMTask.refine(mode: .formal, input: "hello world")
        let system = LLMPromptBuilder.systemPrompt(for: task).lowercased()
        let user = LLMPromptBuilder.userPrompt(for: task)

        XCTAssertTrue(system.contains("professional"))
        XCTAssertTrue(user.contains("hello world"))
    }

    func testEmailRefinePromptMentionsEmail() {
        let task = LLMTask.refine(mode: .email, input: "quick update")
        let system = LLMPromptBuilder.systemPrompt(for: task).lowercased()
        let user = LLMPromptBuilder.userPrompt(for: task)

        XCTAssertTrue(system.contains("email"))
        XCTAssertTrue(user.contains("quick update"))
    }

    func testCodeRefinePromptPreservesTechnicalIntent() {
        let task = LLMTask.refine(mode: .code, input: "use var_name in if(x==1)")
        let system = LLMPromptBuilder.systemPrompt(for: task).lowercased()
        let user = LLMPromptBuilder.userPrompt(for: task)

        XCTAssertTrue(system.contains("code"))
        XCTAssertTrue(user.contains("var_name"))
    }

    func testCommandPromptContainsCommandAndSelectedText() {
        let task = LLMTask.commandTransform(
            command: "Translate to Spanish",
            selectedText: "Hello friend"
        )
        let user = LLMPromptBuilder.userPrompt(for: task)
        XCTAssertTrue(user.contains("Translate to Spanish"))
        XCTAssertTrue(user.contains("Hello friend"))
    }

    func testTranscriptChatPromptContainsContextAndQuestion() {
        let task = LLMTask.transcriptChat(
            question: "What was the main conclusion?",
            transcript: "We should ship the migration this week."
        )
        let system = LLMPromptBuilder.systemPrompt(for: task).lowercased()
        let user = LLMPromptBuilder.userPrompt(for: task)

        XCTAssertTrue(system.contains("provided transcript"))
        XCTAssertTrue(user.contains("main conclusion"))
        XCTAssertTrue(user.contains("ship the migration"))
    }
}
