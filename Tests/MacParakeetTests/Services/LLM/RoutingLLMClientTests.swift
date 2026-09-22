import XCTest
@testable import MacParakeetCore

final class RoutingLLMClientTests: XCTestCase {

    func testLocalCLIContextRoutesToCLIClient() async throws {
        let cliConfig = LocalCLIConfig(commandTemplate: "printf routed", timeoutSeconds: 10)
        let context = LLMExecutionContext(
            providerConfig: .localCLI(),
            localCLIConfig: cliConfig
        )

        let router = RoutingLLMClient()
        let response = try await router.chatCompletion(
            messages: [ChatMessage(role: .user, content: "test")],
            context: context,
            options: .default
        )

        // If this reached the HTTP client, it would fail with a network error.
        // "routed" confirms the CLI path was taken.
        XCTAssertEqual(response.content, "routed")
        XCTAssertEqual(response.model, "cli")
    }

    func testListModelsReturnsEmptyForLocalCLI() async throws {
        let context = LLMExecutionContext(
            providerConfig: .localCLI(),
            localCLIConfig: LocalCLIConfig(commandTemplate: "echo test", timeoutSeconds: 10)
        )

        let router = RoutingLLMClient()
        let models = try await router.listModels(context: context)
        XCTAssertTrue(models.isEmpty)
    }

    func testInProcessLocalContextRoutesToInjectedClient() async throws {
        let expected = ChatCompletionResponse(content: "in-process", model: "local-test")
        let inProcessClient = StubLLMClient(response: expected)
        let router = RoutingLLMClient(inProcessClient: inProcessClient)

        let response = try await router.chatCompletion(
            messages: [ChatMessage(role: .user, content: "test")],
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "local-test")),
            options: .default
        )

        XCTAssertEqual(response.content, "in-process")
    }
}

private final class StubLLMClient: LLMClientProtocol, @unchecked Sendable {
    private let response: ChatCompletionResponse

    init(response: ChatCompletionResponse) {
        self.response = response
    }

    func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        return response
    }

    func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(response.content)
            continuation.finish()
        }
    }

    func testConnection(context: LLMExecutionContext) async throws {}

    func listModels(context: LLMExecutionContext) async throws -> [String] {
        []
    }
}
