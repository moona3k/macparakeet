import XCTest
@testable import MacParakeetCore

final class PromptInferenceSettingsTests: XCTestCase {
    func testDefaultNormalizesToNil() throws {
        let settings = PromptInferenceSettings()
        XCTAssertTrue(settings.isDefault)
        XCTAssertNil(try settings.validated())
    }

    func testValidationAcceptsBoundaryValues() throws {
        XCTAssertNotNil(
            try PromptInferenceSettings(
                temperature: 0,
                topP: 1,
                topK: 0,
                maxTokens: 131_072,
                thinkingMode: .disabled
            ).validated())
    }

    func testValidationRejectsInvalidAndNonFiniteValues() {
        XCTAssertThrowsError(try PromptInferenceSettings(temperature: .nan).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(temperature: .infinity).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(topP: -.infinity).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(temperature: 2.000_001).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(topP: -0.000_001).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(topK: 1001).validated())
        XCTAssertThrowsError(try PromptInferenceSettings(maxTokens: 0).validated())
    }

    func testCodableRoundTrip() throws {
        let settings = PromptInferenceSettings(
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            maxTokens: 4096,
            thinkingMode: .enabled,
            reasoningEffort: .xhigh
        )
        let decoded = try JSONDecoder().decode(
            PromptInferenceSettings.self,
            from: JSONEncoder().encode(settings)
        )
        XCTAssertEqual(decoded, settings)
    }

    func testDecodingOlderPartialJSONUsesDefaultThinkingMode() throws {
        let empty = try JSONDecoder().decode(
            PromptInferenceSettings.self,
            from: Data("{}".utf8)
        )
        XCTAssertEqual(empty, PromptInferenceSettings())

        let partial = try JSONDecoder().decode(
            PromptInferenceSettings.self,
            from: Data(#"{"temperature":0.2,"reasoningEffort":"low"}"#.utf8)
        )
        XCTAssertEqual(partial, PromptInferenceSettings(temperature: 0.2))
    }

    func testDecodedDisabledThinkingDoesNotExportInactiveEffort() throws {
        let decoded = try JSONDecoder().decode(
            PromptInferenceSettings.self,
            from: Data(#"{"temperature":0.2,"thinkingMode":"disabled","reasoningEffort":"high"}"#.utf8)
        )
        let exported = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any]
        )
        XCTAssertNil(exported["reasoningEffort"])
        XCTAssertEqual(exported["thinkingMode"] as? String, "disabled")
        XCTAssertEqual(exported["temperature"] as? Double, 0.2)
    }

    func testDecodingLegacySeedIgnoresRemovedField() throws {
        let decoded = try JSONDecoder().decode(
            PromptInferenceSettings.self,
            from: Data(#"{"seed":42,"thinkingMode":"enabled"}"#.utf8)
        )

        XCTAssertEqual(decoded, PromptInferenceSettings(thinkingMode: .enabled))
    }

    func testReasoningEffortIsEffectiveOnlyWhenThinkingIsEnabled() throws {
        XCTAssertEqual(
            try PromptInferenceSettings(
                thinkingMode: .enabled,
                reasoningEffort: .medium
            ).validated(),
            PromptInferenceSettings(thinkingMode: .enabled, reasoningEffort: .medium)
        )
        XCTAssertEqual(
            try PromptInferenceSettings(
                thinkingMode: .disabled,
                reasoningEffort: .xhigh
            ).validated(),
            PromptInferenceSettings(thinkingMode: .disabled)
        )
        XCTAssertNil(try PromptInferenceSettings(reasoningEffort: .low).validated())
    }

    func testResolverPreservesBaselineReasoningEffortWhenThinkingIsInherited() throws {
        let baseline = ChatCompletionOptions(
            temperature: 0.7,
            thinkingMode: .enabled,
            reasoningEffort: .high
        )

        let resolution = try PromptInferenceCapabilityResolver.resolve(
            config: .openaiCompatible(model: "local-model", baseURL: URL(string: "http://localhost:8080/v1")!),
            baseline: baseline,
            requested: PromptInferenceSettings(maxTokens: 512)
        )

        XCTAssertEqual(
            resolution.effectiveSettings,
            PromptInferenceSettings(temperature: 0.7, maxTokens: 512, thinkingMode: .enabled, reasoningEffort: .high)
        )
    }

    func testResolverRejectsInvalidValuesEvenWhenProviderWouldOmitThem() {
        XCTAssertThrowsError(
            try PromptInferenceCapabilityResolver.resolve(
                config: .openai(apiKey: "key", model: "gpt-5.5"),
                requested: PromptInferenceSettings(temperature: 3)
            )
        ) { error in
            XCTAssertEqual(
                error as? PromptInferenceSettings.ValidationError,
                .outOfRange(field: .temperature, minimum: 0, maximum: 2)
            )
        }
    }

    func testAnthropicTemperatureRangeAppliesAfterTopPPrecedence() throws {
        let config = LLMProviderConfig.anthropic(apiKey: "key", model: "claude-haiku-4-5")
        XCTAssertThrowsError(
            try PromptInferenceCapabilityResolver.resolve(
                config: config, requested: PromptInferenceSettings(temperature: 1.5)
            )
        ) { error in
            XCTAssertEqual(
                error as? PromptInferenceSettings.ValidationError,
                .outOfRange(field: .temperature, minimum: 0, maximum: 1)
            )
        }
        let boundary = try PromptInferenceCapabilityResolver.resolve(
            config: config, requested: PromptInferenceSettings(temperature: 1)
        )
        XCTAssertEqual(boundary.effectiveSettings, PromptInferenceSettings(temperature: 1, maxTokens: 4096))
        for topP in [0.0, 0.9] {
            let resolution = try PromptInferenceCapabilityResolver.resolve(
                config: config, requested: PromptInferenceSettings(temperature: 1.5, topP: topP)
            )
            XCTAssertEqual(resolution.effectiveSettings, PromptInferenceSettings(topP: topP, maxTokens: 4096))
            XCTAssertEqual(resolution.unsupportedSettings, [.temperature])
        }
    }

    func testEffectiveReceiptIncludesInheritedValuesActuallySent() throws {
        let custom = try PromptInferenceCapabilityResolver.resolve(
            config: .openaiCompatible(
                model: "generic-model",
                baseURL: URL(string: "http://localhost:8080/v1")!
            ),
            requested: nil)
        XCTAssertEqual(custom.effectiveSettings, PromptInferenceSettings(temperature: 0.7))

        let anthropic = try PromptInferenceCapabilityResolver.resolve(
            config: .anthropic(apiKey: "key", model: "claude-sonnet-5"),
            requested: nil)
        XCTAssertEqual(anthropic.effectiveSettings, PromptInferenceSettings(maxTokens: 4096))

        let openAIReasoning = try PromptInferenceCapabilityResolver.resolve(
            config: .openai(apiKey: "key", model: "gpt-5.5"),
            requested: nil)
        XCTAssertNil(openAIReasoning.effectiveSettings)
    }

    func testAnthropicTopPReplacesInheritedTemperatureAndRegeneratesUnchanged() throws {
        let config = LLMProviderConfig.anthropic(apiKey: "key", model: "claude-haiku-4-5")
        for topP in [0.0, 0.9] {
            let resolution = try PromptInferenceCapabilityResolver.resolve(
                config: config,
                requested: PromptInferenceSettings(topP: topP))

            XCTAssertNil(resolution.options.temperature)
            XCTAssertEqual(resolution.options.topP, topP)
            XCTAssertTrue(resolution.unsupportedSettings.isEmpty)
            XCTAssertEqual(
                resolution.effectiveSettings,
                PromptInferenceSettings(topP: topP, maxTokens: 4096)
            )
            XCTAssertEqual(resolution.options.effectiveInferenceSettings, resolution.effectiveSettings)

            let regenerated = try PromptInferenceCapabilityResolver.resolve(
                config: config,
                requested: resolution.effectiveSettings)
            XCTAssertNil(regenerated.options.temperature)
            XCTAssertEqual(regenerated.effectiveSettings, resolution.effectiveSettings)
        }
    }

    func testAnthropicTopPWinsOverExplicitTemperatureAndReportsOmission() throws {
        let resolution = try PromptInferenceCapabilityResolver.resolve(
            config: .anthropic(apiKey: "key", model: "claude-sonnet-4-6"),
            requested: PromptInferenceSettings(temperature: 0.2, topP: 0.9))

        XCTAssertNil(resolution.options.temperature)
        XCTAssertEqual(resolution.options.topP, 0.9)
        XCTAssertEqual(resolution.unsupportedSettings, [.temperature])
        XCTAssertEqual(resolution.effectiveSettings, PromptInferenceSettings(topP: 0.9, maxTokens: 4096))
    }

    func testAnthropicWithoutTopPPreservesHistoricalSampling() throws {
        let config = LLMProviderConfig.anthropic(apiKey: "key", model: "claude-haiku-4-5")
        let defaultResolution = try PromptInferenceCapabilityResolver.resolve(config: config, requested: nil)
        XCTAssertEqual(defaultResolution.options.temperature, 0.7)
        XCTAssertNil(defaultResolution.options.topP)
        XCTAssertEqual(
            defaultResolution.effectiveSettings,
            PromptInferenceSettings(temperature: 0.7, maxTokens: 4096)
        )

        let explicitResolution = try PromptInferenceCapabilityResolver.resolve(
            config: config,
            requested: PromptInferenceSettings(temperature: 0.2))
        XCTAssertEqual(explicitResolution.options.temperature, 0.2)
        XCTAssertNil(explicitResolution.options.topP)
        XCTAssertTrue(explicitResolution.unsupportedSettings.isEmpty)
        XCTAssertEqual(
            explicitResolution.effectiveSettings,
            PromptInferenceSettings(temperature: 0.2, maxTokens: 4096)
        )
    }

    func testCustomOpenAICompatibleSupportsEverySetting() throws {
        let requested = PromptInferenceSettings(
            temperature: 0.2,
            topP: 0.9,
            topK: 20,
            maxTokens: 4096,
            thinkingMode: .enabled,
            reasoningEffort: .xhigh
        )
        let resolution = try PromptInferenceCapabilityResolver.resolve(
            config: .openaiCompatible(
                model: "local-model",
                baseURL: URL(string: "http://localhost:8080/v1")!
            ),
            requested: requested)

        XCTAssertEqual(resolution.effectiveSettings, requested)
        XCTAssertTrue(resolution.unsupportedSettings.isEmpty)
        XCTAssertEqual(resolution.options.temperature, 0.2)
        XCTAssertEqual(resolution.options.thinkingMode, .enabled)
        XCTAssertEqual(resolution.options.reasoningEffort, .xhigh)
    }

    func testOpenAIReasoningModelReportsUnsupportedSampling() throws {
        let resolution = try PromptInferenceCapabilityResolver.resolve(
            config: .openai(apiKey: "key", model: "gpt-5.5"),
            requested: PromptInferenceSettings(
                temperature: 0.2,
                topP: 0.9,
                topK: 20,
                maxTokens: 4096,
                thinkingMode: .enabled,
                reasoningEffort: .medium
            ))

        XCTAssertEqual(resolution.options.maxTokens, 4096)
        XCTAssertNil(resolution.options.temperature)
        XCTAssertEqual(
            resolution.unsupportedSettings,
            [.temperature, .topP, .topK, .thinkingMode, .reasoningEffort]
        )
        XCTAssertEqual(
            resolution.effectiveSettings,
            PromptInferenceSettings(maxTokens: 4096)
        )
    }

    func testLocalCLIReportsAllExplicitSettingsUnsupported() throws {
        let requested = PromptInferenceSettings(temperature: 0.2, thinkingMode: .disabled)
        let resolution = try PromptInferenceCapabilityResolver.resolve(
            config: LLMProviderConfig(
                id: .localCLI,
                baseURL: URL(string: "http://localhost")!,
                apiKey: nil,
                modelName: "claude",
                isLocal: false
            ),
            requested: requested)

        XCTAssertNil(resolution.effectiveSettings)
        XCTAssertEqual(resolution.unsupportedSettings, [.temperature, .thinkingMode])
        XCTAssertNil(resolution.options.temperature)
    }

    func testOllamaDefaultPreservesLegacyRequestSemantics() throws {
        let resolution = try PromptInferenceCapabilityResolver.resolve(
            config: .ollama(model: "qwen3.5:9b"),
            requested: nil)

        XCTAssertNil(resolution.options.temperature)
        XCTAssertEqual(resolution.options.thinkingMode, .disabled)
        XCTAssertEqual(
            resolution.effectiveSettings,
            PromptInferenceSettings(thinkingMode: .disabled)
        )
        XCTAssertTrue(resolution.unsupportedSettings.isEmpty)
    }

    func testOllamaReportsReasoningEffortUnsupported() throws {
        let resolution = try PromptInferenceCapabilityResolver.resolve(
            config: .ollama(model: "local-model"),
            requested: PromptInferenceSettings(
                thinkingMode: .enabled,
                reasoningEffort: .medium
            ))

        XCTAssertEqual(resolution.options.thinkingMode, .enabled)
        XCTAssertNil(resolution.options.reasoningEffort)
        XCTAssertEqual(resolution.unsupportedSettings, [.reasoningEffort])
        XCTAssertEqual(
            resolution.effectiveSettings,
            PromptInferenceSettings(thinkingMode: .enabled)
        )
    }
}
