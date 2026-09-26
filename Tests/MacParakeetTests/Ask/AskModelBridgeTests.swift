import XCTest
@testable import MacParakeetCore

final class AskModelBridgeTests: XCTestCase {
    private let context = LLMExecutionContext(providerConfig: .openai(apiKey: "test-only", model: "scripted"))
    private let messages = [ChatMessage(role: .user, content: "How did the date change?")]

    func testValidToolActionIsParsedAndConstrained() async throws {
        let client = ScriptedAskLLMClient(
            decision:
                #"{"kind":"tool","toolName":"search","query":"launch date","sourceID":"","start":0,"limit":3}"#)
        let action = try await AskModelBridge.decide(messages: messages, client: client, context: context)
        XCTAssertEqual(action.kind, "tool")
        XCTAssertEqual(action.toolName, "search")
        XCTAssertEqual(action.arguments?["query"] as? String, "launch date")
        XCTAssertEqual(action.arguments?["limit"] as? Int, 3)
    }

    func testSourceRestrictedSearchActionIsAccepted() async throws {
        let client = ScriptedAskLLMClient(
            decision:
                #"{"kind":"tool","toolName":"search","query":"launch","sourceID":"A","start":0,"limit":12}"#
        )
        let action = try await AskModelBridge.decide(messages: messages, client: client, context: context)
        XCTAssertEqual(action.toolName, "search")
        XCTAssertEqual(action.arguments?["sourceID"] as? String, "A")
    }

    func testTypedToolArgumentsRemoveUnusedDefaults() async throws {
        let cases: [(String, String, Set<String>)] = [
            (
                #"{"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":0,"limit":0}"#,
                "list_sources", []
            ),
            (
                #"{"kind":"tool","toolName":"search","query":"launch","sourceID":"","start":0,"limit":0}"#,
                "search", ["query"]
            ),
            (
                #"{"kind":"tool","toolName":"read","query":"","sourceID":"A","start":0,"limit":12}"#, "read",
                ["sourceID", "start", "limit"]
            ),
            (
                #"{"kind":"tool","toolName":"get_summary","query":"","sourceID":"A","start":0,"limit":0}"#,
                "get_summary", ["sourceID"]
            ),
        ]
        for (decision, toolName, keys) in cases {
            let action = try await AskModelBridge.decide(
                messages: messages, client: ScriptedAskLLMClient(decision: decision), context: context)
            XCTAssertEqual(action.toolName, toolName)
            XCTAssertEqual(Set(try XCTUnwrap(action.arguments).keys), keys)
        }
    }

    func testFinalActionRequiresNoToolArguments() async throws {
        let client = ScriptedAskLLMClient(
            decision: #"{"kind":"final","toolName":"","query":"","sourceID":"","start":0,"limit":0}"#)
        let action = try await AskModelBridge.decide(messages: messages, client: client, context: context)
        XCTAssertEqual(action.kind, "final")
        XCTAssertNil(action.toolName)
        XCTAssertNil(action.arguments)
    }

    func testWrongKindIsCorrectedOnceWithoutRelaxingValidation() async throws {
        let client = ScriptedAskLLMClient(decisions: [
            #"{"kind":"search","toolName":"search","query":"launch date","sourceID":"A","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"search","query":"launch date","sourceID":"A","start":0,"limit":0}"#,
        ])

        let action = try await AskModelBridge.decide(messages: messages, client: client, context: context)

        XCTAssertEqual(action.kind, "tool")
        XCTAssertEqual(action.toolName, "search")
        XCTAssertEqual(action.arguments?["sourceID"] as? String, "A")
        let requests = await client.recordedDecisionRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].messages[0].content.contains("previous action did not match"))
        XCTAssertFalse(requests[1].messages[0].content.contains(#""kind":"search""#))
    }

    func testWrongArgumentTypeIsCorrectedWithPromptOnlyProvider() async throws {
        let promptOnlyContext = LLMExecutionContext(
            providerConfig: .anthropic(apiKey: "test-only", model: "scripted"))
        let client = ScriptedAskLLMClient(decisions: [
            #"{"kind":"tool","toolName":"search","query":true,"sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":0,"limit":0}"#,
        ])

        let action = try await AskModelBridge.decide(
            messages: messages, client: client, context: promptOnlyContext)

        XCTAssertEqual(action.toolName, "list_sources")
        let requests = await client.recordedDecisionRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].options.responseFormat)
        XCTAssertNil(requests[1].options.responseFormat)
    }

    func testNativeSchemaRequiresSixPlainTypedFields() async throws {
        let client = ScriptedAskLLMClient(
            decision: #"{"kind":"final","toolName":"","query":"","sourceID":"","start":0,"limit":0}"#)
        _ = try await AskModelBridge.decide(messages: messages, client: client, context: context)
        let requests = await client.recordedDecisionRequests()
        guard case .jsonSchema(_, let schema) = requests[0].options.responseFormat else {
            return XCTFail("Expected native JSON schema")
        }
        XCTAssertEqual(schema.properties["kind"]?.enumValues, ["tool", "final"])
        XCTAssertEqual(
            schema.properties["toolName"]?.enumValues,
            ["", "list_sources", "search", "read", "get_summary"])

        XCTAssertFalse(requests[0].options.allowsLocalChunking)
        let encoded = try JSONEncoder().encode(schema)
        XCTAssertEqual(try JSONDecoder().decode(ChatJSONSchema.self, from: encoded), schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let properties = try XCTUnwrap(object["properties"] as? [String: [String: Any]])
        XCTAssertEqual(properties["kind"]?["enum"] as? [String], ["tool", "final"])
        XCTAssertEqual(
            properties["toolName"]?["enum"] as? [String],
            ["", "list_sources", "search", "read", "get_summary"])
        XCTAssertEqual(Set(schema.required), Set(["kind", "toolName", "query", "sourceID", "start", "limit"]))
        XCTAssertFalse(schema.additionalProperties)
        for key in ["query", "sourceID"] {
            XCTAssertEqual(properties[key]?["type"] as? String, "string")
        }
        for key in ["start", "limit"] {
            XCTAssertEqual(properties[key]?["type"] as? String, "integer")
        }
        XCTAssertEqual(Set(properties.keys), Set(["kind", "toolName", "query", "sourceID", "start", "limit"]))
    }

    func testMalformedAndUnknownActionsFailClosed() async throws {
        let invalid = [
            "not JSON",
            #"{"kind":"tool","toolName":"shell","query":"","sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"read","query":"","sourceID":"source","start":-1,"limit":5}"#,
            #"{"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":0,"limit":0,"unexpected":true}"#,
            #"{"kind":"final","toolName":"search","query":"","sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"read","query":"","sourceID":"A","start":0,"limit":13}"#,
            #"{"kind":"tool","toolName":"search","query":true,"sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"search","query":"","sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"search","query":"launch","sourceID":12,"start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"search","query":"launch","sourceID":"","start":1,"limit":0}"#,
            #"{"kind":"tool","toolName":"read","query":"","sourceID":"A","start":false,"limit":5}"#,
            #"{"kind":"tool","toolName":"read","query":"","sourceID":"A","start":0.5,"limit":5}"#,
            #"{"kind":"tool","toolName":"read","query":"","sourceID":"A","start":"0","limit":5}"#,
            #"{"kind":"tool","toolName":"read","query":"","sourceID":"A","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"read","query":"","sourceID":"A","start":0,"limit":true}"#,
            #"{"kind":"tool","toolName":"get_summary","query":"launch","sourceID":"A","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"list_sources","query":"launch","sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"final","toolName":"","query":"","sourceID":"A","start":0,"limit":0}"#,
            #"{"toolName":"list_sources","query":"","sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":0,"limit":0,"argumentsJSON":"{}"}"#,
        ]
        for decision in invalid {
            let client = ScriptedAskLLMClient(decision: decision)
            do {
                _ = try await AskModelBridge.decide(messages: messages, client: client, context: context)
                XCTFail("Accepted invalid decision")
            } catch AskAgentError.invalidModelAction {
                let requests = await client.recordedDecisionRequests()
                XCTAssertEqual(requests.count, 2)
            }
        }
    }

    func testMissingFieldsAndInvalidUnusedNumbersFailClosed() async throws {
        let invalid = [
            #"{"kind":"tool","toolName":"list_sources"}"#,
            #"{"kind":"final","toolName":"","query":"","sourceID":"","start":0}"#,
            #"{"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":false,"limit":0}"#,
            #"{"kind":"final","toolName":"","query":"","sourceID":"","start":0,"limit":false}"#,
            #"{"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":0.1,"limit":0}"#,
            #"{"kind":"final","toolName":"","query":"","sourceID":"","start":0,"limit":0.1}"#,
            #"{"kind":"final","toolName":"","query":"","sourceID":"","start":0,"limit":1}"#,
            #"{"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":-1,"limit":0}"#,
        ]
        for decision in invalid {
            let client = ScriptedAskLLMClient(decision: decision)
            do {
                _ = try await AskModelBridge.decide(messages: messages, client: client, context: context)
                XCTFail("Accepted invalid required scalar fields")
            } catch AskAgentError.invalidModelAction {
                let requests = await client.recordedDecisionRequests()
                XCTAssertEqual(requests.count, 2)
            }
        }
    }

    func testExplicitNullArgumentsFailClosed() async throws {
        let invalid = [
            #"{"kind":"tool","toolName":"list_sources","query":null,"sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"search","query":null,"sourceID":"","start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"search","query":"launch","sourceID":null,"start":0,"limit":0}"#,
            #"{"kind":"tool","toolName":"search","query":"launch","sourceID":"","start":0,"limit":null}"#,
            #"{"kind":"tool","toolName":"read","query":"","sourceID":"A","start":null,"limit":5}"#,
            #"{"kind":"final","toolName":"","query":"","sourceID":"","start":0,"limit":null}"#,
        ]
        for decision in invalid {
            let client = ScriptedAskLLMClient(decision: decision)
            do {
                _ = try await AskModelBridge.decide(messages: messages, client: client, context: context)
                XCTFail("Accepted explicit null argument")
            } catch AskAgentError.invalidModelAction {
                let requests = await client.recordedDecisionRequests()
                XCTAssertEqual(requests.count, 2)
            }
        }
    }

    func testInvalidJSONParserErrorIsSanitizedAndRetryIsBounded() async throws {
        let client = ScriptedAskLLMClient(decision: "not JSON PRIVATE_SENTINEL")
        do {
            _ = try await AskModelBridge.decide(messages: messages, client: client, context: context)
            XCTFail("Accepted invalid model response")
        } catch AskAgentError.invalidModelAction {
            let requests = await client.recordedDecisionRequests()
            XCTAssertEqual(requests.count, 2)
            XCTAssertFalse(requests[1].messages[0].content.contains("PRIVATE_SENTINEL"))
        }
    }

    func testCancellationBeforeRetryIsPropagated() async throws {
        let client = ScriptedAskLLMClient(decision: "not JSON", cancelOnCall: 1)
        let deciding = Task { try await AskModelBridge.decide(messages: messages, client: client, context: context) }
        do {
            _ = try await deciding.value
            XCTFail("Accepted cancelled model request")
        } catch is CancellationError {
            let requests = await client.recordedDecisionRequests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testTruncatedDecisionFailsWithoutRetry() async throws {
        let client = ScriptedAskLLMClient(
            decision:
                #"{"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":0,"limit":0}"#,
            finishReason: "length")
        do {
            _ = try await AskModelBridge.decide(messages: messages, client: client, context: context)
            XCTFail("Accepted truncated model response")
        } catch AskAgentError.budgetExceeded {
            let requests = await client.recordedDecisionRequests()
            XCTAssertEqual(requests.count, 1)
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

    func testAppleIntelligenceFinalAnswerUsesSupportedOutputBudget() async throws {
        let config = LLMProviderConfig.appleIntelligence()
        let client = ScriptedAskLLMClient(
            decision: "", finalChunks: ["Supported answer."], stopReason: "stop",
            checkOptions: { options in
                do {
                    try options.validateInferenceSettings(for: config)
                } catch {
                    XCTFail("Apple Intelligence rejected the final-answer options: \(error)")
                }
                XCTAssertEqual(
                    options.maxTokens,
                    LLMService.maximumOutputTokensLeavingInputRoom(in: LLMService.appleIntelligenceContextBudget)
                )
            }
        )
        try await AskModelBridge.streamFinal(
            messages: messages, client: client, context: LLMExecutionContext(providerConfig: config)
        ) { _ in }
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
    private let script: AskDecisionScript
    let finalChunks: [String]
    let stopReason: String?
    let textAfterTerminal: String?
    let cancelOnCall: Int?
    let checkOptions: (@Sendable (ChatCompletionOptions) -> Void)?

    init(
        decision: String, finalChunks: [String] = [], stopReason: String? = nil,
        textAfterTerminal: String? = nil, finishReason: String? = nil,
        cancelOnCall: Int? = nil,
        checkOptions: (@Sendable (ChatCompletionOptions) -> Void)? = nil
    ) {
        self.script = AskDecisionScript(
            responses: [ChatCompletionResponse(content: decision, finishReason: finishReason, model: "scripted")])
        self.finalChunks = finalChunks
        self.stopReason = stopReason
        self.textAfterTerminal = textAfterTerminal
        self.cancelOnCall = cancelOnCall
        self.checkOptions = checkOptions
    }

    init(decisions: [String]) {
        self.script = AskDecisionScript(
            responses: decisions.map { ChatCompletionResponse(content: $0, model: "scripted") })
        self.finalChunks = []
        self.stopReason = nil
        self.textAfterTerminal = nil
        self.cancelOnCall = nil
        self.checkOptions = nil
    }

    func chatCompletion(
        messages: [ChatMessage], context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        let (response, call) = await script.next(messages: messages, options: options)
        if call == cancelOnCall {
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return response
    }

    func recordedDecisionRequests() async -> [AskDecisionScript.Request] {
        await script.requests
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
        checkOptions?(options)
        return AsyncThrowingStream { continuation in
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

private actor AskDecisionScript {
    struct Request {
        let messages: [ChatMessage]
        let options: ChatCompletionOptions
    }

    let responses: [ChatCompletionResponse]
    private(set) var requests: [Request] = []

    init(responses: [ChatCompletionResponse]) { self.responses = responses }

    func next(messages: [ChatMessage], options: ChatCompletionOptions) -> (ChatCompletionResponse, Int) {
        requests.append(Request(messages: messages, options: options))
        let call = requests.count
        return (responses[min(call - 1, responses.count - 1)], call)
    }
}

private actor AskTextCollector {
    private(set) var text = ""
    func append(_ chunk: String) { text += chunk }
}
