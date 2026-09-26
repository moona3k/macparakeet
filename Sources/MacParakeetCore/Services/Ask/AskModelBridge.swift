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
        Use an empty string for every unused string argument and 0 for every unused integer argument.
        Do not use null or encode arguments as a JSON string.
        Tool arguments: list_sources uses no arguments; search requires query and optionally sourceID and limit 1...12;
        read requires sourceID, start >=0, and limit 1...12; get_summary requires sourceID.
        For final, toolName, query, and sourceID are empty strings; start and limit are 0.
        Search and read evidence before making claims.
        Search matches passages containing ALL query words; it is not semantic search.
        Start with one distinctive topic word across all selected sources (set sourceID to an empty string).
        If no matches, try fewer words or a different word before concluding evidence is absent.
        For changes over time, inspect relevant hits from earlier and later recordings.
        Reading start 0 only covers the opening passages, not the entire recording.
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
        for attempt in 0..<2 {
            let prompt = attempt == 0 ? decisionPrompt : decisionPrompt + "\n" + correctionPrompt
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
            if let action = parseAction(response.content) { return action }
        }
        throw AskAgentError.invalidModelAction
    }

    private static func parseAction(_ content: String) -> Action? {
        guard content.utf8.count <= 8_192,
            let data = content.data(using: .utf8),
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            Set(raw.keys) == Set(["kind", "toolName", "query", "sourceID", "start", "limit"]),
            let kind = raw["kind"] as? String,
            let toolName = raw["toolName"] as? String,
            let query = raw["query"] as? String,
            let sourceID = raw["sourceID"] as? String
        else { return nil }
        func integer(_ key: String) -> Int? {
            guard let number = raw[key] as? NSNumber,
                CFGetTypeID(number) != CFBooleanGetTypeID()
            else { return nil }
            return Int(exactly: number.doubleValue)
        }
        guard let start = integer("start"), let limit = integer("limit") else { return nil }
        var args: [String: Any] = [:]
        if !query.isEmpty { args["query"] = query }
        if !sourceID.isEmpty { args["sourceID"] = sourceID }
        if toolName == "read" || start != 0 { args["start"] = start }
        if limit != 0 { args["limit"] = limit }
        guard let argsData = try? JSONSerialization.data(withJSONObject: args), argsData.count <= 4_096 else {
            return nil
        }
        if kind == "final" {
            guard toolName.isEmpty, args.isEmpty else { return nil }
            return Action(kind: kind, toolName: nil, arguments: nil)
        }
        guard kind == "tool", validate(toolName: toolName, args: args) else { return nil }
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
        func string(_ name: String) -> Bool {
            guard let value = args[name] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.count <= 1_024
        }
        switch toolName {
        case "list_sources": return args.isEmpty
        case "search":
            return Set(args.keys).isSubset(of: ["query", "sourceID", "limit"]) && string("query")
                && (args["sourceID"] == nil || string("sourceID"))
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
