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
            XCTAssertEqual(mapped, .available)
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
        if mapped == .available {
            XCTAssertTrue(SystemLanguageModel.default.supportsLocale())
        }
        #else
        XCTAssertEqual(mapped, .unsupported)
        #endif
    }

    func testLiveTokenCountAPIWhenModelIsPresent() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.4, *) else {
            throw XCTSkip("tokenCount requires macOS 26.4")
        }
        let prompt = "Reply with the single word PING and nothing else."
        do {
            let tokenCount = try await SystemLanguageModel.default.tokenCount(for: prompt)
            let naiveEstimate = max(1, prompt.count / 4)
            print(
                "LIVE_AB tokenCount=\(tokenCount) chars=\(prompt.count) naiveChars/4=\(naiveEstimate)"
            )
            XCTAssertGreaterThan(tokenCount, 0)
            XCTAssertLessThan(tokenCount, prompt.count)
            XCTAssertLessThan(abs(tokenCount - naiveEstimate), naiveEstimate)
        } catch {
            throw XCTSkip(
                "tokenCount A/B skipped: \(AppleIntelligenceAvailability.current().rawValue) — \(error.localizedDescription)"
            )
        }
        #else
        throw XCTSkip("FoundationModels is not importable in this toolchain")
        #endif
    }

    func testLiveRespondStreamAndClientAB() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Requires macOS 26")
        }
        let availability = AppleIntelligenceAvailability.current()
        guard availability == .available else {
            throw XCTSkip(
                "Apple Intelligence generation A/B skipped: \(availability.rawValue) — \(availability.userMessage)"
            )
        }

        let prompt = "Reply with the single word PING and nothing else."
        let options = GenerationOptions(temperature: 0, maximumResponseTokens: 16)

        let respondSession = LanguageModelSession(instructions: "Be terse.")
        let respondText = try await respondSession.respond(to: prompt, options: options).content

        let streamSession = LanguageModelSession(instructions: "Be terse.")
        var streamed = ""
        var previous = ""
        for try await snapshot in streamSession.streamResponse(to: prompt, options: options) {
            let current = snapshot.content
            let delta = AppleIntelligencePromptBuilder.delta(
                fromCumulative: current,
                previous: previous
            )
            if !delta.isEmpty {
                streamed += delta
            }
            if AppleIntelligencePromptBuilder.isCumulativeContinuation(current, of: previous) {
                previous = current
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
        XCTAssertFalse(previous.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(previous, streamed)
        XCTAssertFalse(clientResponse.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertEqual(clientResponse.model, "apple-intelligence")

        print("LIVE_AB availability=available")
        print("LIVE_AB respond=\(respondText)")
        print("LIVE_AB stream=\(previous)")
        print("LIVE_AB client=\(clientResponse.content)")

        let normalizedRespond = respondText.lowercased()
        let normalizedStream = previous.lowercased()
        let normalizedClient = clientResponse.content.lowercased()
        XCTAssertTrue(normalizedRespond.contains("ping") || normalizedRespond.count < 80)
        XCTAssertTrue(normalizedStream.contains("ping") || normalizedStream.count < 80)
        XCTAssertTrue(normalizedClient.contains("ping") || normalizedClient.count < 80)
        #else
        throw XCTSkip("FoundationModels is not importable in this toolchain")
        #endif
    }
}
