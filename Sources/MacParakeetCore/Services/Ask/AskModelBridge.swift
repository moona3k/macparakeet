import Foundation
import CoreFoundation

/// Adapts text-only configured clients to Pi's one-action-per-turn stream.
/// Every model call stays in Swift, so the helper never sees provider credentials.
enum AskModelBridge {
    struct Action {
        let kind: String
        let toolName: String?
        let arguments: [String: Any]?
    }

    private static let completedStopReasons: Set<String> = [
        "stop", "end_turn", "stop_sequence", "eos", "complete", "completed",
    ]

    private static let decisionPrompt = #"""
        Choose exactly one next action for investigating the selected transcripts.
        Return one JSON object with exactly six keys: kind, toolName, query, sourceID, start, limit.
        kind is "tool" or "final". toolName is list_sources, search, read, get_summary, or empty for final.
        query and sourceID must be strings; start and limit must be integers.
        Prefer an empty string for unused string fields and 0 for unused integer fields.
        Only the selected tool's fields become arguments; other typed envelope fields are ignored.
        Do not use null or encode arguments as a JSON string.
        Tool arguments: list_sources uses no arguments; search requires a nonblank query of at most 500 characters and optionally sourceID, start 0...1000000 (result offset), and limit 1...12;
        read requires sourceID, start >=0, and limit 1...12; get_summary requires sourceID.
        For final, toolName, query, and sourceID are empty strings; start and limit are 0.
        Search and read evidence before making claims.
        Search ranks passages matching ANY query term; it is lexical, not semantic search.
        Start with distinctive topic keywords across all selected sources (set sourceID to an empty string).
        If no matches, try alternate vocabulary before concluding evidence is absent.
        For changes over time, inspect relevant hits from earlier and later recordings.
        Reading start 0 only covers the opening passages, not the entire recording.
        Search and read return nextStart when more results remain. Use nextStart to continue.
        For search, keep query and sourceID unchanged when continuing; start is a result offset, not a passage index.
        One tool call per turn. Do not include markdown or any other text.

        Examples (each is one complete response):
        {"kind":"tool","toolName":"list_sources","query":"","sourceID":"","start":0,"limit":0}
        {"kind":"tool","toolName":"search","query":"budget","sourceID":"","start":0,"limit":8}
        {"kind":"tool","toolName":"read","query":"","sourceID":"SOURCE_ID","start":0,"limit":5}
        {"kind":"tool","toolName":"get_summary","query":"","sourceID":"SOURCE_ID","start":0,"limit":0}
        {"kind":"final","toolName":"","query":"","sourceID":"","start":0,"limit":0}
        """#
    private static let correctionPrompt = """
        The previous action did not match the required format or allowed arguments.
        Choose the next action again for the same question. Return exactly one complete
        JSON object with all six keys following the examples above. Use empty strings and 0
        for unused arguments. Use only the listed kind and toolName values.
        """
    private static let schema = ChatJSONSchema(
        type: "object",
        properties: [
            "kind": ChatJSONSchemaProperty(type: "string", enumValues: ["tool", "final"]),
            "toolName": ChatJSONSchemaProperty(
                type: "string", enumValues: ["", "list_sources", "search", "read", "get_summary"]),
            "query": ChatJSONSchemaProperty(type: "string"),
            "sourceID": ChatJSONSchemaProperty(type: "string"),
            "start": ChatJSONSchemaProperty(type: "integer"),
            "limit": ChatJSONSchemaProperty(type: "integer"),
        ],
        required: ["kind", "toolName", "query", "sourceID", "start", "limit"],
        additionalProperties: false
    )

    static func decide(
        messages: [ChatMessage], client: any LLMClientProtocol, context: LLMExecutionContext
    ) async throws -> Action {
        try Task.checkCancellation()
        let format: ChatResponseFormat? =
            client.structuredOutputCapability(context: context) == .nativeJSONSchema
            ? .jsonSchema(name: "ask_action", schema: schema) : nil
        var correction: String?
        for _ in 0..<2 {
            let prompt = decisionPrompt + (correction.map { "\n" + correctionPrompt + "\n" + $0 } ?? "")
            let response = try await client.chatCompletion(
                messages: [ChatMessage(role: .system, content: prompt)] + messages,
                context: context,
                options: ChatCompletionOptions(
                    temperature: 0, maxTokens: 400, responseFormat: format, allowsLocalChunking: false)
            )
            try Task.checkCancellation()
            try requireLocalCompletionReason(response.finishReason, context: context)
            if let reason = response.finishReason?.lowercased(),
                !completedStopReasons.contains(reason)
            {
                throw AskAgentError.budgetExceeded("Ask action ended before a complete model response")
            }
            do {
                return try parseAction(response.content)
            } catch let failure as ActionValidationFailure {
                correction = failure.reason
            }
        }
        throw AskAgentError.invalidModelAction
    }

    private struct ActionValidationFailure: Error {
        // Only constant, application-authored messages may be used as retry feedback.
        let reason: String
    }

    private static func parseAction(_ content: String) throws -> Action {
        guard content.utf8.count <= 8_192,
            let data = content.data(using: .utf8),
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            Set(raw.keys) == Set(["kind", "toolName", "query", "sourceID", "start", "limit"]),
            let kind = raw["kind"] as? String,
            let toolName = raw["toolName"] as? String,
            let query = raw["query"] as? String,
            let sourceID = raw["sourceID"] as? String
        else {
            throw ActionValidationFailure(
                reason: "Return exactly the six required fields; kind, toolName, query, and sourceID must be strings.")
        }
        func integer(_ key: String) -> Int? {
            guard let number = raw[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return nil }
            return Int(exactly: number.doubleValue)
        }
        guard let start = integer("start"), let limit = integer("limit") else {
            throw ActionValidationFailure(
                reason: "start and limit must be integers, not strings, booleans, fractions, or null.")
        }
        if kind == "final" {
            guard toolName.isEmpty, query.isEmpty, sourceID.isEmpty, start == 0, limit == 0 else {
                throw ActionValidationFailure(
                    reason: "For final, toolName, query, and sourceID must be empty strings; start and limit must be 0."
                )
            }
            return Action(kind: kind, toolName: nil, arguments: nil)
        }
        guard kind == "tool" else {
            throw ActionValidationFailure(reason: "kind must be tool or final, not a tool name.")
        }
        // The wire envelope is a superset of all tool schemas. Project it onto
        // the selected tool before validating: an unused query on read is not
        // a read argument, even when a model fills it with a topic word.
        var args: [String: Any] = [:]
        let requirements: String
        switch toolName {
        case "list_sources":
            requirements = "list_sources takes no arguments."
        case "search":
            args["query"] = query
            if start != 0 { args["start"] = start }
            if !sourceID.isEmpty { args["sourceID"] = sourceID }
            if limit != 0 { args["limit"] = limit }
            requirements =
                "search needs a nonblank query of at most 500 characters, optional nonblank sourceID, start 0...1000000, and limit 1...12 (or 0 for the default)."
        case "read":
            args = ["sourceID": sourceID, "start": start, "limit": limit]
            requirements =
                "read needs a nonblank sourceID from the selected recordings, start 0...1000000, and limit 1...12."
        case "get_summary":
            args["sourceID"] = sourceID
            requirements = "get_summary needs a nonblank sourceID from the selected recordings."
        default:
            throw ActionValidationFailure(
                reason: "toolName must be list_sources, search, read, or get_summary when kind is tool.")
        }
        guard validate(toolName: toolName, args: args) else {
            throw ActionValidationFailure(reason: requirements + " sourceID must be at most 1024 characters.")
        }
        guard let argsData = try? JSONSerialization.data(withJSONObject: args), argsData.count <= 4_096 else {
            throw ActionValidationFailure(
                reason: "Tool arguments must fit within 4096 UTF-8 JSON bytes; shorten text arguments.")
        }
        return Action(kind: kind, toolName: toolName, arguments: args)
    }

    static func streamFinal(
        messages: [ChatMessage], client: any LLMClientProtocol,
        context: LLMExecutionContext, onText: @escaping @Sendable (String) async throws -> Void
    ) async throws {
        let prompt = ChatMessage(
            role: .system,
            content:
                "Answer the question using only the selected transcript evidence in the conversation. Cite real passage handles from tool results as [E1], [E2], etc. State uncertainty and unexamined coverage. Do not invent timestamps or imply an unexamined source was checked."
        )
        let maxTokens =
            context.providerConfig.id == .appleIntelligence
            ? min(4_096, LLMService.maximumOutputTokensLeavingInputRoom(in: LLMService.appleIntelligenceContextBudget))
            : 4_096
        let stream = client.chatCompletionDetailedStream(
            messages: [prompt] + messages, context: context,
            options: ChatCompletionOptions(temperature: 0.3, maxTokens: maxTokens, allowsLocalChunking: false)
        )
        var sawTerminal = false
        var characterCount = 0
        for try await event in stream {
            try Task.checkCancellation()
            guard !sawTerminal else {
                throw AskAgentError.protocolViolation("Model emitted content after completion")
            }
            switch event {
            case .text(let chunk):
                characterCount += chunk.count
                guard characterCount <= 80_000 else { throw AskAgentError.budgetExceeded("Ask answer exceeds limit") }
                try await onText(chunk)
            case .completed(let terminal):
                guard !sawTerminal else { throw AskAgentError.protocolViolation("Duplicate model terminal event") }
                sawTerminal = true
                try requireLocalCompletionReason(terminal.stopReason, context: context)
                if let reason = terminal.stopReason?.lowercased(),
                    !completedStopReasons.contains(reason)
                {
                    throw AskAgentError.budgetExceeded("Ask answer ended before a complete model response")
                }
            }
        }
        guard sawTerminal, characterCount > 0 else {
            throw AskAgentError.protocolViolation("Model answer ended without a complete response")
        }
    }

    private static func requireLocalCompletionReason(_ reason: String?, context: LLMExecutionContext) throws {
        // In-process MLX currently exposes text chunks without EOS/token-limit
        // evidence. Stream exhaustion and chunk counts cannot prove completion.
        if context.providerConfig.id == .inProcessLocal,
            reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        {
            throw AskAgentError.unverifiedLocalCompletion
        }
    }

    private static func validate(toolName: String, args: [String: Any]) -> Bool {
        func int(_ name: String, min: Int, max: Int) -> Bool {
            guard let number = args[name] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return false }
            let value = number.intValue
            return Double(value) == number.doubleValue && value >= min && value <= max
        }
        func string(_ name: String, maxLength: Int = 1_024) -> Bool {
            guard let value = args[name] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= maxLength
        }
        switch toolName {
        case "list_sources": return args.isEmpty
        case "search":
            return Set(args.keys).isSubset(of: ["query", "sourceID", "start", "limit"])
                && string("query", maxLength: 500)
                && (args["sourceID"] == nil || string("sourceID"))
                && (args["start"] == nil || int("start", min: 0, max: 1_000_000))
                && (args["limit"] == nil || int("limit", min: 1, max: 12))
        case "read":
            return Set(args.keys) == Set(["sourceID", "start", "limit"])
                && string("sourceID") && int("start", min: 0, max: 1_000_000)
                && int("limit", min: 1, max: 12)
        case "get_summary": return Set(args.keys) == Set(["sourceID"]) && string("sourceID")
        default: return false
        }
    }
}
