import XCTest
@testable import MacParakeetCore

final class PromptAwareMockLLMClient: LLMClientProtocol, @unchecked Sendable {
    var capturedMessages: [ChatMessage] = []

    func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        capturedMessages = messages
        return ChatCompletionResponse(content: "Summary", model: "mock")
    }

    func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        capturedMessages = messages
        return AsyncThrowingStream { continuation in
            continuation.yield("Summary")
            continuation.finish()
        }
    }

    func testConnection(context: LLMExecutionContext) async throws {}
    func listModels(context: LLMExecutionContext) async throws -> [String] { [] }
}

final class LLMServicePromptTests: XCTestCase {
    var client: PromptAwareMockLLMClient!
    var configStore: MockLLMConfigStore!
    var resolver: MockLLMExecutionContextResolver!
    var service: LLMService!

    override func setUp() {
        client = PromptAwareMockLLMClient()
        configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test")
        resolver = MockLLMExecutionContextResolver(configStore: configStore)
        service = LLMService(client: client, contextResolver: resolver)
    }

    func testCustomSystemPromptOverridesDefault() async throws {
        _ = try await service.summarize(
            transcript: "Transcript",
            systemPrompt: "Custom instructions"
        )

        XCTAssertEqual(client.capturedMessages.first?.role, .system)
        XCTAssertEqual(client.capturedMessages.first?.content, "Custom instructions")
    }

    func testNilSystemPromptUsesDefaultSummaryPrompt() async throws {
        _ = try await service.summarize(
            transcript: "Transcript",
            systemPrompt: nil
        )

        XCTAssertEqual(client.capturedMessages.first?.role, .system)
        XCTAssertTrue(client.capturedMessages.first?.content.contains("Summarize this transcript") ?? false)
    }
}
