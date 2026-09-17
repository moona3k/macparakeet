import XCTest
@testable import MacParakeetCore

final class AppleIntelligenceLLMClientTests: XCTestCase {
    func testPromptBuilderUsesBareUserTextForSingleTurn() {
        let split = AppleIntelligencePromptBuilder.split(messages: [
            ChatMessage(role: .system, content: "Be brief."),
            ChatMessage(role: .user, content: "Hello"),
        ])
        XCTAssertEqual(split.instructions, "Be brief.")
        XCTAssertEqual(split.prompt, "Hello")
    }

    func testPromptBuilderFormatsChatHistory() {
        let split = AppleIntelligencePromptBuilder.split(messages: [
            ChatMessage(role: .user, content: "Hi"),
            ChatMessage(role: .assistant, content: "Hello"),
            ChatMessage(role: .user, content: "Follow up"),
        ])
        XCTAssertNil(split.instructions)
        XCTAssertEqual(
            split.prompt,
            "User:\nHi\n\nAssistant:\nHello\n\nUser:\nFollow up"
        )
    }

    func testDeltaEmitsOnlyNewSuffix() {
        XCTAssertEqual(
            AppleIntelligencePromptBuilder.delta(fromCumulative: "Hel", previous: ""),
            "Hel"
        )
        XCTAssertEqual(
            AppleIntelligencePromptBuilder.delta(fromCumulative: "Hello", previous: "Hel"),
            "lo"
        )
        XCTAssertEqual(
            AppleIntelligencePromptBuilder.delta(fromCumulative: "Hello", previous: "Hello"),
            ""
        )
    }

    func testDeltaSkipsDivergentSnapshot() {
        XCTAssertEqual(
            AppleIntelligencePromptBuilder.delta(fromCumulative: "Other", previous: "Hel"),
            ""
        )
    }

    func testDeltaEmitsCombiningMarkContinuation() {
        XCTAssertEqual(
            AppleIntelligencePromptBuilder.delta(fromCumulative: "cafe\u{0301}", previous: "cafe"),
            "\u{0301}"
        )
        XCTAssertEqual(
            AppleIntelligencePromptBuilder.delta(
                fromCumulative: "cafe\u{0301} au lait",
                previous: "cafe\u{0301}"
            ),
            " au lait"
        )
        XCTAssertTrue(
            AppleIntelligencePromptBuilder.isCumulativeContinuation("cafe\u{0301}", of: "cafe")
        )
    }

    func testUnavailableGeneratorFailsConnection() async {
        let client = AppleIntelligenceLLMClient(generator: UnavailableAppleIntelligenceGenerator())
        do {
            _ = try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                context: LLMExecutionContext(providerConfig: .appleIntelligence()),
                options: .default
            )
            XCTFail("Expected connection failure")
        } catch let error as LLMError {
            guard case .connectionFailed(let detail) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(detail.contains("macOS 26"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testStubGeneratorCompletesAndStreamsDeltas() async throws {
        let generator = StubAppleIntelligenceGenerator(
            availability: .available,
            chunks: ["Hel", "Hello"]
        )
        let client = AppleIntelligenceLLMClient(generator: generator)
        let context = LLMExecutionContext(providerConfig: .appleIntelligence())

        let response = try await client.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            context: context,
            options: .default
        )
        XCTAssertEqual(response.content, "Hello")
        XCTAssertEqual(response.model, "apple-intelligence")

        var streamed: [String] = []
        for try await part in client.chatCompletionStream(
            messages: [ChatMessage(role: .user, content: "Hi")],
            context: context,
            options: .default
        ) {
            streamed.append(part)
        }
        XCTAssertEqual(streamed, ["Hel", "lo"])
    }

    func testStubGeneratorStreamsCombiningMarkDeltas() async throws {
        let generator = StubAppleIntelligenceGenerator(
            availability: .available,
            chunks: ["cafe", "cafe\u{0301}", "cafe\u{0301} au lait"]
        )
        let client = AppleIntelligenceLLMClient(generator: generator)
        var streamed: [String] = []
        for try await part in client.chatCompletionStream(
            messages: [ChatMessage(role: .user, content: "Hi")],
            context: LLMExecutionContext(providerConfig: .appleIntelligence()),
            options: .default
        ) {
            streamed.append(part)
        }
        XCTAssertEqual(streamed, ["cafe", "\u{0301}", " au lait"])
    }

    func testNotEnabledAvailabilityIsConnectionFailed() async {
        let client = AppleIntelligenceLLMClient(
            generator: StubAppleIntelligenceGenerator(
                availability: .appleIntelligenceNotEnabled,
                chunks: ["nope"]
            )
        )
        do {
            _ = try await client.testConnection(
                context: LLMExecutionContext(providerConfig: .appleIntelligence())
            )
            XCTFail("Expected connection failure")
        } catch let error as LLMError {
            guard case .connectionFailed(let detail) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(detail.contains("System Settings"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testWrongProviderIsRejected() async {
        let client = AppleIntelligenceLLMClient(
            generator: StubAppleIntelligenceGenerator(availability: .available, chunks: ["x"])
        )
        do {
            _ = try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                context: LLMExecutionContext(providerConfig: .ollama()),
                options: .default
            )
            XCTFail("Expected provider error")
        } catch let error as LLMError {
            guard case .providerError(let message) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(message.contains("ollama"))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testListModelsRequiresAvailability() async throws {
        let ready = AppleIntelligenceLLMClient(
            generator: StubAppleIntelligenceGenerator(availability: .available, chunks: ["OK"])
        )
        let models = try await ready.listModels(
            context: LLMExecutionContext(providerConfig: .appleIntelligence())
        )
        XCTAssertEqual(models, ["apple-intelligence"])

        let pending = AppleIntelligenceLLMClient(
            generator: StubAppleIntelligenceGenerator(availability: .modelNotReady, chunks: ["OK"])
        )
        do {
            _ = try await pending.listModels(
                context: LLMExecutionContext(providerConfig: .appleIntelligence())
            )
            XCTFail("Expected connection failure")
        } catch let error as LLMError {
            guard case .connectionFailed = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testContentFilteredErrorCopy() {
        let error = LLMError.contentFiltered(
            "Apple Intelligence declined this request. Try rephrasing, or use a different AI provider."
        )
        XCTAssertTrue(error.localizedDescription.contains("declined"))
    }

    func testAvailabilityCurrentDoesNotCrash() {
        let availability = AppleIntelligenceAvailability.current()
        XCTAssertFalse(availability.userMessage.isEmpty)
        switch availability {
        case .unsupported, .deviceNotEligible:
            XCTAssertFalse(availability.isUserSelectable)
        case .appleIntelligenceNotEnabled, .modelNotReady, .available:
            XCTAssertTrue(availability.isUserSelectable)
        }
    }
}

private struct StubAppleIntelligenceGenerator: AppleIntelligenceGenerating {
    let availability: AppleIntelligenceAvailability
    let chunks: [String]

    func currentAvailability() -> AppleIntelligenceAvailability {
        availability
    }

    func generate(
        request: AppleIntelligenceGenerationRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        _ = request
        var previous = ""
        for chunk in chunks {
            if let onPartial {
                let delta = AppleIntelligencePromptBuilder.delta(
                    fromCumulative: chunk,
                    previous: previous
                )
                if !delta.isEmpty {
                    onPartial(delta)
                }
            }
            previous = chunk
        }
        return chunks.last ?? ""
    }
}
