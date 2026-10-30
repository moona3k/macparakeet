import Observation
import XCTest

@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptChatPublicationTests: XCTestCase {
    @MainActor
    private final class Changes {
        var count = 0
        func observe(_ model: TranscriptChatViewModel) {
            withObservationTracking {
                _ = model.messages
            } onChange: { [weak self, weak model] in
                MainActor.assumeIsolated {
                    guard let self, let model else { return }
                    self.count += 1
                    self.observe(model)
                }
            }
        }
    }

    func testFailedBurstDiscardsUnpublishedTail() async throws {
        try await checkDiscardedBurst(error: NSError(domain: "SyntheticProvider", code: 1), expectsError: true)
    }

    func testCancelledBurstDiscardsUnpublishedTail() async throws {
        try await checkDiscardedBurst(error: CancellationError(), expectsError: false)
    }

    private func checkDiscardedBurst(error: Error, expectsError: Bool) async throws {
        let model = TranscriptChatViewModel()
        let service = MockLLMService()
        let repository = MockChatConversationRepository()
        service.chatStreamOverride = AsyncThrowingStream { continuation in
            for index in 0..<1_000 { continuation.yield("\(index) ") }
            continuation.finish(throwing: error)
        }
        model.configure(llmService: service, transcriptText: "Transcript", conversationRepo: repository)
        model.loadTranscript("Transcript", transcriptionId: UUID())
        model.inputText = "Summarize"
        model.sendMessage()
        let completed = expectation(description: "Stream terminated")
        withObservationTracking {
            _ = model.isStreaming
        } onChange: {
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.messages.count, 1)
        XCTAssertEqual(model.messages.first?.content, "Summarize")
        XCTAssertEqual(model.errorMessage != nil, expectsError)
        XCTAssertFalse(
            repository.updateMessagesCalls.contains { call in
                call.messages?.contains(where: { $0.role == .assistant }) == true
            })
    }

    func testBurstPublishesBoundedUpdatesAndSavesEveryToken() async throws {
        let model = TranscriptChatViewModel()
        let service = MockLLMService()
        let repository = MockChatConversationRepository()
        let tokens = (0..<1_000).map { "\($0) " }
        service.streamTokens = tokens
        model.configure(llmService: service, transcriptText: "Transcript", conversationRepo: repository)
        model.loadTranscript("Transcript", transcriptionId: UUID())
        model.inputText = "Summarize"
        model.sendMessage()
        let changes = Changes()
        changes.observe(model)
        let completed = expectation(description: "Stream completed")
        withObservationTracking {
            _ = model.isStreaming
        } onChange: {
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 5)
        XCTAssertFalse(model.isStreaming)
        XCTAssertEqual(model.messages.last?.content, tokens.joined())
        XCTAssertEqual(repository.updateMessagesCalls.last?.messages?.last?.content, tokens.joined())
        print("Chat burst: 1000 tokens, \(changes.count) message-array publications")
        XCTAssertGreaterThan(changes.count, 0)
        XCTAssertLessThan(changes.count, 100, "A token burst must not invalidate the message list once per token")
    }
}
