import Foundation
import MacParakeetCore
import MacParakeetViewModels
import XCTest

@MainActor
final class AskWorkspaceViewModelTests: XCTestCase {
    func testPickerKeepsSelectionAcrossFiltersAndCancel() async {
        let source = UUID()
        let service = AskWorkspaceMock()
        await service.setSources([source])
        let model = AskWorkspaceViewModel(service: service)
        await model.createConversation()
        await model.beginSourceSelection()
        await model.toggleSource(source)
        XCTAssertEqual(model.pickerSelection, [source])

        await model.updateSourceFilter(AskSourceFilter(searchText: "no match", sourceType: .file))
        XCTAssertTrue(model.sourceResults.isEmpty)
        XCTAssertEqual(model.pickerSelection, [source])
        model.cancelSourceSelection()
        XCTAssertTrue(model.conversation?.activeSection?.sourceIDs.isEmpty == true)

        await model.beginSourceSelection()
        XCTAssertTrue(model.pickerSelection.isEmpty)
    }

    func testApplyingSourcesStartsSectionAndPreservesDraft() async {
        let source = UUID()
        let service = AskWorkspaceMock()
        await service.setSources([source])
        let model = AskWorkspaceViewModel(service: service)
        await model.createConversation()
        model.updateDraft("Compare the decisions")
        await model.beginSourceSelection()
        await model.toggleSource(source)
        await model.applySourceSelection()

        XCTAssertEqual(model.conversation?.sections.count, 2)
        XCTAssertEqual(model.conversation?.activeSection?.sourceIDs, [source])
        XCTAssertEqual(model.draft, "Compare the decisions")
        XCTAssertFalse(model.showingSourcePicker)
    }

    func testOlderLoadCannotReplaceNewerConversation() async {
        let first = AskConversation(title: "First")
        let second = AskConversation(title: "Second")
        let service = AskWorkspaceMock(conversations: [first, second])
        await service.delayConversation(first.id, nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        let older = Task { await model.openConversation(first.id) }
        await service.waitUntilRequested(first.id)
        await model.openConversation(second.id)
        await older.value

        XCTAssertEqual(model.conversation?.id, second.id)
    }

    func testDraftSurvivesNavigation() async {
        let first = AskConversation(title: "First")
        let second = AskConversation(title: "Second")
        let service = AskWorkspaceMock(conversations: [first, second])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(first.id)
        model.updateDraft("A question in progress")
        await model.openConversation(second.id)
        await model.openConversation(first.id)
        XCTAssertEqual(model.draft, "A question in progress")
    }

    func testNavigationPreservesDraftWhenSaveConflictsWithoutReload() async {
        for createNew in [false, true] {
            let first = AskConversation(title: "First", draft: "Earlier")
            let second = AskConversation(title: "Second")
            let service = AskWorkspaceMock(conversations: [first, second])
            let model = AskWorkspaceViewModel(service: service)
            await model.openConversation(first.id)
            model.updateDraft("My unsent question")

            var external = first
            external.draft = "CLI draft"
            external.revision += 1
            await service.replaceConversation(external)

            if createNew {
                await model.createConversation()
            } else {
                await model.openConversation(second.id)
            }

            XCTAssertEqual(model.conversation?.id, first.id)
            XCTAssertEqual(model.draft, "My unsent question")
            XCTAssertNotNil(model.errorMessage)
            let saved = try? await service.conversation(id: first.id)
            XCTAssertEqual(saved?.draft, "CLI draft")
            let conversations = try? await service.conversations()
            XCTAssertEqual(conversations?.count, 2)

            await model.load()
            XCTAssertEqual(model.savedDraftAtConflict, "CLI draft")
            await model.keepMyDraft()
            await model.openConversation(second.id)
            XCTAssertEqual(model.conversation?.id, second.id)
            let resolved = try? await service.conversation(id: first.id)
            XCTAssertEqual(resolved?.draft, "My unsent question")
        }
    }

    func testDraftFlushWaitsForEditsMadeDuringSave() async {
        let first = AskConversation(title: "First")
        let second = AskConversation(title: "Second")
        let service = AskWorkspaceMock(conversations: [first, second])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(first.id)
        model.updateDraft("First edit")
        await service.delay("saveDraftReturn", nanoseconds: 200_000_000)
        let navigation = Task { await model.openConversation(second.id) }
        await service.waitUntilRequested("saveDraftReturn")
        model.updateDraft("Latest edit")
        await navigation.value

        XCTAssertEqual(model.conversation?.id, second.id)
        let saved = try? await service.conversation(id: first.id)
        XCTAssertEqual(saved?.draft, "Latest edit")
    }

    func testSendPreservesLocalDraftWhenItsPreflightSaveConflicts() async {
        let source = UUID()
        let original = AskConversation(sections: [AskContextSection(sourceIDs: [source])])
        let service = AskWorkspaceMock(conversations: [original])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("My unsent question")
        var external = original
        external.draft = "CLI draft"
        external.revision += 1
        await service.replaceConversation(external)

        await model.send()
        await model.stopAndSettle()

        XCTAssertEqual(model.draft, "My unsent question")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.pendingQuestion)
        let saved = try? await service.conversation(id: original.id)
        XCTAssertEqual(saved?.draft, "CLI draft")
        XCTAssertTrue(saved?.messages.isEmpty == true)
    }

    func testDraftTypedWhileNavigationLoadsIsSavedBeforeAdoptingDestination() async {
        for createNew in [false, true] {
            let first = AskConversation(title: "First")
            let second = AskConversation(title: "Second")
            let service = AskWorkspaceMock(conversations: [first, second])
            let model = AskWorkspaceViewModel(service: service)
            await model.openConversation(first.id)
            if createNew {
                await service.delay("create", nanoseconds: 200_000_000)
            } else {
                await service.delayConversation(second.id, nanoseconds: 200_000_000)
            }
            let navigation = Task {
                if createNew {
                    await model.createConversation()
                } else {
                    await model.openConversation(second.id)
                }
            }
            if createNew {
                await service.waitUntilRequested("create")
            } else {
                await service.waitUntilRequested(second.id)
            }
            model.updateDraft("Typed while the destination loads")
            await navigation.value

            XCTAssertNotEqual(model.conversation?.id, first.id)
            let saved = try? await service.conversation(id: first.id)
            XCTAssertEqual(saved?.draft, "Typed while the destination loads")
        }
    }

    func testCreatedConversationRemainsReachableWhenFinalDraftSaveConflicts() async {
        let first = AskConversation(title: "First")
        let service = AskWorkspaceMock(conversations: [first])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(first.id)
        await service.delay("create", nanoseconds: 200_000_000)
        let navigation = Task { await model.createConversation() }
        await service.waitUntilRequested("create")
        model.updateDraft("My later edit")
        var external = first
        external.draft = "CLI draft"
        external.revision += 1
        await service.replaceConversation(external)
        await navigation.value

        XCTAssertEqual(model.conversation?.id, first.id)
        XCTAssertEqual(model.draft, "My later edit")
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.conversations.count, 2)
        let saved = try? await service.conversation(id: first.id)
        XCTAssertEqual(saved?.draft, "CLI draft")
    }

    func testProviderLookupCannotSendAfterNavigation() async {
        let source = UUID()
        let first = AskConversation(title: "First", sections: [AskContextSection(sourceIDs: [source])])
        let second = AskConversation(title: "Second")
        let service = AskWorkspaceMock(conversations: [first, second])
        await service.setSources([source])
        await service.delay("provider", nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(first.id)
        model.updateDraft("What changed?")
        let sending = Task { await model.send() }
        await service.waitUntilRequested("provider")
        await model.openConversation(second.id)
        await sending.value
        let original = try? await service.conversation(id: first.id)
        XCTAssertEqual(model.conversation?.id, second.id)
        XCTAssertTrue(original?.messages.isEmpty == true)
    }

    func testDelayedRenameDoesNotReplaceNewConversation() async {
        let first = AskConversation(title: "First")
        let second = AskConversation(title: "Second")
        let service = AskWorkspaceMock(conversations: [first, second])
        await service.delay("rename", nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(first.id)
        model.renameDraft = "Renamed"
        let rename = Task { await model.renameConversation() }
        await service.waitUntilRequested("rename")
        await model.openConversation(second.id)
        await rename.value
        XCTAssertEqual(model.conversation?.id, second.id)
        XCTAssertEqual(model.conversation?.title, "Second")
    }

    func testDelayedSourceChangeDoesNotReplaceNewConversation() async {
        let source = UUID()
        let first = AskConversation(title: "First")
        let second = AskConversation(title: "Second")
        let service = AskWorkspaceMock(conversations: [first, second])
        await service.setSources([source])
        await service.delay("select", nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(first.id)
        await model.beginSourceSelection()
        await model.toggleSource(source)
        let apply = Task { await model.applySourceSelection() }
        await service.waitUntilRequested("select")
        await model.openConversation(second.id)
        await apply.value
        XCTAssertEqual(model.conversation?.id, second.id)
        XCTAssertTrue(model.conversation?.activeSection?.sourceIDs.isEmpty == true)
    }

    func testDelayedDeleteDoesNotClearNewConversation() async {
        let first = AskConversation(title: "First")
        let second = AskConversation(title: "Second")
        let service = AskWorkspaceMock(conversations: [first, second])
        await service.delay("delete", nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(first.id)
        let deleting = Task { await model.deleteConversation() }
        await service.waitUntilRequested("delete")
        await model.openConversation(second.id)
        await deleting.value
        XCTAssertEqual(model.conversation?.id, second.id)
    }

    func testDelayedNewConversationDoesNotReplaceLaterNavigation() async {
        let existing = AskConversation(title: "Existing")
        let service = AskWorkspaceMock(conversations: [existing])
        await service.delay("create", nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        let creating = Task { await model.createConversation() }
        await service.waitUntilRequested("create")
        await model.openConversation(existing.id)
        await creating.value
        XCTAssertEqual(model.conversation?.id, existing.id)
    }

    func testLibraryHandoffSurvivesAskViewLoadDuringCreation() async {
        let source = UUID()
        let service = AskWorkspaceMock()
        await service.setSources([source])
        await service.delay("create", nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        let handoff = Task { await model.startFromLibrary(sourceIDs: [source]) }
        await service.waitUntilRequested("create")
        await model.load()
        await handoff.value
        XCTAssertEqual(model.conversation?.activeSection?.sourceIDs, [source])
        XCTAssertEqual(model.conversations.count, 1)
    }

    func testReloadReconcilesExternalMessagesAndSourcesWithoutLosingLocalDraft() async {
        let firstSource = UUID()
        let secondSource = UUID()
        let original = AskConversation(title: "Decision", sections: [AskContextSection(sourceIDs: [firstSource])])
        let service = AskWorkspaceMock(conversations: [original])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("My next question")

        var external = original
        let section = AskContextSection(sourceIDs: [firstSource, secondSource])
        external.sections.append(section)
        external.messages.append(AskMessage(sectionID: section.id, role: .user, content: "CLI question"))
        external.revision += 1
        await service.replaceConversation(external)
        await model.load()

        XCTAssertEqual(model.conversation?.revision, external.revision + 1)
        XCTAssertEqual(model.conversation?.activeSection?.sourceIDs, [firstSource, secondSource])
        XCTAssertEqual(model.conversation?.messages.last?.content, "CLI question")
        XCTAssertEqual(model.draft, "My next question")
        let saved = try? await service.conversation(id: original.id)
        XCTAssertEqual(saved?.draft, "My next question")
    }

    func testKeepMyDraftSavesAnEditMadeWhileResolutionIsPending() async {
        let original = AskConversation(title: "Draft", draft: "Earlier")
        let service = AskWorkspaceMock(conversations: [original])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("My first edit")
        var external = original
        external.draft = "CLI edit"
        external.revision += 1
        await service.replaceConversation(external)
        await model.load()
        XCTAssertEqual(model.savedDraftAtConflict, "CLI edit")

        await service.delay("saveDraft", nanoseconds: 200_000_000)
        let resolution = Task { await model.keepMyDraft() }
        await service.waitUntilRequested("saveDraft")
        model.updateDraft("My final edit")
        await resolution.value

        let saved = try? await service.conversation(id: original.id)
        XCTAssertNil(model.savedDraftAtConflict)
        XCTAssertEqual(model.draft, "My final edit")
        XCTAssertEqual(saved?.draft, "My final edit")
    }

    func testReloadSavesLatestEditAfterDelayedFetch() async {
        let source = UUID()
        let original = AskConversation(title: "Decision")
        let service = AskWorkspaceMock(conversations: [original])
        await service.delayConversation(original.id, nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("First edit")

        var external = original
        external.sections.append(AskContextSection(sourceIDs: [source]))
        external.revision += 1
        await service.replaceConversation(external)
        let reload = Task { await model.load() }
        await service.waitUntilConversationRequested(original.id, count: 2)
        model.updateDraft("Latest edit")
        await reload.value

        let saved = try? await service.conversation(id: original.id)
        XCTAssertEqual(model.conversation?.activeSection?.sourceIDs, [source])
        XCTAssertEqual(model.draft, "Latest edit")
        XCTAssertEqual(saved?.draft, "Latest edit")
        XCTAssertNil(model.savedDraftAtConflict)
    }

    func testReloadDoesNotAdoptStaleDraftSaveResponse() async {
        let source = UUID()
        let original = AskConversation(title: "Decision")
        let service = AskWorkspaceMock(conversations: [original])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("My edit")
        await service.delay("saveDraftReturn", nanoseconds: 200_000_000)
        let saving = Task { await model.flushDraft() }
        await service.waitUntilRequested("saveDraftReturn")
        guard var external = try? await service.conversation(id: original.id) else {
            XCTFail("Saved conversation missing")
            return
        }
        external.sections.append(AskContextSection(sourceIDs: [source]))
        external.revision += 1
        await service.replaceConversation(external)

        await model.load()
        await saving.value

        XCTAssertEqual(model.conversation?.revision, external.revision)
        XCTAssertEqual(model.conversation?.activeSection?.sourceIDs, [source])
        XCTAssertEqual(model.draft, "My edit")
        XCTAssertNil(model.savedDraftAtConflict)
    }

    func testReloadClearsEvidenceFromEarlierMessageState() async {
        let original = AskConversation(title: "Decision")
        let service = AskWorkspaceMock(conversations: [original])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        await model.openEvidence(AskEvidenceReference(sourceID: UUID(), sourceRevision: "r1", segmentIndex: 0))
        XCTAssertNotNil(model.evidence)
        let earlierReset = model.evidenceResetID

        var external = original
        external.revision += 1
        await service.replaceConversation(external)
        await model.load()

        XCTAssertNil(model.evidence)
        XCTAssertNotEqual(model.evidenceResetID, earlierReset)
    }

    func testExternalDeletionClearsConflictAndRestoresDraftInNewConversation() async {
        let original = AskConversation(title: "Draft", draft: "Earlier")
        let service = AskWorkspaceMock(conversations: [original])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("My unsent question")
        var external = original
        external.draft = "CLI draft"
        external.revision += 1
        await service.replaceConversation(external)
        await model.load()
        XCTAssertNotNil(model.savedDraftAtConflict)

        try? await service.delete(id: original.id)
        await model.load()
        XCTAssertNil(model.conversation)
        XCTAssertNil(model.savedDraftAtConflict)
        XCTAssertEqual(model.recoveredDraft, "My unsent question")
        await model.createConversation()

        XCTAssertEqual(model.draft, "My unsent question")
        XCTAssertNil(model.recoveredDraft)
        let saved = try? await service.conversation(id: model.conversation!.id)
        XCTAssertEqual(saved?.draft, "My unsent question")
    }

    func testExternalDraftConflictNeedsExplicitChoice() async {
        let original = AskConversation(title: "Draft", draft: "Earlier")
        let service = AskWorkspaceMock(conversations: [original])
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("My local draft")
        var external = original
        external.draft = "CLI draft"
        external.revision += 1
        await service.replaceConversation(external)

        await model.load()
        await model.flushDraft()
        let persisted = try? await service.conversation(id: original.id)
        XCTAssertEqual(model.draft, "My local draft")
        XCTAssertEqual(model.savedDraftAtConflict, "CLI draft")
        XCTAssertEqual(persisted?.draft, "CLI draft")

        model.useSavedDraft()
        XCTAssertEqual(model.draft, "CLI draft")
        XCTAssertNil(model.savedDraftAtConflict)
    }

    func testSubmittedQuestionAppearsImmediatelyAndLaterDraftSurvives() async {
        let source = UUID()
        let original = AskConversation(sections: [AskContextSection(sourceIDs: [source])])
        let service = AskWorkspaceMock(conversations: [original])
        await service.setSources([source])
        await service.delay("send", nanoseconds: 200_000_000)
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("What changed?")
        await model.send()
        await service.waitUntilRequested("send")
        XCTAssertEqual(model.pendingQuestion, "What changed?")
        XCTAssertEqual(model.draft, "")
        model.updateDraft("Follow-up question")
        await model.stopAndSettle()
        XCTAssertNil(model.pendingQuestion)
        XCTAssertEqual(model.draft, "Follow-up question")
        XCTAssertEqual(model.conversation?.messages.filter { $0.role == .user }.count, 1)
    }

    func testSendSetupFailureRestoresSubmittedQuestion() async {
        let source = UUID()
        let original = AskConversation(sections: [AskContextSection(sourceIDs: [source])])
        let service = AskWorkspaceMock(conversations: [original])
        await service.setSources([source])
        await service.failNextSend()
        let model = AskWorkspaceViewModel(service: service)
        await model.openConversation(original.id)
        model.updateDraft("What changed?")
        await model.send()
        await model.stopAndSettle()
        XCTAssertEqual(model.draft, "What changed?")
        XCTAssertNil(model.pendingQuestion)
    }
}

private actor AskWorkspaceMock: AskWorkspaceServing {
    private var values: [UUID: AskConversation]
    private var descriptors: [UUID: AskSourceDescriptor] = [:]
    private var delayedIDs: [UUID: UInt64] = [:]
    private var requestedIDs: Set<UUID> = []
    private var conversationRequestCounts: [UUID: Int] = [:]
    private var operationDelays: [String: UInt64] = [:]
    private var requestedOperations: Set<String> = []
    private var shouldFailSend = false

    init(conversations: [AskConversation] = []) {
        values = Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) })
    }

    func setSources(_ ids: [UUID]) {
        for id in ids {
            descriptors[id] = AskSourceDescriptor(
                id: id, title: "Product sync", recordedAt: Date(), sourceType: .meeting,
                durationMs: 60_000, labelIDs: [], preview: "We discussed the plan.", isAvailable: true
            )
        }
    }

    func delayConversation(_ id: UUID, nanoseconds: UInt64) { delayedIDs[id] = nanoseconds }
    func waitUntilRequested(_ id: UUID) async {
        while !requestedIDs.contains(id) { await Task.yield() }
    }
    func waitUntilConversationRequested(_ id: UUID, count: Int) async {
        while conversationRequestCounts[id, default: 0] < count { await Task.yield() }
    }
    func delay(_ operation: String, nanoseconds: UInt64) { operationDelays[operation] = nanoseconds }
    func replaceConversation(_ value: AskConversation) { values[value.id] = value }
    func failNextSend() { shouldFailSend = true }
    func waitUntilRequested(_ operation: String) async {
        while !requestedOperations.contains(operation) { await Task.yield() }
    }
    private func pause(_ operation: String) async {
        requestedOperations.insert(operation)
        if let duration = operationDelays[operation] {
            try? await Task.sleep(nanoseconds: duration)
        }
    }

    func conversations() throws -> [AskConversation] { Array(values.values) }
    func conversation(id: UUID) async throws -> AskConversation? {
        requestedIDs.insert(id)
        conversationRequestCounts[id, default: 0] += 1
        if let delay = delayedIDs[id] { try await Task.sleep(nanoseconds: delay) }
        return values[id]
    }
    func create(sourceIDs: [UUID]) async throws -> AskConversation {
        await pause("create")
        let value = AskConversation(sections: [AskContextSection(sourceIDs: sourceIDs)])
        values[value.id] = value
        return value
    }
    func rename(id: UUID, title: String, expectedRevision: Int) async throws -> AskConversation {
        await pause("rename")
        var value = try required(id, revision: expectedRevision)
        value.title = title
        value.revision += 1
        values[id] = value
        return value
    }
    func delete(id: UUID) async throws {
        await pause("delete")
        values[id] = nil
    }
    func selectSources(id: UUID, sourceIDs: [UUID], expectedRevision: Int) async throws -> AskConversation {
        await pause("select")
        var value = try required(id, revision: expectedRevision)
        value.sections.append(AskContextSection(sourceIDs: sourceIDs))
        value.revision += 1
        values[id] = value
        return value
    }
    func saveDraft(id: UUID, draft: String, expectedRevision: Int) async throws -> AskConversation {
        await pause("saveDraft")
        var value = try required(id, revision: expectedRevision)
        value.draft = draft
        value.revision += 1
        values[id] = value
        await pause("saveDraftReturn")
        return value
    }
    func sources(filter: AskSourceFilter) throws -> [AskSourceDescriptor] {
        descriptors.values.filter {
            (filter.sourceType == nil || $0.sourceType == filter.sourceType)
                && (filter.searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(filter.searchText))
        }
    }
    func sourceSnapshots(ids: [UUID]) throws -> [AskSourceSnapshot] {
        ids.compactMap { id in
            descriptors[id].map {
                AskSourceSnapshot(descriptor: $0, revision: "r1", passageCount: 1, status: .available)
            }
        }
    }
    func labels() throws -> [MeetingLabel] { [] }
    func provider() async throws -> AskProviderDisclosure {
        await pause("provider")
        return AskProviderDisclosure(
            id: "local", name: "Local", model: "Test", endpoint: "On this Mac", requiresRemoteConsent: false)
    }
    func evidence(_ reference: AskEvidenceReference) throws -> AskEvidence {
        AskEvidence(status: .unavailable, source: nil, passage: nil)
    }
    func send(
        id: UUID, question: String, expectedRevision: Int, approvedProviderID: String?,
        onEvent: @escaping @Sendable (AskAgentEvent) async -> Void
    ) async throws -> AskConversation {
        await pause("send")
        if shouldFailSend {
            shouldFailSend = false
            throw MockError.missing
        }
        var value = try required(id, revision: expectedRevision)
        value.messages.append(AskMessage(sectionID: value.activeSection!.id, role: .user, content: question))
        value.draft = ""
        value.revision += 1
        values[id] = value
        await onEvent(.activity("Searching"))
        return value
    }

    private func required(_ id: UUID, revision: Int) throws -> AskConversation {
        guard let value = values[id], value.revision == revision else { throw MockError.missing }
        return value
    }
}

private enum MockError: Error { case missing }
