import XCTest
@testable import MacParakeetCore

final class LLMProviderDescriptorTests: XCTestCase {
    func testDescriptorsCoverEveryProvider() {
        for provider in LLMProviderID.allCases {
            let descriptor = provider.descriptor

            XCTAssertEqual(descriptor.id, provider)
            XCTAssertEqual(provider.displayName, descriptor.displayName)
            XCTAssertEqual(provider.defaultBaseURL, descriptor.defaultBaseURL)
            XCTAssertEqual(provider.isLocal, descriptor.isLocal)
            XCTAssertEqual(provider.supportsAPIKey, descriptor.supportsAPIKey)
            XCTAssertEqual(provider.requiresAPIKey, descriptor.requiresAPIKey)
            XCTAssertEqual(provider.requiresCustomEndpoint, descriptor.requiresCustomEndpoint)
            XCTAssertEqual(provider.supportsModelListing, descriptor.supportsModelListing)
            XCTAssertEqual(provider.fallbackModels, descriptor.fallbackModels)
            XCTAssertEqual(provider.defaultModelName, descriptor.defaultModelName)
            XCTAssertFalse(descriptor.displayName.isEmpty)
            if !descriptor.defaultBaseURL.isEmpty {
                XCTAssertNotNil(URL(string: descriptor.defaultBaseURL), "\(provider) default URL should parse")
            }
        }
    }

    func testModelListEndpointPolicy() {
        XCTAssertEqual(LLMProviderID.localCLI.modelListEndpoint, .none)
        XCTAssertEqual(LLMProviderID.inProcessLocal.modelListEndpoint, .none)
        XCTAssertEqual(LLMProviderID.anthropic.modelListEndpoint, .anthropic)
        XCTAssertEqual(LLMProviderID.gemini.modelListEndpoint, .gemini)
        XCTAssertEqual(LLMProviderID.ollama.modelListEndpoint, .ollama)

        for provider in [LLMProviderID.openai, .openaiCompatible, .openrouter, .lmstudio] {
            XCTAssertEqual(provider.modelListEndpoint, .openAICompatible)
        }
    }

    func testFallbackModelPolicyKeepsCustomFirstProvidersEmpty() {
        XCTAssertEqual(LLMProviderID.openaiCompatible.fallbackModels, [])
        XCTAssertEqual(LLMProviderID.lmstudio.fallbackModels, [])
        XCTAssertEqual(LLMProviderID.localCLI.fallbackModels, [])
        XCTAssertEqual(LLMProviderID.inProcessLocal.fallbackModels, ["mlx-community/Qwen3-4B-Instruct-2507-DDWQ"])
        XCTAssertEqual(LLMProviderID.gemini.defaultModelName, "gemini-3.5-flash")
    }

    func testCuratedFallbacksTrackCurrentHeadlineModels() {
        XCTAssertEqual(LLMProviderID.openai.defaultModelName, "gpt-5.5")
        XCTAssertTrue(LLMProviderID.openai.fallbackModels.contains("gpt-5.4-mini"))
        XCTAssertFalse(LLMProviderID.openai.fallbackModels.contains("gpt-5.5-pro"))
        XCTAssertFalse(LLMProviderID.openai.fallbackModels.contains("gpt-5.4-pro"))
        XCTAssertTrue(LLMProviderID.anthropic.fallbackModels.contains("claude-opus-4-7"))
        XCTAssertTrue(LLMProviderID.gemini.fallbackModels.contains("gemini-3.1-flash-lite"))
        XCTAssertTrue(LLMProviderID.openrouter.fallbackModels.contains("anthropic/claude-opus-4.7"))
        XCTAssertTrue(LLMProviderID.openrouter.fallbackModels.contains("openai/gpt-5.5"))
        XCTAssertTrue(LLMProviderID.openrouter.fallbackModels.contains("google/gemini-3.5-flash"))
    }

    func testFactoryDefaultsComeFromDescriptors() {
        XCTAssertEqual(LLMProviderConfig.openai(apiKey: "sk").modelName, LLMProviderID.openai.defaultModelName)
        XCTAssertEqual(LLMProviderConfig.openai(apiKey: "sk").baseURL.absoluteString, LLMProviderID.openai.defaultBaseURL)
        XCTAssertEqual(LLMProviderConfig.gemini(apiKey: "key").modelName, LLMProviderID.gemini.defaultModelName)
        XCTAssertEqual(LLMProviderConfig.gemini(apiKey: "key").baseURL.absoluteString, LLMProviderID.gemini.defaultBaseURL)
        XCTAssertEqual(LLMProviderConfig.openrouter(apiKey: "key").modelName, LLMProviderID.openrouter.defaultModelName)
        XCTAssertEqual(LLMProviderConfig.openrouter(apiKey: "key").baseURL.absoluteString, LLMProviderID.openrouter.defaultBaseURL)
        XCTAssertEqual(LLMProviderConfig.ollama().modelName, LLMProviderID.ollama.defaultModelName)
        XCTAssertEqual(LLMProviderConfig.ollama().baseURL.absoluteString, LLMProviderID.ollama.defaultBaseURL)
        XCTAssertEqual(LLMProviderConfig.inProcessLocal().modelName, LLMProviderID.inProcessLocal.defaultModelName)
        XCTAssertEqual(LLMProviderConfig.inProcessLocal().baseURL.absoluteString, LLMProviderID.inProcessLocal.defaultBaseURL)
    }

    func testInProcessLocalProviderIsHiddenWhileFeatureFlagIsOff() {
        XCTAssertFalse(AppFeatures.inProcessLocalLLMEnabled)
        XCTAssertEqual(
            LLMProviderID.userSelectableProviderIDs(inProcessLocalLLMVisible: false),
            [
                .lmstudio,
                .ollama,
                .anthropic,
                .openai,
                .gemini,
                .openrouter,
                .openaiCompatible,
                .localCLI,
            ]
        )
        XCTAssertFalse(LLMProviderID.userSelectableProviderIDs(inProcessLocalLLMVisible: false).contains(.inProcessLocal))
    }

    func testDeveloperOverrideCanExposeInProcessLocalProviderWithoutFlippingPublicFlag() {
        let suiteName = "LLMProviderDescriptorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: AppFeatures.inProcessLocalLLMDeveloperDefaultsKey)

        XCTAssertFalse(AppFeatures.inProcessLocalLLMEnabled)
        XCTAssertTrue(AppFeatures.inProcessLocalLLMDeveloperOverrideEnabled(defaults: defaults, arguments: []))
        XCTAssertTrue(AppFeatures.isInProcessLocalLLMVisible(defaults: defaults, arguments: []))
        XCTAssertTrue(LLMProviderID.userSelectableProviderIDs(inProcessLocalLLMVisible: true).contains(.inProcessLocal))
    }

    func testDeveloperLaunchArgumentCanExposeInProcessLocalProviderWithoutFlippingPublicFlag() {
        let suiteName = "LLMProviderDescriptorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(AppFeatures.inProcessLocalLLMEnabled)
        XCTAssertTrue(AppFeatures.inProcessLocalLLMDeveloperOverrideEnabled(
            defaults: defaults,
            arguments: [AppFeatures.inProcessLocalLLMDeveloperLaunchArgument]
        ))
    }
}
