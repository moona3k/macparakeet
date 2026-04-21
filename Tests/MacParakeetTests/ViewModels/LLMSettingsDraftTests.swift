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

    // Preserves PR #109's tightening: remote providers (including OpenAI-compatible
    // shims) must use HTTPS unless the user is pointing at loopback.
    func testOpenAICompatibleRejectsHTTPOnLANHost() {
        let draft = LLMSettingsDraft(
            providerID: .openaiCompatible,
            useCustomModel: true,
            customModelName: "third-party-model",
            baseURLOverride: "http://192.168.1.5:8000/v1"
        )

        XCTAssertEqual(draft.validationError, .invalidBaseURL)
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
}
