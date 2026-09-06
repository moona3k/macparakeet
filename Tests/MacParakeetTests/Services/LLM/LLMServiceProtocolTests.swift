import XCTest
@testable import MacParakeetCore

final class LLMServiceProtocolTests: XCTestCase {
    func testLegacyFallbackPreservesNilAndDefaultSettings() async throws {
        let service: any LLMServiceProtocol = LegacyPromptLLMService()
        let inheritedSettings: [PromptInferenceSettings?] = [nil, PromptInferenceSettings()]
        for settings in inheritedSettings {
            let result = try await service.generatePromptResultDetailed(
                transcript: "input", systemPrompt: nil, inferenceSettings: settings
            )
            XCTAssertEqual(result.output, "legacy")
            var events: [LLMStreamEvent] = []
            for try await event in service.generatePromptResultDetailedStream(
                transcript: "input", systemPrompt: nil, inferenceSettings: settings
            ) { events.append(event) }
            XCTAssertEqual(
                events, [.text("legacy"), .completed(LLMStreamTerminal(provider: "unknown", model: "unknown"))])
        }
    }

    func testLegacyFallbackRejectsOverridesBeforeCallingLegacyImplementation() async throws {
        let service: any LLMServiceProtocol = LegacyPromptLLMService(rejectLegacyCalls: true)
        let settings = PromptInferenceSettings(temperature: 0.2)
        do {
            _ = try await service.generatePromptResultDetailed(
                transcript: "input", systemPrompt: nil, inferenceSettings: settings
            )
            XCTFail("Expected unsupported settings")
        } catch is UnsupportedPromptInferenceSettingsError {
        }
        do {
            for try await _ in service.generatePromptResultDetailedStream(
                transcript: "input", systemPrompt: nil, inferenceSettings: settings
            ) { XCTFail("Unsupported settings must not emit data") }
            XCTFail("Expected unsupported settings")
        } catch is UnsupportedPromptInferenceSettingsError {
        }
        do {
            for try await _ in service.generatePromptResultStream(
                transcript: "input", systemPrompt: nil, inferenceSettings: settings
            ) { XCTFail("String facade must preserve the rejection") }
            XCTFail("Expected unsupported settings")
        } catch is UnsupportedPromptInferenceSettingsError {
        }
    }
}

private struct LegacyPromptLLMService: LLMServiceProtocol {
    var rejectLegacyCalls = false
    private var result: LLMResult { LLMResult(output: "legacy", provider: "legacy", model: "legacy", latencyMs: 0) }
    private func legacyResult() throws -> LLMResult {
        if rejectLegacyCalls { throw LLMError.invalidResponse }
        return result
    }
    func generatePromptResult(transcript: String, systemPrompt: String?) async throws -> String {
        try legacyResult().output
    }
    func generatePromptResultDetailed(transcript: String, systemPrompt: String?) async throws -> LLMResult {
        try legacyResult()
    }
    func generatePromptResultStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            do {
                continuation.yield(try legacyResult().output)
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
    }
    func chat(
        question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource,
        conversationID: UUID
    ) async throws -> String { result.output }
    func chatDetailed(
        question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource,
        conversationID: UUID
    ) async throws -> LLMResult { result }
    func chatStream(
        question: String, transcript: String, userNotes: String?, history: [ChatMessage], source: TelemetryChatSource,
        conversationID: UUID
    ) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func transform(text: String, prompt: String) async throws -> String { result.output }
    func transformDetailed(text: String, prompt: String) async throws -> LLMResult { result }
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func formatTranscript(
        transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool
    ) async throws -> String { result.output }
    func formatTranscriptDetailed(
        transcript: String, promptTemplate: String, source: TelemetryFormatterSource, defaultPromptUsed: Bool
    ) async throws -> LLMFormatterResult {
        LLMFormatterResult(
            result: result, operationID: "legacy", inputChars: transcript.count, outputChars: result.output.count,
            inputTruncated: false, defaultPromptUsed: defaultPromptUsed, messageCount: 2)
    }
}
