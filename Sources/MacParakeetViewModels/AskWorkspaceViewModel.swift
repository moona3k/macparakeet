import Foundation
import MacParakeetCore

@MainActor
@Observable
public final class AskWorkspaceViewModel {
    public private(set) var conversations: [AskConversation] = []
    public private(set) var conversation: AskConversation?
    public private(set) var isLoading = false
    public private(set) var isSending = false
    public private(set) var isStopping = false
    public private(set) var activity: String?
    public private(set) var streamingText = ""
    public private(set) var pendingQuestion: String?
    public private(set) var errorMessage: String?
    public private(set) var provider: AskProviderDisclosure?
    public private(set) var evidence: AskEvidence?
    public private(set) var isEvidenceLoading = false
    public private(set) var evidenceResetID = UUID()
    public private(set) var activeSourceSnapshots: [AskSourceSnapshot] = []

    public var draft = ""
    public var showingSourcePicker = false
    public private(set) var sourcePickerID = UUID()
    public var showingRemoteConsent = false
    public var showingRename = false
    public var renameDraft = ""
    public var showingDeleteConfirmation = false
    public var sourceFilter = AskSourceFilter(sourceType: .meeting)
    public private(set) var sourceResults: [AskSourceDescriptor] = []
    public private(set) var sourceLabels: [MeetingLabel] = []
    public private(set) var pickerSelection: [UUID] = []
    public private(set) var selectedSourceSnapshots: [AskSourceSnapshot] = []
    public private(set) var isLoadingSources = false
    public private(set) var hasMoreSources = false
    public private(set) var sourcePickerError: String?
    public private(set) var savedDraftAtConflict: String?
    public private(set) var recoveredDraft: String?

    private var service: (any AskWorkspaceServing)?
    private var loadGeneration = 0
    private var sourceGeneration = 0
    private var pickerGeneration = 0
    private var evidenceGeneration = 0
    private var draftGeneration = 0
    private var draftReloadGeneration: Int?
    private var runGeneration = 0
    private var sendTask: Task<Void, Never>?
    private var draftTask: Task<Void, Never>?
    private var pendingLibrarySourceIDs: [UUID]?
    private var isCreatingFromLibrary = false
    private var pendingRemoteSend: (id: UUID, revision: Int, question: String, providerID: String, navigation: Int)?
    private let pageSize = 50
    public static let maximumSources = 32

    public init(service: (any AskWorkspaceServing)? = nil) {
        self.service = service
    }

    public func configure(service: any AskWorkspaceServing) {
        self.service = service
        Task { [weak self] in await self?.load() }
    }

    public func load() async {
        guard let service, !isCreatingFromLibrary else { return }
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil
        do {
            let list = try await service.conversations()
            let disclosure = try? await service.provider()
            guard loadGeneration == generation, !isCreatingFromLibrary else { return }
            conversations = list
            provider = disclosure
            isLoading = false
            if let pendingLibrarySourceIDs {
                self.pendingLibrarySourceIDs = nil
                await createConversation(sourceIDs: pendingLibrarySourceIDs)
            } else if let current = conversation, !isSending {
                draftReloadGeneration = generation
                defer { if draftReloadGeneration == generation { draftReloadGeneration = nil } }
                let pendingSave = draftTask
                pendingSave?.cancel()
                await pendingSave?.value
                guard loadGeneration == generation, conversation?.id == current.id else { return }
                var observed = conversation!
                var updated = try await service.conversation(id: current.id)
                guard loadGeneration == generation, conversation?.id == current.id else { return }
                // An autosave already in flight can advance the local revision
                // while the service read is suspended. Read again in that case.
                while conversation?.revision != observed.revision {
                    observed = conversation!
                    updated = try await service.conversation(id: current.id)
                    guard loadGeneration == generation, conversation?.id == current.id else { return }
                }
                if let updated {
                    let unsavedDraft = draft != observed.draft
                    let localDraft = draft
                    let externalDraftChanged = updated.draft != observed.draft
                    let needsDraftSave = unsavedDraft && localDraft != updated.draft
                    conversation = updated
                    updateList(updated)
                    errorMessage = nil
                    draft = needsDraftSave ? localDraft : updated.draft
                    if needsDraftSave && externalDraftChanged {
                        savedDraftAtConflict = updated.draft
                    } else if !needsDraftSave {
                        savedDraftAtConflict = nil
                    }
                    closeEvidence()
                    draftReloadGeneration = nil
                    if needsDraftSave && savedDraftAtConflict == nil { await flushDraft() }
                    await refreshActiveSources(for: updated)
                } else {
                    if !draft.isEmpty { recoveredDraft = draft }
                    conversation = nil
                    conversations.removeAll { $0.id == current.id }
                    activeSourceSnapshots = []
                    savedDraftAtConflict = nil
                    closeEvidence()
                    errorMessage =
                        "This conversation was removed in another process. Start a new conversation to recover your draft."
                }
            } else if conversation == nil, let first = list.first {
                await openConversation(first.id)
            }
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
        if loadGeneration == generation { isLoading = false }
    }

    public func openConversation(_ id: UUID) async {
        guard let service else { return }
        guard !blockWhileDraftConflicted() else { return }
        isLoading = false
        loadGeneration += 1
        let generation = loadGeneration
        cancelSourceSelection()
        pendingRemoteSend = nil
        showingRemoteConsent = false
        showingRename = false
        showingDeleteConfirmation = false
        await stopAndSettle()
        guard loadGeneration == generation else { return }
        await flushDraft()
        guard loadGeneration == generation else { return }
        evidence = nil
        evidenceGeneration += 1
        errorMessage = nil
        do {
            guard let loaded = try await service.conversation(id: id) else {
                throw AskUIError.conversationUnavailable
            }
            guard loadGeneration == generation else { return }
            adopt(loaded)
            await refreshActiveSources(for: loaded)
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func createConversation(sourceIDs: [UUID] = []) async {
        guard let service else { return }
        guard !blockWhileDraftConflicted() else { return }
        isLoading = false
        loadGeneration += 1
        let generation = loadGeneration
        cancelSourceSelection()
        pendingRemoteSend = nil
        showingRemoteConsent = false
        showingRename = false
        showingDeleteConfirmation = false
        await stopAndSettle()
        guard loadGeneration == generation else { return }
        await flushDraft()
        guard loadGeneration == generation else { return }
        errorMessage = nil
        do {
            let created = try await service.create(sourceIDs: sourceIDs)
            guard loadGeneration == generation else { return }
            adopt(created)
            if let recoveredDraft {
                draft = recoveredDraft
                self.recoveredDraft = nil
                await flushDraft()
                guard loadGeneration == generation, conversation?.id == created.id else { return }
            }
            evidence = nil
            let list = try await service.conversations()
            guard loadGeneration == generation, conversation?.id == created.id else { return }
            conversations = list
            await refreshActiveSources(for: created)
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    public func startFromLibrary(sourceIDs: [UUID]) async {
        var seen: Set<UUID> = []
        let ids = sourceIDs.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        isCreatingFromLibrary = true
        defer { isCreatingFromLibrary = false }
        if service == nil {
            pendingLibrarySourceIDs = ids
            return
        }
        await createConversation(sourceIDs: ids)
    }

    public func updateDraft(_ value: String) {
        draft = value
        draftGeneration += 1
        if isSending {
            draftTask?.cancel()
            return
        }
        if savedDraftAtConflict != nil || draftReloadGeneration == loadGeneration {
            draftTask?.cancel()
            return
        }
        let generation = draftGeneration
        draftTask?.cancel()
        draftTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.draftGeneration == generation else { return }
            await self.flushDraft()
        }
    }

    public func flushDraft() async {
        draftTask?.cancel()
        guard !isSending, savedDraftAtConflict == nil,
            draftReloadGeneration != loadGeneration
        else { return }
        guard let service, let current = conversation, current.draft != draft else { return }
        let intendedDraft = draft
        do {
            let saved = try await service.saveDraft(
                id: current.id, draft: intendedDraft, expectedRevision: current.revision
            )
            guard conversation?.id == saved.id,
                conversation?.revision == current.revision
            else { return }
            conversation = saved
            updateList(saved)
            if draft != intendedDraft, !isSending {
                Task { await flushDraft() }
            }
        } catch {
            guard conversation?.id == current.id else { return }
            errorMessage = "Could not save draft: \(error.localizedDescription)"
        }
    }

    public func renameConversation() async {
        guard let service, let current = conversation else { return }
        let navigation = loadGeneration
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        await flushDraft()
        guard let latest = conversation, latest.id == current.id,
            loadGeneration == navigation
        else { return }
        do {
            let renamed = try await service.rename(
                id: latest.id, title: name, expectedRevision: latest.revision
            )
            guard loadGeneration == navigation, conversation?.id == latest.id,
                conversation?.revision == latest.revision
            else { return }
            conversation = renamed
            updateList(renamed)
            showingRename = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func deleteConversation() async {
        guard let service, let current = conversation else { return }
        await stopAndSettle()
        do {
            try await service.delete(id: current.id)
            conversations.removeAll { $0.id == current.id }
            showingDeleteConfirmation = false
            guard conversation?.id == current.id else { return }
            conversation = nil
            draft = ""
            activeSourceSnapshots = []
            evidence = nil
            if let next = conversations.first { await openConversation(next.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func beginSourceSelection() async {
        guard let service else { return }
        if conversation == nil { await createConversation() }
        guard let current = conversation else { return }
        pickerGeneration += 1
        let generation = pickerGeneration
        pickerSelection = current.activeSection?.sourceIDs ?? []
        sourcePickerID = UUID()
        sourceResults = []
        hasMoreSources = false
        selectedSourceSnapshots = []
        isLoadingSources = true
        showingSourcePicker = true
        sourcePickerError = nil
        sourceFilter = AskSourceFilter(sourceType: .meeting, limit: pageSize)
        do {
            let labels = try await service.labels()
            guard pickerGeneration == generation, showingSourcePicker,
                conversation?.id == current.id
            else { return }
            sourceLabels = labels.filter { !$0.isArchived }
        } catch {
            guard pickerGeneration == generation, showingSourcePicker,
                conversation?.id == current.id
            else { return }
            sourcePickerError = error.localizedDescription
        }
        guard pickerGeneration == generation else { return }
        await refreshSelectedSourceSnapshots()
        await searchSources()
    }

    public func updateSourceFilter(_ filter: AskSourceFilter) async {
        sourceFilter = filter
        await searchSources()
    }

    /// Apply the latest UI filter synchronously before scheduling a search so
    /// older search tasks cannot restore an earlier typed query.
    public func setSourceFilter(_ filter: AskSourceFilter) {
        sourceFilter = filter
        sourceGeneration += 1
        Task { await searchSources() }
    }

    public func searchSources(loadMore: Bool = false) async {
        guard let service else { return }
        sourceGeneration += 1
        let generation = sourceGeneration
        isLoadingSources = true
        sourcePickerError = nil
        var query = sourceFilter
        query.limit = pageSize
        query.offset = loadMore ? sourceResults.count : 0
        do {
            let results = try await service.sources(filter: query)
            guard sourceGeneration == generation, showingSourcePicker else { return }
            if loadMore { sourceResults.append(contentsOf: results) } else { sourceResults = results }
            hasMoreSources = results.count == pageSize
        } catch {
            guard sourceGeneration == generation else { return }
            sourcePickerError = error.localizedDescription
        }
        if sourceGeneration == generation { isLoadingSources = false }
    }

    public func toggleSource(_ id: UUID) async {
        if let index = pickerSelection.firstIndex(of: id) {
            pickerSelection.remove(at: index)
        } else {
            guard pickerSelection.count < Self.maximumSources else {
                sourcePickerError = "Choose up to \(Self.maximumSources) sources."
                return
            }
            pickerSelection.append(id)
        }
        sourcePickerError = nil
        await refreshSelectedSourceSnapshots()
    }

    public func selectVisibleSources() async {
        let visible = sourceResults.filter(\.isAvailable).map(\.id)
        for id in visible where !pickerSelection.contains(id) {
            guard pickerSelection.count < Self.maximumSources else {
                sourcePickerError = "Choose up to \(Self.maximumSources) sources."
                break
            }
            pickerSelection.append(id)
        }
        await refreshSelectedSourceSnapshots()
    }

    public func cancelSourceSelection() {
        showingSourcePicker = false
        pickerGeneration += 1
        sourceGeneration += 1
        isLoadingSources = false
        sourcePickerError = nil
    }

    public func applySourceSelection() async {
        guard let service, let current = conversation, showingSourcePicker else { return }
        guard !blockWhileDraftConflicted() else { return }
        let navigation = loadGeneration
        let picker = pickerGeneration
        let selected = pickerSelection
        if selected == current.activeSection?.sourceIDs {
            cancelSourceSelection()
            return
        }
        await stopAndSettle()
        guard loadGeneration == navigation, pickerGeneration == picker,
            conversation?.id == current.id
        else { return }
        await flushDraft()
        guard let latest = conversation, latest.id == current.id,
            loadGeneration == navigation, pickerGeneration == picker
        else { return }
        do {
            let changed = try await service.selectSources(
                id: latest.id, sourceIDs: selected, expectedRevision: latest.revision
            )
            guard loadGeneration == navigation, pickerGeneration == picker,
                conversation?.id == latest.id,
                conversation?.revision == latest.revision
            else { return }
            adopt(changed)
            updateList(changed)
            cancelSourceSelection()
            await refreshActiveSources(for: changed)
        } catch {
            sourcePickerError = error.localizedDescription
        }
    }

    public func send() async {
        guard let service, let current = conversation, !isSending else { return }
        guard !blockWhileDraftConflicted() else { return }
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !(current.activeSection?.sourceIDs.isEmpty ?? true) else { return }
        let navigation = loadGeneration
        await flushDraft()
        guard loadGeneration == navigation, let ready = conversation,
            ready.id == current.id, !isSending,
            draft.trimmingCharacters(in: .whitespacesAndNewlines) == question
        else { return }
        let revision = ready.revision
        let disclosure: AskProviderDisclosure
        do {
            disclosure = try await service.provider()
        } catch {
            guard loadGeneration == navigation, conversation?.id == current.id else { return }
            errorMessage = error.localizedDescription
            return
        }
        guard loadGeneration == navigation, conversation?.id == current.id,
            conversation?.revision == revision, !isSending,
            draft.trimmingCharacters(in: .whitespacesAndNewlines) == question
        else { return }
        provider = disclosure
        if disclosure.requiresRemoteConsent {
            pendingRemoteSend = (current.id, revision, question, disclosure.id, navigation)
            showingRemoteConsent = true
            return
        }
        await beginSend(
            question: question, approvedProviderID: nil,
            expectedID: current.id, navigation: navigation)
    }

    public func approveRemoteSend() async {
        showingRemoteConsent = false
        guard let pending = pendingRemoteSend else { return }
        pendingRemoteSend = nil
        guard loadGeneration == pending.navigation,
            conversation?.id == pending.id,
            conversation?.revision == pending.revision,
            draft.trimmingCharacters(in: .whitespacesAndNewlines) == pending.question
        else { return }
        await beginSend(
            question: pending.question, approvedProviderID: pending.providerID,
            expectedID: pending.id, navigation: pending.navigation)
    }

    public func stopAndSettle() async {
        guard let sendTask else { return }
        isStopping = true
        sendTask.cancel()
        await sendTask.value
        self.sendTask = nil
        isStopping = false
    }

    public func openEvidence(_ reference: AskEvidenceReference) async {
        guard let service else { return }
        evidenceGeneration += 1
        let generation = evidenceGeneration
        isEvidenceLoading = true
        evidence = nil
        do {
            let loaded = try await service.evidence(reference)
            guard evidenceGeneration == generation else { return }
            evidence = loaded
        } catch {
            guard evidenceGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
        if evidenceGeneration == generation { isEvidenceLoading = false }
    }

    public func closeEvidence() {
        evidenceGeneration += 1
        evidence = nil
        isEvidenceLoading = false
        evidenceResetID = UUID()
    }

    private func beginSend(
        question: String, approvedProviderID: String?, expectedID: UUID, navigation: Int
    ) async {
        guard let service, let current = conversation, current.id == expectedID,
            loadGeneration == navigation, !isSending, !question.isEmpty
        else { return }
        await flushDraft()
        guard let latest = conversation, latest.id == current.id,
            loadGeneration == navigation, !isSending,
            draft.trimmingCharacters(in: .whitespacesAndNewlines) == question
        else { return }
        runGeneration += 1
        let generation = runGeneration
        let draftAtStart = draft
        let draftGenerationAtStart = draftGeneration
        isSending = true
        pendingQuestion = question
        draft = ""
        isStopping = false
        streamingText = ""
        activity = "Starting investigation…"
        errorMessage = nil
        // Show the submitted question immediately. The saved draft remains in
        // storage until the service accepts the send, so preflight failures
        // can restore it without losing later typing.
        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.send(
                    id: latest.id,
                    question: question,
                    expectedRevision: latest.revision,
                    approvedProviderID: approvedProviderID,
                    onEvent: { [weak self] event in
                        await self?.accept(event, generation: generation, conversationID: latest.id)
                    }
                )
                guard self.runGeneration == generation, self.conversation?.id == result.id else { return }
                let changedDuringRun = self.draftGeneration != draftGenerationAtStart
                let laterDraft = self.draft
                self.adopt(result)
                self.updateList(result)
                if changedDuringRun {
                    self.draft = laterDraft
                } else if draftAtStart.trimmingCharacters(in: .whitespacesAndNewlines) == question {
                    self.draft = result.draft
                }
            } catch {
                guard self.runGeneration == generation, self.conversation?.id == latest.id else { return }
                self.errorMessage = error.localizedDescription
                // The service may have persisted a terminal message before
                // reporting an error. Re-read it before a retry.
                if let refreshed = try? await service.conversation(id: latest.id),
                    self.runGeneration == generation, self.conversation?.id == latest.id
                {
                    let laterDraft = self.draft
                    let changedDuringRun = self.draftGeneration != draftGenerationAtStart
                    self.adopt(refreshed)
                    self.updateList(refreshed)
                    if changedDuringRun {
                        self.draft = laterDraft
                    }
                } else if self.draftGeneration == draftGenerationAtStart {
                    self.draft = draftAtStart
                }
            }
            guard self.runGeneration == generation else { return }
            self.isSending = false
            self.isStopping = false
            self.activity = nil
            self.streamingText = ""
            self.pendingQuestion = nil
            self.sendTask = nil
            await self.flushDraft()
        }
    }

    private func accept(_ event: AskAgentEvent, generation: Int, conversationID: UUID) {
        guard runGeneration == generation, conversation?.id == conversationID else { return }
        switch event {
        case .activity(let description): activity = description
        case .text(let delta): streamingText += delta
        }
    }

    private func refreshActiveSources(for current: AskConversation) async {
        guard let service else { return }
        let ids = current.activeSection?.sourceIDs ?? []
        guard !ids.isEmpty else { activeSourceSnapshots = []; return }
        do {
            let snapshots = try await service.sourceSnapshots(ids: ids)
            guard conversation?.id == current.id,
                conversation?.activeSection?.id == current.activeSection?.id
            else { return }
            activeSourceSnapshots = snapshots
        } catch {
            guard conversation?.id == current.id else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func refreshSelectedSourceSnapshots() async {
        guard let service else { return }
        let ids = pickerSelection
        guard !ids.isEmpty else { selectedSourceSnapshots = []; return }
        do {
            let snapshots = try await service.sourceSnapshots(ids: ids)
            guard showingSourcePicker, pickerSelection == ids else { return }
            selectedSourceSnapshots = snapshots
        } catch {
            sourcePickerError = error.localizedDescription
        }
    }

    private func adopt(_ loaded: AskConversation) {
        conversation = loaded
        draft = loaded.draft
        savedDraftAtConflict = nil
        streamingText = ""
        activity = nil
        updateList(loaded)
    }

    public func useSavedDraft() {
        guard let savedDraftAtConflict else { return }
        draft = savedDraftAtConflict
        self.savedDraftAtConflict = nil
    }

    public func keepMyDraft() async {
        guard savedDraftAtConflict != nil, let service, let current = conversation else { return }
        let localDraft = draft
        do {
            let saved = try await service.saveDraft(
                id: current.id, draft: localDraft, expectedRevision: current.revision
            )
            guard conversation?.id == current.id,
                conversation?.revision == current.revision
            else { return }
            conversation = saved
            updateList(saved)
            savedDraftAtConflict = nil
            if draft != localDraft { await flushDraft() }
        } catch {
            errorMessage = "Could not save draft: \(error.localizedDescription)"
        }
    }

    private func updateList(_ value: AskConversation) {
        if let index = conversations.firstIndex(where: { $0.id == value.id }) {
            conversations[index] = value
        } else {
            conversations.insert(value, at: 0)
        }
        conversations.sort { $0.updatedAt > $1.updatedAt }
    }

    private func blockWhileDraftConflicted() -> Bool {
        guard savedDraftAtConflict != nil else { return false }
        errorMessage = "Choose which draft to keep before continuing."
        return true
    }
}

private enum AskUIError: LocalizedError {
    case conversationUnavailable
    var errorDescription: String? { "This conversation is no longer available." }
}
