import XCTest
@testable import MacParakeetCore

final class ChatCompletionsModelPolicyTests: XCTestCase {
    func testCanonicalIDStripsOpenRouterPrefix() {
        XCTAssertEqual(
            ChatCompletionsModelPolicy.canonicalModelID("moonshotai/kimi-k2.6"),
            "kimi-k2.6"
        )
        XCTAssertEqual(
            ChatCompletionsModelPolicy.canonicalModelID("deepseek/deepseek-v4-flash"),
            "deepseek-v4-flash"
        )
    }

    func testFamiliesFromNativeAndGatewayIDs() {
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k2.6"), .kimi)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "moonshotai/kimi-k2.6"), .kimi)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k2.7-code"), .kimi)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k2.5"), .kimi)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "kimi-k3"), .kimi)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "moonshot-v1-32k"), .generic)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "deepseek-v4-flash"), .deepseek)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "deepseek/deepseek-v4-pro"), .deepseek)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "qwen3.7-max"), .qwen)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "glm-5.1"), .glm)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "MiniMax-M2.7"), .minimax)
        XCTAssertEqual(ChatCompletionsModelPolicy.family(for: "gpt-4.1"), .generic)
    }

    func testKimiOmitsSamplingOnEveryCompatiblePath() {
        for model in ["kimi-k2.6", "moonshotai/kimi-k2.6", "kimi-k3", "kimi-k2.7-code"] {
            XCTAssertTrue(
                ChatCompletionsModelPolicy.shouldOmitSampling(model: model),
                "\(model) must omit the app temperature baseline"
            )
        }
    }

    func testOtherLabsKeepSampling() {
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "deepseek-v4-flash"))
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "qwen3.7-max"))
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "glm-5.1"))
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "MiniMax-M2.7"))
    }

    func testGPT5OmitStillWins() {
        XCTAssertTrue(ChatCompletionsModelPolicy.shouldOmitSampling(model: "gpt-5.5"))
        XCTAssertTrue(ChatCompletionsModelPolicy.shouldOmitSampling(model: "openai/gpt-5.6-sol"))
        XCTAssertFalse(ChatCompletionsModelPolicy.shouldOmitSampling(model: "gpt-5.3-chat-latest"))
    }

    func testKimiK3DoesNotExposeThinkingToggle() {
        XCTAssertFalse(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "kimi-k3"))
        XCTAssertFalse(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "kimi-k2.7-code"))
        XCTAssertTrue(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "kimi-k2.6"))
        XCTAssertTrue(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "MiniMax-M2.7"))
        XCTAssertTrue(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "deepseek-v4-flash"))
        XCTAssertFalse(ChatCompletionsModelPolicy.supportsThinkingToggle(model: "gpt-4.1"))
    }

    func testLabThinkingEncodings() {
        XCTAssertEqual(
            encoding(.moonshot, "kimi-k2.6", .disabled),
            .thinkingType("disabled")
        )
        XCTAssertEqual(
            encoding(.minimax, "MiniMax-M2.7", .enabled),
            .thinkingType("adaptive")
        )
        XCTAssertEqual(
            encoding(.qwen, "qwen3.7-max", .enabled),
            .enableThinking(true)
        )
        XCTAssertEqual(encoding(.moonshot, "kimi-k3", .enabled), .omit)
        XCTAssertEqual(encoding(.moonshot, "kimi-k2.7-code", .disabled), .omit)
        XCTAssertEqual(encoding(.openrouter, "moonshotai/kimi-k2.6", .disabled), .omit)
    }

    func testGenericOpenAICompatibleKeepsLlamaCppKwargs() {
        XCTAssertEqual(
            encoding(
                .openaiCompatible, "llama-3.1-8b", .disabled, usesPromptInferenceSettings: true),
            .llamaCpp(enableThinking: false, reasoningEffort: nil)
        )
        XCTAssertEqual(
            encoding(
                .openaiCompatible, "qwen2.5-32b-instruct", .disabled,
                usesPromptInferenceSettings: true),
            .llamaCpp(enableThinking: false, reasoningEffort: nil)
        )
        XCTAssertEqual(
            encoding(
                .openaiCompatible, "kimi-k2.6", .disabled, usesPromptInferenceSettings: true),
            .llamaCpp(enableThinking: false, reasoningEffort: nil)
        )
    }

    private func encoding(
        _ provider: LLMProviderID,
        _ model: String,
        _ thinkingMode: PromptInferenceSettings.ThinkingMode,
        usesPromptInferenceSettings: Bool = false
    ) -> ChatCompletionsThinkingEncoding {
        ChatCompletionsModelPolicy.thinkingEncoding(
            provider: provider,
            model: model,
            thinkingMode: thinkingMode,
            reasoningEffort: nil,
            usesPromptInferenceSettings: usesPromptInferenceSettings
        )
    }
}
