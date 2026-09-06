import XCTest
@testable import MacParakeetCore

/// Schema and conversion tests for the public LLM result envelope.
/// These tests are the contract: an agent author building on top of
/// `--json` output should be able to read the assertions here and know
/// exactly what fields exist, what types they have, and what values mean
/// "absent" vs "zero".
final class LLMResultTests: XCTestCase {

    // MARK: - LLMUsage(_ TokenUsage) conversion

    func testLLMUsageFromTokenUsageComputesTotal() {
        let tokenUsage = TokenUsage(promptTokens: 12, completionTokens: 34)
        let usage = LLMUsage(tokenUsage)

        XCTAssertEqual(usage.promptTokens, 12)
        XCTAssertEqual(usage.completionTokens, 34)
        XCTAssertEqual(usage.totalTokens, 46)
    }

    func testLLMUsageFromZeroTokenUsageStillProducesZeroTotal() {
        let usage = LLMUsage(TokenUsage(promptTokens: 0, completionTokens: 0))
        XCTAssertEqual(usage.totalTokens, 0)
    }

    func testTokenUsageTotalsPreserveComponentsAtIntegerBounds() {
        let cases: [(Int, Int, Int?)] = [
            (Int.max, 1, nil), (Int.min, -1, nil),
            (Int.max, 0, Int.max), (Int.max - 1, 1, Int.max), (12, 34, 46),
        ]
        for (prompt, completion, total) in cases {
            let usage = LLMUsage(TokenUsage(promptTokens: prompt, completionTokens: completion))
            XCTAssertEqual(usage.promptTokens, prompt)
            XCTAssertEqual(usage.completionTokens, completion)
            XCTAssertEqual(usage.totalTokens, total)
        }
        XCTAssertNil(LLMUsage.derivedTotal(promptTokens: Int.max, completionTokens: nil))
        XCTAssertNil(LLMUsage.derivedTotal(promptTokens: nil, completionTokens: 1))
        XCTAssertNil(LLMUsage.derivedTotal(promptTokens: nil, completionTokens: nil))
    }

    // MARK: - LLMResult init from ChatCompletionResponse

    func testLLMResultFromResponseStampsProviderAndLatency() {
        let response = ChatCompletionResponse(
            content: "hello world",
            finishReason: "stop",
            model: "gpt-4.1",
            usage: TokenUsage(promptTokens: 10, completionTokens: 20)
        )
        let result = LLMResult(response: response, provider: .openai, latencyMs: 1234)

        XCTAssertEqual(result.output, "hello world")
        XCTAssertEqual(result.provider, "openai")
        XCTAssertEqual(result.model, "gpt-4.1")
        XCTAssertEqual(result.usage?.promptTokens, 10)
        XCTAssertEqual(result.usage?.completionTokens, 20)
        XCTAssertEqual(result.usage?.totalTokens, 30)
        XCTAssertEqual(result.stopReason, "stop")
        XCTAssertEqual(result.latencyMs, 1234)
    }

    func testLLMResultFromResponseWithoutUsageProducesNilUsage() {
        let response = ChatCompletionResponse(content: "hi", model: "qwen-7b")
        let result = LLMResult(response: response, provider: .ollama, latencyMs: 50)

        XCTAssertNil(result.usage)
        XCTAssertNil(result.stopReason)
        XCTAssertEqual(result.provider, "ollama")
    }

    func testLLMResultFromResponseCarriesEffectiveInferenceReceipt() {
        let settings = PromptInferenceSettings(temperature: 0.2, maxTokens: 512)
        let response = ChatCompletionResponse(
            content: "hi",
            model: "gpt-4.1",
            effectiveInferenceSettings: settings
        )

        let result = LLMResult(response: response, provider: .openai, latencyMs: 50)

        XCTAssertEqual(result.effectiveSettings, settings)
    }

    func testLLMResultEncodesEffectiveSettingsAdditively() throws {
        let result = LLMResult(
            output: "configured",
            provider: "openai",
            model: "gpt-4.1",
            latencyMs: 12,
            effectiveSettings: PromptInferenceSettings(
                temperature: 0.25,
                maxTokens: 256,
                thinkingMode: .enabled,
                reasoningEffort: .high
            )
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any]
        )
        let receipt = try XCTUnwrap(object["effectiveSettings"] as? [String: Any])
        XCTAssertEqual(receipt["temperature"] as? Double, 0.25)
        XCTAssertEqual(receipt["maxTokens"] as? Int, 256)
        XCTAssertEqual(receipt["reasoningEffort"] as? String, "high")
    }

    // MARK: - JSON encoding shape

    func testLLMResultEncodesAllFields() throws {
        let result = LLMResult(
            output: "summary text",
            provider: "anthropic",
            model: "claude-sonnet-4-6",
            usage: LLMUsage(promptTokens: 100, completionTokens: 200, totalTokens: 300),
            stopReason: "end_turn",
            latencyMs: 4567
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Sorted-keys output is deterministic — assert the exact shape so any
        // future field-name drift fails this test.
        XCTAssertEqual(
            json,
            #"{"latencyMs":4567,"model":"claude-sonnet-4-6","output":"summary text","provider":"anthropic","stopReason":"end_turn","usage":{"completionTokens":200,"promptTokens":100,"totalTokens":300}}"#
        )
    }

    func testLLMResultRoundTripsThroughJSON() throws {
        let original = LLMResult(
            output: "round trip",
            provider: "lmstudio",
            model: "qwen-4b",
            usage: LLMUsage(promptTokens: 5, completionTokens: 10, totalTokens: 15),
            stopReason: "stop",
            latencyMs: 100
        )

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(LLMResult.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func testLLMResultWithNilUsageOmitsTokenSubfields() throws {
        let result = LLMResult(
            output: "no tokens",
            provider: "cli",
            model: "claude -p",
            usage: nil,
            stopReason: nil,
            latencyMs: 99
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(result)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Default Codable omits nil optionals — agents should see explicit
        // absent rather than `"usage": {}` or the like.
        XCTAssertFalse(json.contains("\"usage\""))
        XCTAssertFalse(json.contains("\"stopReason\""))
        XCTAssertTrue(json.contains("\"latencyMs\":99"))
    }

    // MARK: - LLMUsage partial fields

    func testLLMUsageAllowsPartialFields() throws {
        // Some providers (notably localCLI / openaiCompatible without usage
        // headers) report partial counts. The schema has to round-trip them.
        let usage = LLMUsage(promptTokens: 42, completionTokens: nil, totalTokens: nil)
        let data = try JSONEncoder().encode(usage)
        let decoded = try JSONDecoder().decode(LLMUsage.self, from: data)

        XCTAssertEqual(decoded.promptTokens, 42)
        XCTAssertNil(decoded.completionTokens)
        XCTAssertNil(decoded.totalTokens)
    }
}
