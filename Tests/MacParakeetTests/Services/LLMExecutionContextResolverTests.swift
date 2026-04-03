import XCTest
@testable import MacParakeetCore

final class LLMExecutionContextResolverTests: XCTestCase {
    func testStoredResolverReturnsNilWithoutProviderConfig() throws {
        let configStore = MockLLMConfigStore()
        let resolver = StoredLLMExecutionContextResolver(
            configStore: configStore,
            cliConfigStore: LocalCLIConfigStore(defaults: UserDefaults(suiteName: "test.llm.context.\(UUID().uuidString)")!)
        )

        XCTAssertNil(try resolver.resolveContext())
    }

    func testStoredResolverLoadsCloudProviderWithoutLocalCLIConfig() throws {
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test", model: "gpt-5.4")

        let resolver = StoredLLMExecutionContextResolver(
            configStore: configStore,
            cliConfigStore: LocalCLIConfigStore(defaults: UserDefaults(suiteName: "test.llm.context.\(UUID().uuidString)")!)
        )

        let context = try resolver.resolveContext()
        XCTAssertEqual(context?.providerConfig.id, .openai)
        XCTAssertNil(context?.localCLIConfig)
    }

    func testStoredResolverLoadsLocalCLIConfigAlongsideProviderConfig() throws {
        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        let defaults = UserDefaults(suiteName: "test.llm.context.\(UUID().uuidString)")!
        let cliConfigStore = LocalCLIConfigStore(defaults: defaults)
        try cliConfigStore.save(
            LocalCLIConfig(
                commandTemplate: "codex exec --skip-git-repo-check --model gpt-5.4-mini",
                timeoutSeconds: 45
            )
        )

        let resolver = StoredLLMExecutionContextResolver(
            configStore: configStore,
            cliConfigStore: cliConfigStore
        )

        let context = try resolver.resolveContext()
        XCTAssertEqual(context?.providerConfig.id, .localCLI)
        XCTAssertEqual(
            context?.localCLIConfig?.commandTemplate,
            "codex exec --skip-git-repo-check --model gpt-5.4-mini"
        )
        XCTAssertEqual(context?.localCLIConfig?.timeoutSeconds, 45)
    }
}
