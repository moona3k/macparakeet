import XCTest
@testable import MacParakeetCore

final class AskModelBridgeTests: XCTestCase {
    private let context = LLMExecutionContext(providerConfig: .openai(apiKey: "test-only", model: "scripted"))
    private let messages = [ChatMessage(role: .user, content: "How did the date change?")]

    func testValidToolActionIsParsedAndConstrained() async throws {
        let client = ScriptedAskLLMClient(
            decision: #"{"kind":"tool","toolName":"search","argumentsJSON":"{\"query\":\"launch date\",\"limit\":3}"}"#)
        let action = try await AskModelBridge.decide(messages: messages, client: client, context: context)
        XCTAssertEqual(action.kind, "tool")
        XCTAssertEqual(action.toolName, "search")
        XCTAssertEqual(action.arguments?["query"] as? String, "launch date")
        XCTAssertEqual(action.arguments?["limit"] as? Int, 3)
    }

    func testSourceRestrictedSearchActionIsAccepted() async throws {
        let client = ScriptedAskLLMClient(
            decision:
                #"{"kind":"tool","toolName":"search","argumentsJSON":"{\"query\":\"launch\",\"sourceID\":\"A\",\"limit\":12}"}"#
        )
        let action = try await AskModelBridge.decide(messages: messages, client: client, context: context)
        XCTAssertEqual(action.toolName, "search")
        XCTAssertEqual(action.arguments?["sourceID"] as? String, "A")
    }

    func testMalformedAndUnknownActionsFailClosed() async throws {
        let invalid = [
            "not JSON",
            #"{"kind":"tool","toolName":"shell","argumentsJSON":"{}"}"#,
            #"{"kind":"tool","toolName":"read","argumentsJSON":"{\"sourceID\":\"source\",\"start\":-1,\"limit\":5}"}"#,
            #"{"kind":"tool","toolName":"list_sources","argumentsJSON":"{\"unexpected\":true}"}"#,
            #"{"kind":"final","toolName":"search","argumentsJSON":"{}"}"#,
            #"{"kind":"tool","toolName":"read","argumentsJSON":"{\"sourceID\":\"A\",\"start\":0,\"limit\":13}"}"#,
        ]
        for decision in invalid {
            let client = ScriptedAskLLMClient(decision: decision)
            do {
                _ = try await AskModelBridge.decide(messages: messages, client: client, context: context)
                XCTFail("Accepted invalid decision: \(decision)")
            } catch {}
        }
    }

    func testDetailedStreamForwardsTextAndRequiresSuccessfulTerminal() async throws {
        let client = ScriptedAskLLMClient(decision: "", finalChunks: ["June ", "became July."], stopReason: "stop")
        let collected = AskTextCollector()
        try await AskModelBridge.streamFinal(messages: messages, client: client, context: context) { chunk in
            await collected.append(chunk)
        }
        let result = await collected.text
        XCTAssertEqual(result, "June became July.")
    }

    func testNonSuccessTerminalFails() async throws {
        let client = ScriptedAskLLMClient(decision: "", finalChunks: ["Filtered"], stopReason: "content_filter")
        do {
            try await AskModelBridge.streamFinal(messages: messages, client: client, context: context) { _ in }
            XCTFail("Content filtered model response was accepted")
        } catch AskAgentError.budgetExceeded {}
    }

    func testTextAfterTerminalFails() async throws {
        let client = ScriptedAskLLMClient(
            decision: "", finalChunks: ["First"], stopReason: "stop", textAfterTerminal: "Late"
        )
        do {
            try await AskModelBridge.streamFinal(messages: messages, client: client, context: context) { _ in }
            XCTFail("Text after terminal was accepted")
        } catch AskAgentError.protocolViolation {}
    }

    func testTruncatedFinalStreamFails() async throws {
        let client = ScriptedAskLLMClient(decision: "", finalChunks: ["Incomplete"], stopReason: "max_tokens")
        do {
            try await AskModelBridge.streamFinal(messages: messages, client: client, context: context) { _ in }
            XCTFail("Truncated model response was accepted")
        } catch AskAgentError.budgetExceeded {}
    }
}

private final class ScriptedAskLLMClient: LLMClientProtocol, @unchecked Sendable {
    let decision: String
    let finalChunks: [String]
    let stopReason: String?
    let textAfterTerminal: String?

    init(
        decision: String, finalChunks: [String] = [], stopReason: String? = nil,
        textAfterTerminal: String? = nil
    ) {
        self.decision = decision
        self.finalChunks = finalChunks
        self.stopReason = stopReason
        self.textAfterTerminal = textAfterTerminal
    }

    func chatCompletion(
        messages: [ChatMessage], context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(content: decision, model: "scripted")
    }

    func chatCompletionStream(
        messages: [ChatMessage], context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            for chunk in finalChunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    func chatCompletionDetailedStream(
        messages: [ChatMessage], context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            for chunk in finalChunks { continuation.yield(.text(chunk)) }
            continuation.yield(
                .completed(LLMStreamTerminal(provider: "scripted", model: "scripted", stopReason: stopReason)))
            if let textAfterTerminal { continuation.yield(.text(textAfterTerminal)) }
            continuation.finish()
        }
    }

    func testConnection(context: LLMExecutionContext) async throws {}
    func listModels(context: LLMExecutionContext) async throws -> [String] { [] }
}

private actor AskTextCollector {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}
