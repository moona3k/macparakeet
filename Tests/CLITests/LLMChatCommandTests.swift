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

    func testLoadTranscriptContextThrowsWhenFileDoesNotExist() {
        let missingPath = "/tmp/macparakeet-missing-\(UUID().uuidString).txt"

        XCTAssertThrowsError(try LLMChatPromptComposer.loadTranscriptContext(from: missingPath)) { error in
            guard case CLIError.transcriptFileNotFound(let path) = error else {
                return XCTFail("Expected transcriptFileNotFound, got: \(error)")
            }
            XCTAssertEqual(path, missingPath)
        }
    }

    func testLoadTranscriptContextThrowsWhenPathIsUnreadable() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("llm-chat-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        XCTAssertThrowsError(try LLMChatPromptComposer.loadTranscriptContext(from: directoryURL.path)) { error in
            guard case CLIError.transcriptFileReadFailed(let path, _) = error else {
                return XCTFail("Expected transcriptFileReadFailed, got: \(error)")
            }
            XCTAssertEqual(path, directoryURL.path)
        }
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
