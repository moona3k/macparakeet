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
            apiKeyInput: "test-key",
            useCustomModel: true,
            customModelName: "third-party-model"
        )

        XCTAssertEqual(draft.validationError, .invalidBaseURL)
    }
}
