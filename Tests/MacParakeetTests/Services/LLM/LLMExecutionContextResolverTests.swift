import XCTest
@testable import MacParakeetCore

final class LLMExecutionContextResolverTests: XCTestCase {
    func testStoredResolverReturnsNilWithoutProviderConfig() throws {
        let configStore = MockLLMConfigStore()
        let suiteName = "test.llm.context.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = StoredLLMExecutionContextResolver(
            configStore: configStore,
            cliConfigStore: LocalCLIConfigStore(defaults: defaults)
        )

        XCTAssertNil(try resolver.resolveContext())
    }

    func testStoredResolverLoadsCloudProviderWithoutLocalCLIConfig() throws {
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test", model: "gpt-5.4")

        let suiteName = "test.llm.context.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let resolver = StoredLLMExecutionContextResolver(
            configStore: configStore,
            cliConfigStore: LocalCLIConfigStore(defaults: defaults)
        )

        let context = try resolver.resolveContext()
        XCTAssertEqual(context?.providerConfig.id, .openai)
        XCTAssertNil(context?.localCLIConfig)
    }

    func testStoredResolverLoadsLocalCLIConfigAlongsideProviderConfig() throws {
        let configStore = MockLLMConfigStore()
        configStore.config = .localCLI()

        let suiteName = "test.llm.context.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cliConfigStore = LocalCLIConfigStore(defaults: defaults)
        try cliConfigStore.save(
            LocalCLIConfig(
                commandTemplate: "codex exec --skip-git-repo-check --model gpt-5.4-mini",
                timeoutSeconds: 90
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
        XCTAssertEqual(context?.localCLIConfig?.timeoutSeconds, 90)
    }
}
