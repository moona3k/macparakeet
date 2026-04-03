import XCTest
@testable import MacParakeetCore

final class RoutingLLMClientTests: XCTestCase {

    func testLocalCLIContextRoutesToCLIClient() async throws {
        let cliConfig = LocalCLIConfig(commandTemplate: "echo routed", timeoutSeconds: 10)
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
}
