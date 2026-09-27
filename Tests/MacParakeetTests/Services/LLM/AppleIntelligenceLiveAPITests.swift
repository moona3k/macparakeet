import XCTest
@testable import MacParakeetCore

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Live Foundation Models A/B. Generation is skipped unless Apple Intelligence
/// is enabled on the host; availability mapping always runs on macOS 26+ SDKs.
final class AppleIntelligenceLiveAPITests: XCTestCase {
    func testAvailabilityMappingMatchesFoundationModels() throws {
        let mapped = AppleIntelligenceAvailability.current()
        XCTAssertFalse(mapped.userMessage.isEmpty)

        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Requires macOS 26")
        }

        switch SystemLanguageModel.default.availability {
        case .available:
            if SystemLanguageModel.default.supportsLocale() {
                XCTAssertEqual(mapped, .available)
            } else {
                XCTAssertEqual(mapped, .localeLimited)
                XCTAssertTrue(mapped.canGenerate)
            }
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                XCTAssertEqual(mapped, .deviceNotEligible)
            case .appleIntelligenceNotEnabled:
                XCTAssertEqual(mapped, .appleIntelligenceNotEnabled)
            case .modelNotReady:
                XCTAssertEqual(mapped, .modelNotReady)
            @unknown default:
                XCTAssertEqual(mapped, .unsupported)
            }
        @unknown default:
            XCTAssertEqual(mapped, .unsupported)
        }

        XCTAssertGreaterThan(SystemLanguageModel.default.contextSize, 0)
        #else
        XCTAssertEqual(mapped, .unsupported)
        #endif
    }

    func testLiveRespondStreamAndClientAB() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Requires macOS 26")
        }
        let availability = AppleIntelligenceAvailability.current()
        guard availability.canGenerate else {
            throw XCTSkip(
                "Apple Intelligence generation A/B skipped: \(availability.rawValue) — \(availability.userMessage)"
            )
        }
        guard SystemLanguageModel.default.supportsLocale() else {
            throw XCTSkip("Apple Intelligence does not support the current app locale")
        }

        let prompt = "Reply with the single word PING and nothing else."
        let options = GenerationOptions(temperature: 0, maximumResponseTokens: 16)

        let respondSession = LanguageModelSession(instructions: "Be terse.")
        let respondText = try await respondSession.respond(to: prompt, options: options).content

        let streamSession = LanguageModelSession(instructions: "Be terse.")
        var streamed = ""
        var reducer = AppleIntelligenceStreamReducer()
        for try await snapshot in streamSession.streamResponse(to: prompt, options: options) {
            let delta = try reducer.consume(snapshot.content)
            if !delta.isEmpty {
                streamed += delta
            }
        }

        let client = AppleIntelligenceLLMClient()
        let clientResponse = try await client.chatCompletion(
            messages: [
                ChatMessage(role: .system, content: "Be terse."),
                ChatMessage(role: .user, content: prompt),
            ],
            context: LLMExecutionContext(providerConfig: .appleIntelligence()),
            options: ChatCompletionOptions(temperature: 0, maxTokens: 16)
        )

        XCTAssertFalse(respondText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertFalse(reducer.emitted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(reducer.emitted, streamed)
        XCTAssertFalse(clientResponse.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(clientResponse.model, "apple-intelligence")

        print("LIVE_AB availability=available")
        print("LIVE_AB respond=\(respondText)")
        print("LIVE_AB stream=\(reducer.emitted)")
        print("LIVE_AB client=\(clientResponse.content)")

        let normalizedRespond = respondText.lowercased()
        let normalizedStream = reducer.emitted.lowercased()
        let normalizedClient = clientResponse.content.lowercased()
        XCTAssertTrue(normalizedRespond.contains("ping") || normalizedRespond.count < 80)
        XCTAssertTrue(normalizedStream.contains("ping") || normalizedStream.count < 80)
        XCTAssertTrue(normalizedClient.contains("ping") || normalizedClient.count < 80)
        #else
        throw XCTSkip("FoundationModels is not importable in this toolchain")
        #endif
    }

    /// Timestamped, speaker-labeled transcripts run near 2.8 characters per
    /// token, so the 12k-character budget alone overflowed the 4,096-token
    /// window ("Text exceeds the model's context limit"). The measured fit
    /// must leave room for the answer.
    func testLiveDenseTranscriptPromptResultFitsTheWindow() async throws {
        #if canImport(FoundationModels) && compiler(>=6.3)
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("Token counting requires macOS 26.4")
        }
        guard AppleIntelligenceAvailability.current().canGenerate, SystemLanguageModel.default.supportsLocale()
        else {
            throw XCTSkip("Apple Intelligence generation is unavailable on this Mac")
        }
        let transcript = (0..<260).map { index in
            "[00:\(String(format: "%02d:%02d", index * 9 / 60 % 60, index * 9 % 60))] Speaker \(index % 7 + 1): "
                + "We reviewed step \(index) of the rollout, including a budget of \(index * 37) dollars, "
                + "owner number \(index % 11), and the follow-up date."
        }.joined(separator: "\n")
        let store = MockLLMConfigStore()
        store.config = .appleIntelligence()
        let service = LLMService(
            client: RoutingLLMClient(),
            contextResolver: MockLLMExecutionContextResolver(configStore: store)
        )

        let result = try await service.generatePromptResultDetailed(
            transcript: transcript,
            systemPrompt: """
                Break this transcript into logical chapters. For each chapter give a concise title, \
                a 2-4 sentence summary, and notable moments attributed to the speaker.
                """,
            inferenceSettings: nil
        )

        XCTAssertFalse(result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        print("LIVE_FIT outputChars=\(result.output.count)")
        #else
        throw XCTSkip("Token counting needs FoundationModels from the macOS 26.4 SDK")
        #endif
    }
}
