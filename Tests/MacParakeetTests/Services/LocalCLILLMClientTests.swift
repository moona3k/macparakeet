import XCTest
@testable import MacParakeetCore

final class LocalCLILLMClientTests: XCTestCase {

    // MARK: - Message Extraction

    func testExtractPromptsFromMessages() {
        let messages = [
            ChatMessage(role: .system, content: "You are helpful."),
            ChatMessage(role: .user, content: "Summarize this."),
        ]
        let (system, user) = LocalCLILLMClient.extractPrompts(from: messages)
        XCTAssertEqual(system, "You are helpful.")
        XCTAssertEqual(user, "Summarize this.")
    }

    func testExtractPromptsNoSystem() {
        let messages = [
            ChatMessage(role: .user, content: "Hello"),
        ]
        let (system, user) = LocalCLILLMClient.extractPrompts(from: messages)
        XCTAssertEqual(system, "")
        XCTAssertEqual(user, "Hello")
    }

    func testExtractPromptsMultipleUserMessages() {
        let messages = [
            ChatMessage(role: .system, content: "System"),
            ChatMessage(role: .user, content: "First"),
            ChatMessage(role: .assistant, content: "Response"),
            ChatMessage(role: .user, content: "Second"),
        ]
        let (system, user) = LocalCLILLMClient.extractPrompts(from: messages)
        XCTAssertEqual(system, "System")
        // Multi-turn messages should include role labels
        XCTAssertTrue(user.contains("User: First"))
        XCTAssertTrue(user.contains("Assistant: Response"))
        XCTAssertTrue(user.contains("User: Second"))
    }

    // MARK: - Chat Completion

    func testChatCompletionViaEcho() async throws {
        let config = LocalCLIConfig(commandTemplate: "echo 'summary result'", timeoutSeconds: 10)

        let executor = LocalCLIExecutor()
        let client = LocalCLILLMClient(executor: executor)
        let context = LLMExecutionContext(providerConfig: .localCLI(), localCLIConfig: config)

        let messages = [
            ChatMessage(role: .system, content: "Summarize."),
            ChatMessage(role: .user, content: "Some transcript"),
        ]
        let response = try await client.chatCompletion(
            messages: messages,
            context: context,
            options: .default
        )

        XCTAssertEqual(response.content, "summary result")
        XCTAssertEqual(response.model, "cli")
        XCTAssertNil(response.usage)
    }

    // MARK: - Streaming

    func testStreamYieldsSingleChunk() async throws {
        let config = LocalCLIConfig(commandTemplate: "echo 'streamed'", timeoutSeconds: 10)

        let executor = LocalCLIExecutor()
        let client = LocalCLILLMClient(executor: executor)
        let context = LLMExecutionContext(providerConfig: .localCLI(), localCLIConfig: config)

        let messages = [ChatMessage(role: .user, content: "test")]
        let stream = client.chatCompletionStream(
            messages: messages, context: context, options: .default
        )

        var chunks: [String] = []
        for try await chunk in stream {
            chunks.append(chunk)
        }

        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks.first, "streamed")
    }

    // MARK: - List Models

    func testListModelsReturnsEmpty() async throws {
        let client = LocalCLILLMClient()
        let models = try await client.listModels(context: LLMExecutionContext(providerConfig: .localCLI()))
        XCTAssertTrue(models.isEmpty)
    }

    // MARK: - Error Mapping

    func testCLIErrorMappedToLLMError() async throws {
        let config = LocalCLIConfig(commandTemplate: "exit 1", timeoutSeconds: 10)

        let executor = LocalCLIExecutor()
        let client = LocalCLILLMClient(executor: executor)
        let context = LLMExecutionContext(providerConfig: .localCLI(), localCLIConfig: config)

        let messages = [ChatMessage(role: .user, content: "test")]
        do {
            _ = try await client.chatCompletion(
                messages: messages, context: context, options: .default
            )
            XCTFail("Expected LLMError.cliError")
        } catch let error as LLMError {
            if case .cliError(let detail) = error {
                XCTAssertTrue(detail.contains("exit code"))
            } else {
                XCTFail("Expected cliError, got \(error)")
            }
        }
    }

    func testMissingLocalCLIConfigMapsToLLMError() async throws {
        let client = LocalCLILLMClient()
        let messages = [ChatMessage(role: .user, content: "test")]

        do {
            _ = try await client.chatCompletion(
                messages: messages,
                context: LLMExecutionContext(providerConfig: .localCLI()),
                options: .default
            )
            XCTFail("Expected LLMError.cliError")
        } catch let error as LLMError {
            guard case .cliError(let detail) = error else {
                XCTFail("Expected cliError, got \(error)")
                return
            }
            XCTAssertTrue(detail.contains("not configured"))
        }
    }
}
