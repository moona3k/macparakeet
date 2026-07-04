import XCTest
@testable import MacParakeetViewModels
@testable import MacParakeetCore

final class LLMSettingsDraftTests: XCTestCase {
    func testHTTPRemoteBaseURLIsRejected() {
        let draft = LLMSettingsDraft(
            providerID: .openai,
            apiKeyInput: "test-key",
            suggestedModelName: "gpt-4.1",
            baseURLOverride: "http://example.com/v1"
        )

        XCTAssertEqual(draft.validationError, .invalidBaseURL)
    }

    func testHTTPLocalhostBaseURLIsAllowed() {
        let draft = LLMSettingsDraft(
            providerID: .ollama,
            suggestedModelName: "qwen3.5:4b",
            baseURLOverride: "http://localhost:11434/v1"
        )

        XCTAssertNil(draft.validationError)
    }

    // Regression: #118 — Ollama running on a LAN host must not require HTTPS.
    func testOllamaLANBaseURLIsAllowed() throws {
        let draft = LLMSettingsDraft(
            providerID: .ollama,
            suggestedModelName: "qwen3.5:4b",
            baseURLOverride: "http://192.168.1.5:11434/v1"
        )

        XCTAssertNil(draft.validationError)

        let config = try draft.buildConfig(defaultBaseURL: "http://localhost:11434/v1")
        XCTAssertEqual(config?.id, .ollama)
        XCTAssertEqual(config?.baseURL.absoluteString, "http://192.168.1.5:11434/v1")
        XCTAssertEqual(config?.isLocal, true)
    }

    // Regression: #118 — mDNS / Tailscale / 0.0.0.0 bindings must also be accepted for local providers.
    func testLMStudioMDNSBaseURLIsAllowed() {
        let draft = LLMSettingsDraft(
            providerID: .lmstudio,
            suggestedModelName: "local-model",
            baseURLOverride: "http://studio.local:1234/v1"
        )

        XCTAssertNil(draft.validationError)
    }

    // Preserves PR #109's tightening: OpenAI-compatible LAN HTTP needs an
    // explicit local-network opt-in unless the user is pointing at loopback.
    func testOpenAICompatibleRejectsHTTPOnLANHostWithoutOptIn() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "third-party-model",
            baseURLOverride: "http://192.168.1.5:8000/v1"
        )

        XCTAssertEqual(draft.validationError, .localNetworkHTTPRequiresOptIn)
    }

    func testOpenAICompatibleAllowsHTTPOnLANHostWithExplicitOptIn() throws {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "local-model",
            baseURLOverride: "http://192.168.1.5:8000/v1",
            allowInsecureLocalNetworkHTTP: true
        )

        XCTAssertNil(draft.validationError)
        XCTAssertTrue(draft.isLocalConfiguration)
        XCTAssertTrue(draft.usesInsecureLocalNetworkHTTP)

        let config = try draft.buildConfig(defaultBaseURL: "")
        XCTAssertEqual(config?.id, .openaiCompatible)
        XCTAssertEqual(config?.baseURL.absoluteString, "http://192.168.1.5:8000/v1")
        XCTAssertEqual(config?.isLocal, true)
    }

    func testOpenAICompatibleRejectsPublicHTTPHostEvenWithExplicitOptIn() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "local-model",
            baseURLOverride: "http://example.com/v1",
            allowInsecureLocalNetworkHTTP: true
        )

        XCTAssertEqual(draft.validationError, .invalidBaseURL)
        XCTAssertFalse(draft.isLocalConfiguration)
        XCTAssertFalse(draft.usesInsecureLocalNetworkHTTP)
    }

    func testOpenAICompatibleRejectsPublicHTTPAddressEvenWithExplicitOptIn() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "local-model",
            baseURLOverride: "http://8.8.8.8/v1",
            allowInsecureLocalNetworkHTTP: true
        )

        XCTAssertEqual(draft.validationError, .invalidBaseURL)
        XCTAssertFalse(draft.isLocalConfiguration)
        XCTAssertFalse(draft.usesInsecureLocalNetworkHTTP)
    }

    func testOpenAICompatibleAllowsCGNATHTTPWithExplicitOptIn() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "local-model",
            baseURLOverride: "http://100.64.0.42:8000/v1",
            allowInsecureLocalNetworkHTTP: true
        )

        XCTAssertNil(draft.validationError)
        XCTAssertTrue(draft.isLocalConfiguration)
        XCTAssertTrue(draft.usesInsecureLocalNetworkHTTP)
    }

    func testOpenAICompatibleAllowsPrivateIPv6HTTPWithExplicitOptIn() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "local-model",
            baseURLOverride: "http://[fd12:3456::1]:8000/v1",
            allowInsecureLocalNetworkHTTP: true
        )

        XCTAssertNil(draft.validationError)
        XCTAssertTrue(draft.isLocalConfiguration)
        XCTAssertTrue(draft.usesInsecureLocalNetworkHTTP)
    }

    func testOpenAICompatibleAllowsScopedLinkLocalIPv6HTTPWithExplicitOptIn() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "local-model",
            baseURLOverride: "http://[fe80::1%25en0]:8000/v1",
            allowInsecureLocalNetworkHTTP: true
        )

        XCTAssertNil(draft.validationError)
        XCTAssertTrue(draft.isLocalConfiguration)
        XCTAssertTrue(draft.usesInsecureLocalNetworkHTTP)
    }

    func testOpenAICompatibleAllowsMDNSHTTPWithExplicitOptIn() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "local-model",
            baseURLOverride: "http://studio.local:8000/v1",
            allowInsecureLocalNetworkHTTP: true
        )

        XCTAssertNil(draft.validationError)
        XCTAssertTrue(draft.isLocalConfiguration)
        XCTAssertTrue(draft.usesInsecureLocalNetworkHTTP)
    }

    // Regression: #118 — 0.0.0.0 bind addresses (common Ollama config) must be accepted.
    func testOllamaWildcardBindBaseURLIsAllowed() {
        let draft = LLMSettingsDraft(
            providerID: .ollama,
            suggestedModelName: "qwen3.5:4b",
            baseURLOverride: "http://0.0.0.0:11434/v1"
        )

        XCTAssertNil(draft.validationError)
    }

    // IPv6 loopback must be treated as loopback for remote providers too. Pins
    // the behavior of LLMProviderConfig.isLoopbackEndpoint + URL.host for `[::1]`.
    func testIPv6LoopbackAllowedForRemoteProvider() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "third-party-model",
            baseURLOverride: "http://[::1]:8080/v1"
        )

        XCTAssertNil(draft.validationError)
    }

    // Non-web schemes are rejected for every provider, including local ones.
    func testNonHTTPSchemeRejectedForLocalProvider() {
        let draft = LLMSettingsDraft(
            providerID: .ollama,
            suggestedModelName: "qwen3.5:4b",
            baseURLOverride: "ftp://localhost:11434/v1"
        )

        XCTAssertEqual(draft.validationError, .invalidBaseURL)
    }

    func testHTTPSRemoteBaseURLIsAllowed() {
        let draft = LLMSettingsDraft(
            providerID: .openai,
            apiKeyInput: "test-key",
            suggestedModelName: "gpt-4.1",
            baseURLOverride: "https://example.com/v1"
        )

        XCTAssertNil(draft.validationError)
    }

    func testMissingSuggestedModelSelectionIsInvalid() {
        let draft = LLMSettingsDraft(
            providerID: .lmstudio,
            suggestedModelName: "",
            useCustomModel: false
        )

        XCTAssertEqual(draft.validationError, .missingModelSelection)
    }

    func testBuildConfigAllowsMissingModelNameForModelDiscovery() throws {
        let draft = LLMSettingsDraft(
            providerID: .lmstudio,
            useCustomModel: true,
            customModelName: ""
        )

        let config = try draft.buildConfig(
            defaultBaseURL: "http://localhost:1234/v1",
            allowMissingModelName: true
        )

        XCTAssertEqual(config?.id, .lmstudio)
        XCTAssertEqual(config?.modelName, "")
    }

    func testLMStudioAllowsOptionalAPIKey() throws {
        let draft = LLMSettingsDraft(
            providerID: .lmstudio,
            apiKeyInput: "lm-token",
            suggestedModelName: "local-model"
        )

        XCTAssertNil(draft.validationError)

        let config = try draft.buildConfig(defaultBaseURL: "http://localhost:1234/v1")
        XCTAssertEqual(config?.id, .lmstudio)
        XCTAssertEqual(config?.apiKey, "lm-token")
        XCTAssertTrue(config?.isLocal == true)
    }

    func testOpenAICompatibleProviderRequiresCustomEndpoint() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "third-party-model"
        )

        XCTAssertEqual(draft.validationError, .invalidBaseURL)
    }

    func testOpenAICompatibleLoopbackEndpointBuildsLocalConfig() throws {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "third-party-model",
            baseURLOverride: "http://127.0.0.1:8000/v1"
        )

        let config = try draft.buildConfig(defaultBaseURL: "")

        XCTAssertEqual(config?.id, .openaiCompatible)
        XCTAssertEqual(config?.isLocal, true)
    }

    func testOpenAICompatibleRemoteEndpointBuildsNonLocalConfig() throws {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "third-party-model",
            baseURLOverride: "https://api.example.com/v1"
        )

        let config = try draft.buildConfig(defaultBaseURL: "")

        XCTAssertEqual(config?.id, .openaiCompatible)
        XCTAssertEqual(config?.isLocal, false)
    }

    func testOpenAICompatibleStoredLocalNetworkHTTPConfigRestoresOptIn() {
        let config = LLMProviderConfig(
            id: .openaiCompatible,
            baseURL: URL(string: "http://192.168.1.5:8000/v1")!,
            apiKey: nil,
            modelName: "local-model",
            isLocal: true
        )

        let draft = LLMSettingsDraft.fromStoredConfig(
            config,
            suggestedModels: [],
            defaultModelName: "",
            defaultBaseURL: ""
        )

        XCTAssertTrue(draft.allowInsecureLocalNetworkHTTP)
        XCTAssertTrue(draft.usesInsecureLocalNetworkHTTP)
        XCTAssertNil(draft.validationError)
    }

    func testOpenAICompatibleStoredPublicHTTPConfigDoesNotRestoreOptIn() {
        let config = LLMProviderConfig(
            id: .openaiCompatible,
            baseURL: URL(string: "http://example.com/v1")!,
            apiKey: nil,
            modelName: "remote-model",
            isLocal: true
        )

        let draft = LLMSettingsDraft.fromStoredConfig(
            config,
            suggestedModels: [],
            defaultModelName: "",
            defaultBaseURL: ""
        )

        XCTAssertFalse(draft.allowInsecureLocalNetworkHTTP)
        XCTAssertFalse(draft.usesInsecureLocalNetworkHTTP)
        XCTAssertEqual(draft.validationError, .invalidBaseURL)
    }
}
