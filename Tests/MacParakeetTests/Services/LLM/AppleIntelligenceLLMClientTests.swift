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

    func testBlankGenerationIsInvalidResponse() async {
        let client = AppleIntelligenceLLMClient(
            generator: StubAppleIntelligenceGenerator(availability: .available, chunks: [" \n"])
        )
        do {
            _ = try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                context: LLMExecutionContext(providerConfig: .appleIntelligence()),
                options: .default
            )
            XCTFail("Expected invalid response")
        } catch let error as LLMError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected error \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testGenerationPreservesEdgeWhitespace() async throws {
        let client = AppleIntelligenceLLMClient(
            generator: StubAppleIntelligenceGenerator(availability: .available, chunks: ["  Hello\n"])
        )
        let response = try await client.chatCompletion(
            messages: [ChatMessage(role: .user, content: "Hi")],
            context: LLMExecutionContext(providerConfig: .appleIntelligence()),
            options: .default
        )
        XCTAssertEqual(response.content, "  Hello\n")
    }

    func testGenerationThatReturnsAfterCancelIsNotSuccess() async {
        let generator = CancelThenReturnGenerator()
        let client = AppleIntelligenceLLMClient(generator: generator)
        let task = Task {
            try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                context: LLMExecutionContext(providerConfig: .appleIntelligence()),
                options: .default
            )
        }
        await generator.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testTemperatureAboveOneIsRejectedBeforeGeneration() async {
        let client = AppleIntelligenceLLMClient(
            generator: StubAppleIntelligenceGenerator(availability: .available, chunks: ["should not run"])
        )
        do {
            _ = try await client.chatCompletion(
                messages: [ChatMessage(role: .user, content: "Hi")],
                context: LLMExecutionContext(providerConfig: .appleIntelligence()),
                options: ChatCompletionOptions(temperature: 1.5)
            )
            XCTFail("Expected temperature validation failure")
        } catch let error as PromptInferenceSettings.ValidationError {
            XCTAssertEqual(error, .outOfRange(field: .temperature, minimum: 0, maximum: 1))
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testStreamReducerThrowsWhenASnapshotDiverges() throws {
        var reducer = AppleIntelligenceStreamReducer()
        XCTAssertEqual(try reducer.consume("Hel"), "Hel")
        XCTAssertThrowsError(try reducer.consume("Other")) { error in
            guard case LLMError.streamingError = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertEqual(reducer.emitted, "Hel")
    }

    func testFailureMapperSurfacesOverflowAndGuardrails() {
        guard case .contextTooLong = AppleIntelligenceFailureMapper.llmError(for: .exceededContextWindow) else {
            return XCTFail("Expected contextTooLong")
        }
        guard case .rateLimited = AppleIntelligenceFailureMapper.llmError(for: .rateLimited) else {
            return XCTFail("Expected rateLimited")
        }
        let filtered = AppleIntelligenceFailureMapper.llmError(for: .guardrailOrRefusal)
        guard case .contentFiltered(let message) = filtered else {
            return XCTFail("Expected contentFiltered, got \(filtered)")
        }
        XCTAssertTrue(message.contains("declined"))
        let busy = AppleIntelligenceFailureMapper.llmError(for: .concurrentRequests)
        guard case .providerError(let busyMessage) = busy else {
            return XCTFail("Expected providerError, got \(busy)")
        }
        XCTAssertTrue(busyMessage.contains("busy"))
        let language = AppleIntelligenceFailureMapper.llmError(for: .unsupportedLanguageOrLocale)
        guard case .providerError(let languageMessage) = language else {
            return XCTFail("Expected providerError, got \(language)")
        }
        XCTAssertTrue(languageMessage.contains("language"))
    }

    func testContentFilteredErrorCopy() {
        let error = LLMError.contentFiltered(
            "Apple Intelligence declined this request. Try rephrasing, or use a different AI provider."
        )
        XCTAssertTrue(error.localizedDescription.contains("declined"))
    }

    func testNotEnabledSettingsURLOpensTheSiriPane() {
        XCTAssertEqual(
            AppleIntelligenceAvailability.appleIntelligenceNotEnabled.settingsURL?.absoluteString,
            "x-apple.systempreferences:com.apple.Siri-Settings.extension"
        )
    }

    func testAvailabilityCurrentDoesNotCrash() {
        let availability = AppleIntelligenceAvailability.current()
        XCTAssertFalse(availability.userMessage.isEmpty)
        switch availability {
        case .unsupported, .deviceNotEligible:
            XCTAssertFalse(availability.isUserSelectable)
        case .appleIntelligenceNotEnabled, .modelNotReady, .available, .localeLimited:
            XCTAssertTrue(availability.isUserSelectable)
            XCTAssertEqual(availability.canGenerate, availability == .available || availability == .localeLimited)
        }
    }
}

private final class CancelThenReturnGenerator: AppleIntelligenceGenerating, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var started = false

    func waitUntilStarted() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            if register(waiter) {
                waiter.resume()
            }
        }
    }

    func currentAvailability() -> AppleIntelligenceAvailability {
        .available
    }

    func generate(
        request: AppleIntelligenceGenerationRequest,
        onPartial: (@Sendable (String) -> Void)?
    ) async throws -> String {
        _ = request
        markStarted()?.resume()
        onPartial?("partial")
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
        } catch is CancellationError {
            return "partial"
        }
        return "partial"
    }

    /// Returns true when generation has already started and the caller should resume `waiter`.
    private func register(_ waiter: CheckedContinuation<Void, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if started { return true }
        continuation = waiter
        return false
    }

    private func markStarted() -> CheckedContinuation<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        started = true
        let waiter = continuation
        continuation = nil
        return waiter
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
        if let onPartial {
            var reducer = AppleIntelligenceStreamReducer()
            for chunk in chunks {
                let delta = try reducer.consume(chunk)
                if !delta.isEmpty {
                    onPartial(delta)
                }
            }
            return reducer.emitted
        }
        return chunks.last ?? ""
    }
}
