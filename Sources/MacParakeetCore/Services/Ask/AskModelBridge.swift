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

    private static let decisionPrompt = """
        Choose exactly one next action for investigating the selected transcripts.
        Return one JSON object with keys kind, toolName, argumentsJSON. For a tool call,
        kind is "tool", toolName is list_sources, search, read, or get_summary,
        and argumentsJSON is a JSON object encoded as a string. For the final answer,
        kind is "final", toolName is empty, and argumentsJSON is "{}".
        Tool arguments: list_sources {}; search {query:string, sourceID?:string, limit?:integer 1...12};
        read {sourceID:string, start:integer >=0, limit:integer 1...12};
        get_summary {sourceID:string}. Search and read evidence before making claims.
        One tool call per turn. Do not include markdown or any other text.
        """
    private static let schema = ChatJSONSchema(
        type: "object",
        properties: [
            "kind": ChatJSONSchemaProperty(type: "string"),
            "toolName": ChatJSONSchemaProperty(type: "string"),
            "argumentsJSON": ChatJSONSchemaProperty(type: "string"),
        ],
        required: ["kind", "toolName", "argumentsJSON"],
        additionalProperties: false
    )

    static func decide(
        messages: [ChatMessage], client: any LLMClientProtocol, context: LLMExecutionContext
    ) async throws -> Action {
        try Task.checkCancellation()
        let format: ChatResponseFormat? =
            client.structuredOutputCapability(context: context) == .nativeJSONSchema
            ? .jsonSchema(name: "ask_action", schema: schema) : nil
        let response = try await client.chatCompletion(
            messages: [ChatMessage(role: .system, content: decisionPrompt)] + messages,
            context: context,
            options: ChatCompletionOptions(temperature: 0, maxTokens: 400, responseFormat: format)
        )
        try Task.checkCancellation()
        guard response.content.utf8.count <= 8_192,
            let data = response.content.data(using: .utf8),
            let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            Set(raw.keys) == Set(["kind", "toolName", "argumentsJSON"]),
            let kind = raw["kind"] as? String,
            let toolName = raw["toolName"] as? String,
            let argumentsJSON = raw["argumentsJSON"] as? String,
            argumentsJSON.utf8.count <= 4_096,
            let argsData = argumentsJSON.data(using: .utf8),
            let args = try JSONSerialization.jsonObject(with: argsData) as? [String: Any]
        else { throw AskAgentError.protocolViolation("Model returned an invalid Ask action") }
        if kind == "final" {
            guard toolName.isEmpty, args.isEmpty else {
                throw AskAgentError.protocolViolation("Invalid final action")
            }
            return Action(kind: kind, toolName: nil, arguments: nil)
        }
        guard kind == "tool", validate(toolName: toolName, args: args) else {
            throw AskAgentError.protocolViolation("Model requested an invalid Ask tool")
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
        let stream = client.chatCompletionDetailedStream(
            messages: [prompt] + messages, context: context,
            options: ChatCompletionOptions(temperature: 0.3, maxTokens: 4_096)
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
                if let reason = terminal.stopReason?.lowercased(),
                    !["stop", "end_turn", "stop_sequence", "eos", "complete", "completed"].contains(reason)
                {
                    throw AskAgentError.budgetExceeded("Ask answer ended before a complete model response")
                }
            }
        }
        guard sawTerminal, characterCount > 0 else {
            throw AskAgentError.protocolViolation("Model answer ended without a complete response")
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
