import XCTest
@testable import CLI

final class LLMChatCommandTests: XCTestCase {
    func testComposeWithoutTranscriptUsesDirectQuestion() {
        let payload = LLMChatPromptComposer.compose(
            question: "What are the key points?",
            transcriptContext: nil
        )

        XCTAssertEqual(payload.prompt, "What are the key points?")
        XCTAssertEqual(payload.defaultSystemPrompt, LLMChatPromptComposer.defaultSystemPrompt)
    }

    func testLoadTranscriptContextAndComposeUsesTranscriptPrompt() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-chat-context-\(UUID().uuidString).txt")
        let transcript = String(repeating: "a", count: 13_000)
        try transcript.write(to: tempURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let context = try LLMChatPromptComposer.loadTranscriptContext(from: tempURL.path)
        let payload = LLMChatPromptComposer.compose(
            question: "Summarize this transcript",
            transcriptContext: context
        )

        XCTAssertNotNil(context)
        XCTAssertTrue(context?.contains("[...truncated...]") == true)
        XCTAssertTrue(payload.prompt.contains("Transcript:"))
        XCTAssertTrue(payload.prompt.contains("Question:"))
    }

    func testChatArgumentParsingReadsTranscriptSystemAndStatsFlags() throws {
        let command = try LLMCommand.Chat.parse(
            [
                "What changed?",
                "--transcript-file", "/tmp/transcript.txt",
                "--system", "Be concise",
                "--stats",
            ]
        )

        XCTAssertEqual(command.question, "What changed?")
        XCTAssertEqual(command.transcriptFile, "/tmp/transcript.txt")
        XCTAssertEqual(command.runtime.system, "Be concise")
        XCTAssertTrue(command.runtime.stats)
    }
}
