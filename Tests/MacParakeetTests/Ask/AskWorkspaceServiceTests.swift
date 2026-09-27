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

    func testReadPaginationWalksCanonicalPassagesAndSearchReportsMatchMode() async throws {
        let fixture = try Fixture()
        let source = try fixture.source(
            "Long meeting", String(repeating: "Launch discussion. ", count: 300) + "Final decision: October 24.")
        let agent = ScriptedAskAgent { _, tool, _ in
            struct Evidence: Decodable { let citation: String; let passage: AskPassage }
            struct Page: Decodable {
                let passages: [Evidence]
                let sourceID: UUID
                let start: Int
                let returnedCount: Int
                let totalPassages: Int
                let hasMore: Bool
                let nextStart: Int?
            }
            struct Search: Decodable {
                let matches: [Evidence]
                let query: String
                let matchMode: String
                let hasMore: Bool
            }
            let search = try JSONDecoder().decode(
                Search.self, from: Data(try await tool("search", #"{"query":"launch date","limit":1}"#).utf8))
            XCTAssertEqual(search.matchMode, "unicode61_bm25")
            XCTAssertEqual(search.query, "launch date")
            XCTAssertEqual(search.matches.count, 1)
            XCTAssertTrue(search.hasMore)
            var start = 0
            var indices: [Int] = []
            var finalCitation = ""
            while true {
                let raw = try await tool("read", "{\"sourceID\":\"\(source.id)\",\"start\":\(start),\"limit\":5}")
                let page = try JSONDecoder().decode(Page.self, from: Data(raw.utf8))
                XCTAssertEqual(page.sourceID, source.id)
                XCTAssertEqual(page.start, start)
                XCTAssertEqual(page.returnedCount, page.passages.count)
                XCTAssertLessThanOrEqual(page.returnedCount, 5)
                indices += page.passages.map { $0.passage.reference.segmentIndex }
                if let final = page.passages.first(where: { $0.passage.text.contains("October 24") }) {
                    finalCitation = final.citation
                }
                guard let next = page.nextStart else {
                    XCTAssertFalse(page.hasMore)
                    XCTAssertEqual(indices, Array(0..<page.totalPassages))
                    break
                }
                XCTAssertTrue(page.hasMore)
                XCTAssertEqual(next, start + page.returnedCount)
                guard next > start, next < page.totalPassages else {
                    XCTFail("Pagination did not advance within the recording"); break
                }
                start = next
            }
            XCTAssertFalse(finalCitation.isEmpty)
            return "October 24 \(finalCitation)."
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let answer = try await service.send(
            id: chat.id, question: "What was finally decided?", expectedRevision: chat.revision,
            approvedProviderID: nil, onEvent: { _ in })
        XCTAssertEqual(answer.messages.last?.status, .complete)
        XCTAssertEqual(answer.messages.last?.citations.count, 1)
    }

    func testByteLimitedPagesAdvanceOnlyReturnedPassagesAndKeepMarkersContiguous() async throws {
        let fixture = try Fixture()
        let source = Transcription(
            fileName: "Large labels",
            transcriptSegments: (0..<10).map { index in
                TranscriptSegmentRecord(
                    startMs: index * 1_000, endMs: (index + 1) * 1_000,
                    speakerId: "speaker-1", speakerLabel: String(repeating: "Speaker", count: 800),
                    text: "Launch decision \(index).",
                    wordRange: TranscriptSegmentWordRange(startIndex: index, endIndexExclusive: index + 1))
            }, status: .completed, sourceType: .meeting)
        try fixture.transcriptions.save(source)
        let agent = ScriptedAskAgent { _, tool, _ in
            struct Item: Decodable { let citation: String; let passage: AskPassage }
            struct Page: Decodable {
                let passages: [Item]?
                let matches: [Item]?
                var items: [Item] { passages ?? matches ?? [] }
                let returnedCount: Int
                let hasMore: Bool
                let nextStart: Int?
            }
            for name in ["read", "search"] {
                var start = 0
                var all: [Item] = []
                while start < 10 {
                    var arguments: [String: Any] = ["sourceID": source.id.uuidString, "start": start, "limit": 12]
                    if name == "search" { arguments["query"] = "launch date" }
                    let raw = try await tool(
                        name, String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self))
                    XCTAssertLessThanOrEqual(raw.utf8.count, 32_000)
                    let page = try JSONDecoder().decode(Page.self, from: Data(raw.utf8))
                    XCTAssertGreaterThan(page.returnedCount, 0)
                    XCTAssertLessThan(page.returnedCount, 10)
                    all += page.items
                    if let next = page.nextStart {
                        XCTAssertTrue(page.hasMore)
                        XCTAssertEqual(next, start + page.returnedCount)
                        start = next
                    } else {
                        XCTAssertFalse(page.hasMore)
                        break
                    }
                }
                XCTAssertEqual(all.map { $0.passage.reference.segmentIndex }, Array(0..<10))
                XCTAssertEqual(all.map(\.citation), (1...10).map { "[E\($0)]" })
            }
            return "Launch decision 9 [E10]."
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let answer = try await service.send(
            id: chat.id, question: "What was decided?", expectedRevision: chat.revision,
            approvedProviderID: nil, onEvent: { _ in })
        XCTAssertEqual(answer.messages.last?.status, .complete)
        XCTAssertEqual(answer.messages.last?.citations.first?.segmentIndex, 9)
        let activities = try XCTUnwrap(answer.messages.last?.activities)
        XCTAssertEqual(activities.compactMap(\.resultCount).reduce(0, +), 20)
        XCTAssertTrue(activities.allSatisfy { ($0.resultCount ?? 10) < 10 })
        XCTAssertEqual(activities.first?.hasMore, true)
        XCTAssertEqual(activities.last?.hasMore, false)
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
        XCTAssertEqual(result.messages.last?.activities?.first?.status, .complete)
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
        for malformed in ["[e1]", "[E 1]", "[E+1]", "[E-1]", "[E1x]", "[E1 ]"] {
            let source = try fixture.source("Planning", "Launch in June.")
            let agent = ScriptedAskAgent { _, tool, event in
                _ = try await tool("search", #"{"query":"June"}"#)
                let text = "Launch in June [E1] \(malformed)."
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

    func testSummaryToolBoundsAggregateUnicodeAndEscapedJSONWithoutChangingReceipts() async throws {
        try await assertSummaryBudget(content: String(repeating: "界", count: 4_000), expectedCount: 2)
        try await assertSummaryBudget(content: String(repeating: "\"\n\\", count: 1_333), expectedCount: 3)
    }

    func testSingleOversizedSummaryDoesNotPreventAnswerUsingTranscriptEvidence() async throws {
        // One grapheme cluster contains several scalars; a 4,000-character
        // receipt can exceed the byte limit even without any JSON escaping.
        try await assertSummaryBudget(content: String(repeating: "👨‍👩‍👧‍👦", count: 4_000), expectedCount: 0)
    }

    private func assertSummaryBudget(content: String, expectedCount: Int) async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let prompt = Prompt(name: "Bounded summary fixture", content: "Summarize", category: .result)
        try PromptRepository(dbQueue: fixture.database.dbQueue).save(prompt)
        let repository = PromptResultRepository(dbQueue: fixture.database.dbQueue)
        let summaries = try (0..<10).map { index in
            let summary = PromptResult(
                transcriptionId: source.id, promptId: prompt.id, promptName: "Summary", promptContent: "Summarize",
                content: content, sourceCorrectionRevision: 0,
                sourceTranscriptHash: PromptResultFreshness.sourceTranscriptHash(for: source),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(index)))
            try repository.save(summary)
            return summary
        }
        let agent = ScriptedAskAgent { _, tool, event in
            let output = try await tool("get_summary", "{\"sourceID\":\"\(source.id.uuidString)\"}")
            XCTAssertLessThanOrEqual(output.utf8.count, 32_000)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let returned = try decoder.decode([AskSummary].self, from: Data(output.utf8))
            XCTAssertEqual(returned.map(\.id), Array(summaries.prefix(expectedCount)).map(\.id))
            XCTAssertTrue(returned.allSatisfy { $0.content == content })
            // An omitted overview was never model context and must not become
            // a receipt that invalidates an otherwise valid cited answer.
            var omitted = summaries[expectedCount]
            omitted.content = "Changed after the tool call."
            try repository.save(omitted)
            _ = try await tool("search", #"{"query":"June"}"#)
            await event(.text("June [E1]."))
            return "June [E1]."
        }
        let service = fixture.service(agent)
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in })
        XCTAssertEqual(result.messages.last?.status, .complete)
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

    func testOversizedHistoryIsRejectedBeforePersistenceAndKeepsDraft() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let snapshot = try XCTUnwrap(
            AskSourceService(dbQueue: fixture.database.dbQueue).snapshot(sourceIDs: [source.id]).first)
        let versions = [source.id: snapshot.revision]
        let section = AskContextSection(sourceIDs: [source.id])
        let repository = AskConversationRepository(dbQueue: fixture.database.dbQueue)
        let chat = try repository.create(
            AskConversation(
                sections: [section],
                messages: [
                    AskMessage(sectionID: section.id, role: .user, content: "Earlier?", sourceRevisions: versions),
                    AskMessage(
                        sectionID: section.id, role: .assistant, content: String(repeating: "x", count: 33_000),
                        sourceRevisions: versions),
                ], draft: "Keep this question"))
        let persistedBeforeSend = try XCTUnwrap(repository.fetch(id: chat.id))
        let service = fixture.service(
            ScriptedAskAgent { _, _, _ in
                XCTFail("Oversized history must not run"); return ""
            })
        do {
            _ = try await service.send(
                id: chat.id, question: chat.draft, expectedRevision: chat.revision,
                approvedProviderID: nil, onEvent: { _ in })
            XCTFail("Expected preflight rejection")
        } catch AskWorkspaceError.contextTooLarge {
            XCTAssertTrue(AskWorkspaceError.contextTooLarge.localizedDescription.contains("new conversation"))
        }
        XCTAssertEqual(try repository.fetch(id: chat.id), persistedBeforeSend)
        let token = UUID()
        XCTAssertTrue(
            try repository.acquireRun(
                id: chat.id, expectedRevision: chat.revision, token: token,
                leaseUntil: Date().addingTimeInterval(30)))
        XCTAssertTrue(try repository.releaseRun(id: chat.id, token: token))
    }

    func testSerializedUTF8QuestionBudgetIncludesEscapingBeforePersistence() async throws {
        for question in [String(repeating: "界", count: 6_000), String(repeating: "\u{0001}", count: 3_000)] {
            let fixture = try Fixture()
            let source = try fixture.source("Planning", "Launch in June.")
            let service = fixture.service(
                ScriptedAskAgent { _, _, _ in
                    XCTFail("Oversized UTF8 or escaped JSON must not run"); return ""
                })
            let chat = try await service.create(sourceIDs: [source.id])
            let persistedBeforeSend = try await service.conversation(id: chat.id)
            do {
                _ = try await service.send(
                    id: chat.id, question: question, expectedRevision: chat.revision,
                    approvedProviderID: nil, onEvent: { _ in })
                XCTFail("Expected serialized-byte preflight rejection")
            } catch AskWorkspaceError.contextTooLarge {}
            let saved = try await service.conversation(id: chat.id)
            XCTAssertEqual(saved, persistedBeforeSend)
        }
    }

    func testBudgetAndInvalidActionFailuresKeepPartialTextAndSanitizeReason() async throws {
        for error in [
            AskAgentError.budgetExceeded("private provider payload"), .invalidModelAction, .unverifiedLocalCompletion,
        ] {
            let fixture = try Fixture()
            let source = try fixture.source("Planning", "Launch in June.")
            let service = fixture.service(
                ScriptedAskAgent { _, _, event in
                    await event(.text("Partial answer"))
                    throw error
                })
            let chat = try await service.create(sourceIDs: [source.id])
            let result = try await service.send(
                id: chat.id, question: "What changed?", expectedRevision: chat.revision,
                approvedProviderID: nil, onEvent: { _ in })
            XCTAssertEqual(result.messages.last?.status, .failed)
            XCTAssertEqual(result.messages.last?.content, "Partial answer")
            let reason = try XCTUnwrap(result.messages.last?.failureReason)
            XCTAssertFalse(reason.contains("private provider payload"))
            switch error {
            case .budgetExceeded: XCTAssertTrue(reason.contains("narrower question"))
            case .invalidModelAction: XCTAssertTrue(reason.contains("valid Ask action"))
            case .unverifiedLocalCompletion: XCTAssertTrue(reason.contains("did not confirm that generation finished"))
            default: XCTFail("Unexpected test error")
            }
        }
    }

    func testActivityEventsDescribeAcceptedToolsAndPersistWithAnswer() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let recorder = AskActivityRecorder()
        let service = fixture.service(
            ScriptedAskAgent { _, tool, event in
                _ = try await tool("list_sources", "{}")
                _ = try await tool("search", #"{"query":"June"}"#)
                _ = try await tool("read", "{\"sourceID\":\"\(source.id)\"}")
                _ = try await tool("get_summary", "{\"sourceID\":\"\(source.id)\"}")
                await event(.text("June [E1]."))
                return "June [E1]."
            })
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { await recorder.append($0) })
        let activities = try XCTUnwrap(result.messages.last?.activities)
        XCTAssertEqual(activities.map(\.tool), [.listSources, .search, .read, .getSummary])
        XCTAssertTrue(activities.allSatisfy { $0.status == .complete })
        XCTAssertEqual(activities.map(\.sourceCount), [1, 1, 1, 1])
        XCTAssertEqual(activities.map(\.resultCount), [nil, 1, 1, 0])
        XCTAssertEqual(activities[1].query, "June")
        XCTAssertEqual(activities[2].sourceTitle, "Planning")
        XCTAssertEqual(activities[2].hasMore, false)
        let events = await recorder.events
        let steps = events.compactMap { event -> AskActivity? in
            if case .step(let step) = event { return step }; return nil
        }
        XCTAssertEqual(steps.count, 8)
        for index in activities.indices {
            XCTAssertEqual(steps[index * 2].status, .running)
            XCTAssertEqual(steps[index * 2].id, activities[index].id)
            XCTAssertEqual(steps[index * 2 + 1], activities[index])
        }
        guard case .phase(.validating) = events.last else { return XCTFail("Validation must be the last phase") }
        let saved = try await service.conversation(id: chat.id)
        XCTAssertEqual(saved?.messages.last?.activities, activities)
    }

    func testCancelledToolActivitySettlesBeforePersistence() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let recorder = AskActivityRecorder()
        let service = fixture.service(
            ScriptedAskAgent { _, tool, _ in
                _ = try await tool("read", "{\"sourceID\":\"\(source.id)\"}")
                XCTFail("Cancelled operation must not return evidence")
                return ""
            })
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0, approvedProviderID: nil,
            onEvent: { event in
                await recorder.append(event)
                if case .step(let step) = event, step.status == .running {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        XCTAssertEqual(result.messages.last?.status, .cancelled)
        XCTAssertEqual(result.messages.last?.activities?.first?.status, .cancelled)
        XCTAssertNil(result.messages.last?.activities?.first?.resultCount)
        let saved = try await service.conversation(id: chat.id)
        XCTAssertEqual(saved?.messages.last?.activities, result.messages.last?.activities)
        let events = await recorder.events
        guard case .step(let terminal) = events.last else { return XCTFail("Missing cancellation event") }
        XCTAssertEqual(terminal.status, .cancelled)
    }

    func testToolCancelledAfterCompletionKeepsAcceptedActivityComplete() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let recorder = AskActivityRecorder()
        let service = fixture.service(
            ScriptedAskAgent { _, tool, _ in
                _ = try await tool("read", "{\"sourceID\":\"\(source.id)\"}")
                XCTFail("Cancellation after completion must still stop the run")
                return ""
            })
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0, approvedProviderID: nil,
            onEvent: { event in
                await recorder.append(event)
                if case .step(let step) = event, step.status == .complete {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            })
        XCTAssertEqual(result.messages.last?.status, .cancelled)
        let activity = try XCTUnwrap(result.messages.last?.activities?.first)
        XCTAssertEqual(activity.status, .complete)
        XCTAssertEqual(activity.resultCount, 1)
        let saved = try await service.conversation(id: chat.id)
        XCTAssertEqual(saved?.messages.last?.activities, result.messages.last?.activities)
    }

    func testFailedToolDoesNotDiscloseUnselectedSourceOrRawErrors() async throws {
        let fixture = try Fixture()
        let source = try fixture.source("Planning", "Launch in June.")
        let unselected = try fixture.source("Private title", "Private transcript")
        let service = fixture.service(
            ScriptedAskAgent { _, tool, _ in
                _ = try await tool("list_sources", "{}")
                _ = try await tool("read", "{\"sourceID\":\"\(unselected.id)\"}")
                return ""
            })
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in })
        let activities = try XCTUnwrap(result.messages.last?.activities)
        XCTAssertEqual(result.messages.last?.status, .failed)
        XCTAssertEqual(activities.map(\.status), [.complete, .failed])
        XCTAssertNil(activities.last?.sourceTitle)
        XCTAssertNil(activities.last?.resultCount)
        let saved = try await service.conversation(id: chat.id)
        XCTAssertEqual(saved?.messages.last?.activities, activities)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(activities), as: UTF8.self).contains("Private"))
    }

    func testActivityHistoryBoundDoesNotStopFurtherTools() async throws {
        let fixture = try Fixture()
        let source = try fixture.source(String(repeating: "T", count: 250), "Launch in June.")
        let query = String(repeating: "a", count: 250)
        let service = fixture.service(
            ScriptedAskAgent { _, tool, _ in
                _ = try await tool("search", "{\"query\":\"\(query)\",\"sourceID\":\"\(source.id)\"}")
                for _ in 0..<33 { _ = try await tool("list_sources", "{}") }
                return "Not enough evidence."
            })
        let chat = try await service.create(sourceIDs: [source.id])
        let result = try await service.send(
            id: chat.id, question: "When?", expectedRevision: 0,
            approvedProviderID: nil, onEvent: { _ in })
        let activities = try XCTUnwrap(result.messages.last?.activities)
        XCTAssertEqual(result.messages.last?.status, .incomplete)
        XCTAssertEqual(activities.count, 32)
        XCTAssertEqual(activities.first?.sourceTitle?.count, 200)
        XCTAssertEqual(activities.first?.query?.count, 200)
        XCTAssertTrue(activities.allSatisfy { $0.status == .complete })
    }

    func testLegacyMessageWithoutActivitiesDecodes() throws {
        let original = AskMessage(sectionID: UUID(), role: .assistant, content: "Old answer")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "activities")
        let decoded = try JSONDecoder().decode(
            AskMessage.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.activities)
        XCTAssertEqual(decoded.content, "Old answer")
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

private actor AskActivityRecorder {
    private(set) var events: [AskAgentEvent] = []
    func append(_ event: AskAgentEvent) { events.append(event) }
}
