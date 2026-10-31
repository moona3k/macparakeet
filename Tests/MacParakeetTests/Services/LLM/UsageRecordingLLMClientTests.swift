import XCTest

@testable import MacParakeetCore

private struct UsageRecordingClientStub: LLMClientProtocol {
    let usage: TokenUsage?

    func chatCompletion(
        messages: [ChatMessage], context: LLMExecutionContext, options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(content: "done", model: "reported-model", usage: usage)
    }

    func chatCompletionStream(
        messages: [ChatMessage], context: LLMExecutionContext, options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("done")
            continuation.finish()
        }
    }

    func testConnection(context: LLMExecutionContext) async throws {}
    func listModels(context: LLMExecutionContext) async throws -> [String] { [] }
}

final class UsageRecordingLLMClientTests: XCTestCase {
    private let messages = [
        ChatMessage(role: .system, content: "abcd"),
        ChatMessage(role: .user, content: "visible", modelPromptOverride: String(repeating: "x", count: 40)),
    ]

    func testAllCompletionShapesEstimateTheActualModelPrompt() async throws {
        for shape in 0..<3 {
            let manager = try DatabaseManager()
            let repo = UsageEventRepository(dbQueue: manager.dbQueue)
            let client = UsageRecordingLLMClient(
                base: UsageRecordingClientStub(usage: nil), ledger: UsageLedger(repository: repo))
            let context = LLMExecutionContext(providerConfig: .inProcessLocal(model: "configured-model"))
            switch shape {
            case 0:
                _ = try await client.chatCompletion(messages: messages, context: context, options: .default)
            case 1:
                for try await _ in client.chatCompletionStream(messages: messages, context: context, options: .default)
                {}
            default:
                for try await _ in client.chatCompletionDetailedStream(
                    messages: messages, context: context, options: .default)
                {}
            }
            let row = try XCTUnwrap(repo.summary(since: nil).first)
            XCTAssertEqual(row.promptTokens, 11, "Estimate 44 model characters, not 11 display characters")
            XCTAssertEqual(row.completionTokens, 1)
            XCTAssertTrue(row.tokensEstimated)
            XCTAssertTrue(row.isLocal)
            XCTAssertEqual(row.requests, 1)
        }
    }

    func testProviderReportedTokensRemainAuthoritative() async throws {
        let manager = try DatabaseManager()
        let repo = UsageEventRepository(dbQueue: manager.dbQueue)
        let client = UsageRecordingLLMClient(
            base: UsageRecordingClientStub(usage: TokenUsage(promptTokens: 123, completionTokens: 45)),
            ledger: UsageLedger(repository: repo))
        _ = try await client.chatCompletion(
            messages: messages,
            context: LLMExecutionContext(providerConfig: .inProcessLocal(model: "configured-model")),
            options: .default)
        let row = try XCTUnwrap(repo.summary(since: nil).first)
        XCTAssertEqual(row.promptTokens, 123)
        XCTAssertEqual(row.completionTokens, 45)
        XCTAssertFalse(row.tokensEstimated)
        XCTAssertEqual(row.model, "reported-model")
    }
}
