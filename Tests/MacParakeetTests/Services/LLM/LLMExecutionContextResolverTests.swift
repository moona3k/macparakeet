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

    func testStoredResolverInheritsDefaultWhenTaskHasNoOverride() throws {
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test", model: "gpt-5.4")
        let suiteName = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resolver = StoredLLMExecutionContextResolver(
            configStore: configStore,
            cliConfigStore: LocalCLIConfigStore(defaults: defaults)
        )

        XCTAssertEqual(try resolver.resolveContext(for: .cleanup)?.providerConfig.modelName, "gpt-5.4")
        XCTAssertEqual(try resolver.resolveContext(for: .analysis)?.providerConfig.modelName, "gpt-5.4")
        XCTAssertEqual(try resolver.resolveContext(for: .transform)?.providerConfig.modelName, "gpt-5.4")
    }

    func testStoredResolverUsesCleanupOverrideWithoutMutatingDefault() throws {
        let configStore = MockLLMConfigStore()
        configStore.config = .anthropic(apiKey: "sk-ant", model: "claude-sonnet-5")
        configStore.taskOverrides[.cleanup] = .ollama(model: "llama3.2")
        let suiteName = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resolver = StoredLLMExecutionContextResolver(
            configStore: configStore,
            cliConfigStore: LocalCLIConfigStore(defaults: defaults)
        )

        XCTAssertEqual(try resolver.resolveContext(for: .cleanup)?.providerConfig.id, .ollama)
        XCTAssertEqual(try resolver.resolveContext(for: .analysis)?.providerConfig.id, .anthropic)
        XCTAssertEqual(try resolver.resolveContext()?.providerConfig.id, .anthropic)
        XCTAssertEqual(try resolver.resolveContext(for: .transform)?.providerConfig.id, .anthropic)
    }

    func testTransformIgnoresStoredOverrides() throws {
        let configStore = MockLLMConfigStore()
        configStore.config = .openai(apiKey: "sk-test", model: "gpt-5.4")
        configStore.taskOverrides[.cleanup] = .ollama(model: "llama3.2")
        configStore.taskOverrides[.transform] = .gemini(apiKey: "gemini-key")
        let suiteName = "com.macparakeet.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resolver = StoredLLMExecutionContextResolver(
            configStore: configStore,
            cliConfigStore: LocalCLIConfigStore(defaults: defaults)
        )

        XCTAssertEqual(try resolver.resolveContext(for: .transform)?.providerConfig.id, .openai)
    }
}
