import XCTest
@testable import MacParakeetCore

final class AskWorkspaceServiceTests: XCTestCase {
    func testAnswerPersistsScopedCitationsAndSourceChangeStartsFreshContext() async throws {
        let fixture = try Fixture()
        let first = try fixture.source("First decision", "Launch in June.")
        let second = try fixture.source("Second decision", "Launch in July.")
        let agent = ScriptedAskAgent { _, tool, event in
            let sources = try await tool("list_sources", "{}")
            XCTAssertTrue(sources.contains(first.id.uuidString))
            XCTAssertFalse(sources.contains(second.id.uuidString))
            let evidence = try await tool("search", #"{"query":"June"}"#)
            XCTAssertTrue(evidence.contains("[E1]"))
            await event(.text("The original date was June [E1]. June was the plan [E1]."))
            return "The original date was June [E1]. June was the plan [E1]."
        }
        let service = fixture.service(agent)
        let created = try await service.create(sourceIDs: [first.id])
        let answered = try await service.send(
            id: created.id, question: "What was decided?", expectedRevision: created.revision,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(answered.messages.last?.status, .complete)
        XCTAssertEqual(answered.messages.last?.content, "The original date was June [1]. June was the plan [1].")
        XCTAssertEqual(answered.messages.last?.citations.count, 1)
        let reference = try XCTUnwrap(answered.messages.last?.citations.first)
        let resolved = try await service.evidence(reference)
        XCTAssertEqual(resolved.status, .available)
        XCTAssertEqual(resolved.passage?.text, "Launch in June.")
        let changed = try await service.selectSources(
            id: created.id, sourceIDs: [second.id], expectedRevision: answered.revision
        )
        XCTAssertEqual(changed.sections.count, 2)
        XCTAssertEqual(changed.messages, answered.messages)

        let nextAgent = ScriptedAskAgent { request, tool, _ in
            XCTAssertFalse(request.messages.contains { $0.content.contains("original date") })
            XCTAssertFalse(request.messages.contains { $0.content == "What was decided?" })
            let result = try await tool("search", #"{"query":"July"}"#)
            XCTAssertTrue(result.contains("July"))
            return "July [E1]."
        }
        let nextService = fixture.service(nextAgent)
        let next = try await nextService.send(
            id: changed.id, question: "And now?", expectedRevision: changed.revision,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(next.messages.last?.citations.first?.sourceID, second.id)
    }

    func testRemoteProviderRequiresExplicitMatchingApprovalBeforeAnyRun() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let agent = ScriptedAskAgent { _, _, _ in
            XCTFail("Must not run"); return ""
        }
        let service = fixture.service(agent, config: .openai(apiKey: "test-key", model: "fixture"))
        let chat = try await service.create(sourceIDs: [source.id])
        let disclosure = try await service.provider()
        XCTAssertTrue(disclosure.requiresRemoteConsent)
        XCTAssertFalse(disclosure.id.contains("test-key"))
        do {
            _ = try await service.send(
                id: chat.id, question: "What changed?", expectedRevision: chat.revision,
                approvedProviderID: "different-provider", onEvent: { _ in }
            )
            XCTFail("Expected consent requirement")
        } catch AskWorkspaceError.remotePermissionRequired {}
        let saved = try await service.conversation(id: chat.id)
        XCTAssertEqual(saved?.messages.count, 0)
    }

    func testCommandLineAgentProviderIsRejectedBeforeSourceDisclosure() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let agent = ScriptedAskAgent { _, _, _ in
            XCTFail("Must not run"); return ""
        }
        let service = fixture.service(agent, config: .localCLI())
        let chat = try await service.create(sourceIDs: [source.id])
        do {
            _ = try await service.send(
                id: chat.id, question: "When?", expectedRevision: 0,
                approvedProviderID: nil, onEvent: { _ in }
            )
            XCTFail("CLI provider must not execute")
        } catch AskWorkspaceError.unsupportedProvider {}
        let saved = try await service.conversation(id: chat.id)
        XCTAssertTrue(saved?.messages.isEmpty == true)
    }

    func testSourceEditDuringRunPreservesPartialAsFailedAndOldEvidenceBecomesStale() async throws {
        let fixture = try Fixture()
        let original = try fixture.source("Planning", "Launch in June.")
        let repo = fixture.transcriptions
        let agent = ScriptedAskAgent { _, tool, event in
            _ = try await tool("search", #"{"query":"June"}"#)
            await event(.text("June [E1]."))
            var edited = original
            edited.rawTranscript = "Launch in July."
            try repo.save(edited)
            return "June [E1]."
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [original.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: chat.revision,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(result.messages.last?.status, .failed)
        XCTAssertTrue(result.messages.last?.failureReason?.contains("changed") == true)
        XCTAssertEqual(result.messages.last?.content, "June [E1].")
        XCTAssertTrue(result.messages.last?.citations.isEmpty == true)
    }

    func testUnknownCitationFailsInsteadOfPersistingInventedEvidence() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let agent = ScriptedAskAgent { _, _, event in
            await event(.text("Invented [E99]."))
            return "Invented [E99]."
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(result.messages.last?.status, .failed)
        XCTAssertTrue(result.messages.last?.citations.isEmpty == true)
    }

    func testStopSettlesPartialAndReleasesConversationLease() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let started = expectation(description: "stream started")
        let agent = ScriptedAskAgent { _, _, event in
            await event(.text("Partial answer"))
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return "Late answer"
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let task = Task {
            try await service.send(
                id: chat.id, question: "When?", expectedRevision: 0,
                approvedProviderID: nil, onEvent: { _ in }
            )
        }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        let stopped = try await task.value
        XCTAssertEqual(stopped.messages.last?.status, .cancelled)
        XCTAssertEqual(stopped.messages.last?.content, "Partial answer")
        let draft = try await service.saveDraft(id: chat.id, draft: "Next question", expectedRevision: stopped.revision)
        XCTAssertEqual(draft.draft, "Next question")
    }

    func testBareNumberCitationCannotImpersonateValidatedSource() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let agent = ScriptedAskAgent { _, _, event in
            await event(.text("Launch in July [1]."))
            return "Launch in July [1]."
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(result.messages.last?.status, .failed)
        XCTAssertTrue(result.messages.last?.citations.isEmpty == true)
    }

    func testCitedAnswerWithBracketedProseAndMarkdownLinkSucceeds() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let agent = ScriptedAskAgent { _, tool, event in
            _ = try await tool("search", #"{"query":"June"}"#)
            let text =
                "Launch slipped to June [E1] (see [early estimate, unconfirmed])."
                + " Details: [explore the results](https://example.com)."
            await event(.text(text))
            return text
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(result.messages.last?.status, .complete)
        XCTAssertEqual(result.messages.last?.citations.count, 1)
        XCTAssertTrue(result.messages.last?.content.contains("[early estimate, unconfirmed]") == true)
        XCTAssertTrue(result.messages.last?.content.contains("[explore the results]") == true)
    }

    func testMalformedNumericCitationMarkerStillFails() async throws {
        let fixture = try Fixture()
        for malformed in ["[e1]", "[E 1]", "[E+1]", "[E-1]"] {
            let source = try fixture.source("Planning", "Launch in June.")
            let agent = ScriptedAskAgent { _, tool, event in
                _ = try await tool("search", #"{"query":"June"}"#)
                let text = "Launch in June \(malformed)."
                await event(.text(text))
                return text
            }
            let service = fixture.service(agent)
            let chat = try await service.create(sourceIDs: [source.id])
            let result = try await service.send(
                id: chat.id, question: "When?", expectedRevision: 0,
                approvedProviderID: nil, onEvent: { _ in }
            )
            XCTAssertEqual(result.messages.last?.status, .failed, "Expected failure for marker \(malformed)")
            XCTAssertTrue(
                result.messages.last?.citations.isEmpty == true, "Expected no citations for marker \(malformed)")
        }
    }

    func testUncitedResponseIsExplicitlyUnverified() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let agent = ScriptedAskAgent { _, _, _ in "There is not enough evidence to answer." }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "Who approved it?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(result.messages.last?.status, .incomplete)
        XCTAssertTrue(result.messages.last?.failureReason?.contains("unverified") == true)
    }

    func testDeletedConversationCannotBeRecreatedByLateAnswer() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let started = expectation(description: "started")
        let agent = ScriptedAskAgent { _, _, _ in
            started.fulfill()
            try await Task.sleep(for: .seconds(30))
            return "Late answer"
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let task = Task {
            try await service.send(
                id: chat.id, question: "When?", expectedRevision: 0,
                approvedProviderID: nil, onEvent: { _ in }
            )
        }
        await fulfillment(of: [started], timeout: 3)
        try await service.delete(id: chat.id)
        do { _ = try await task.value; XCTFail("Deleted run must not save") } catch AskConversationRepositoryError
            .missing
        {}
        let missing = try await service.conversation(id: chat.id)
        XCTAssertNil(missing)
    }

    func testLoopbackProxyStillRequiresRemoteApproval() async throws {
        let fixture = try Fixture()
        let agent = ScriptedAskAgent { _, _, _ in "" }
        let config = LLMProviderConfig(
            id: .openaiCompatible, baseURL: URL(string: "http://127.0.0.1:19876/v1")!,
            apiKey: nil, modelName: "proxy", isLocal: true
        )
        let disclosure = try await fixture.service(agent, config: config).provider()
        XCTAssertTrue(disclosure.requiresRemoteConsent)
    }

    func testChangedSummaryCannotCompleteEvenWhenTranscriptIsUnchanged() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let prompt = Prompt(name: "Ask summary receipt fixture", content: "Summarize", category: .result)
        try PromptRepository(dbQueue: fixture.database.dbQueue).save(prompt)
        let summaries = PromptResultRepository(dbQueue: fixture.database.dbQueue)
        let summary = PromptResult(
            transcriptionId: source.id, promptId: prompt.id, promptName: "Summary", promptContent: "Summarize",
            content: "June plan.", sourceCorrectionRevision: 0,
            sourceTranscriptHash: PromptResultFreshness.sourceTranscriptHash(for: source)
        )
        try summaries.save(summary)
        let agent = ScriptedAskAgent { _, tool, event in
            _ = try await tool("get_summary", "{\"sourceID\":\"\(source.id.uuidString)\"}")
            _ = try await tool("search", #"{"query":"June"}"#)
            var edited = summary
            edited.content = "The overview was corrected."
            try summaries.save(edited)
            await event(.text("June [E1]."))
            return "June [E1]."
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(result.messages.last?.status, .failed)
        XCTAssertTrue(result.messages.last?.failureReason?.contains("changed") == true)
    }

    func testCancelledQuestionIsNotReplayedWithTheNextQuestion() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let snapshot = try XCTUnwrap(
            AskSourceService(dbQueue: fixture.database.dbQueue).snapshot(sourceIDs: [source.id]).first)
        let versions = [source.id: snapshot.revision]
        let section = AskContextSection(sourceIDs: [source.id])
        let chat = AskConversation(
            sections: [section],
            messages: [
                AskMessage(
                    sectionID: section.id, role: .user, content: "Abandoned question", sourceRevisions: versions),
                AskMessage(
                    sectionID: section.id, role: .assistant, status: .cancelled, content: "Partial",
                    sourceRevisions: versions),
            ])
        _ = try AskConversationRepository(dbQueue: fixture.database.dbQueue).create(chat)
        let agent = ScriptedAskAgent { request, tool, _ in
            XCTAssertFalse(request.messages.contains { $0.content.contains("Abandoned question") })
            XCTAssertFalse(request.messages.contains { $0.content == "Partial" })
            _ = try await tool("search", #"{"query":"June"}"#)
            return "June [E1]."
        }
        let result = try await fixture.service(agent).send(
            id: chat.id, question: "Current question", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in }
        )
        XCTAssertEqual(result.messages.last?.status, .complete)
        XCTAssertEqual(result.messages.count, 4)
    }

    private struct Fixture {
        let database: DatabaseManager
        let transcriptions: TranscriptionRepository

        init() throws {
            database = try DatabaseManager()
            transcriptions = TranscriptionRepository(dbQueue: database.dbQueue)
        }

        func source(_ title: String, _ text: String) throws -> Transcription {
            let value = Transcription(fileName: title, rawTranscript: text, status: .completed, sourceType: .meeting)
            try transcriptions.save(value)
            return value
        }

        func service(_ agent: any AskAgentRunning, config: LLMProviderConfig = .ollama()) -> AskWorkspaceService {
            AskWorkspaceService(
                databaseManager: database, client: MockLLMClient(),
                contextResolver: StaticLLMExecutionContextResolver(
                    context: LLMExecutionContext(providerConfig: config)),
                agent: agent
            )
        }
    }
}

private struct ScriptedAskAgent: AskAgentRunning {
    typealias Tool = @Sendable (String, String) async throws -> String
    typealias Event = @Sendable (AskAgentEvent) async -> Void
    let operation: @Sendable (AskAgentRequest, Tool, Event) async throws -> String

    init(_ operation: @escaping @Sendable (AskAgentRequest, Tool, Event) async throws -> String) {
        self.operation = operation
    }

    func run(
        request: AskAgentRequest, client: any LLMClientProtocol, context: LLMExecutionContext,
        tool: @escaping Tool, onEvent: @escaping Event
    ) async throws -> String {
        try await operation(request, tool, onEvent)
    }
}
