import Foundation
import MacParakeetCore
import os

/// Shared presentation state for meeting types and labels. The database and
/// artifact-refresh rules stay behind Core repositories/services; views only
/// consume resolved classifications and issue intent-level mutations here.
@MainActor @Observable
public final class MeetingClassificationViewModel {
    public private(set) var meetingTypes: [MeetingType] = []
    public private(set) var meetingLabels: [MeetingLabel] = []
    public private(set) var managedMeetingLabels: [MeetingLabel] = []
    public private(set) var classifications: [UUID: MeetingClassification] = [:]
    /// Advances only after an authoritative read, never for optimistic labels.
    /// Database-backed consumers refresh on this signal after writes settle,
    /// including successful clears and rollback to the persisted selection.
    public private(set) var classificationRevisions: [UUID: Int] = [:]
    public private(set) var updatingTranscriptionIDs: Set<UUID> = []
    public private(set) var isUpdatingLabels = false
    public private(set) var isLoadingOptions = false
    public var errorMessage: String?

    @ObservationIgnored private var typeRepository: (any MeetingTypeRepositoryProtocol)?
    @ObservationIgnored private var labelRepository: (any MeetingLabelRepositoryProtocol)?
    @ObservationIgnored private var service: (any MeetingClassificationServiceProtocol)?
    @ObservationIgnored private var optionsTask: Task<Void, Never>?
    @ObservationIgnored private var classificationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var classificationLoadGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var mutationTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var mutationGenerations: [UUID: Int] = [:]
    @ObservationIgnored private var pendingClassificationRefreshes: Set<UUID> = []
    @ObservationIgnored private var desiredClassifications: [UUID: DesiredClassification] = [:]
    @ObservationIgnored private var initialMutationIntents: [UUID: [ClassificationMutation]] = [:]
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.macparakeet.viewmodels",
        category: "MeetingClassification"
    )

    public init() {}

    deinit {
        optionsTask?.cancel()
        for task in classificationTasks.values {
            task.cancel()
        }
        for task in mutationTasks.values {
            task.cancel()
        }
    }

    public func configure(
        typeRepository: any MeetingTypeRepositoryProtocol,
        labelRepository: any MeetingLabelRepositoryProtocol,
        service: any MeetingClassificationServiceProtocol
    ) {
        self.typeRepository = typeRepository
        self.labelRepository = labelRepository
        self.service = service
    }

    @discardableResult
    public func loadOptions() -> Task<Void, Never> {
        optionsTask?.cancel()
        guard let typeRepository, let labelRepository else {
            isLoadingOptions = false
            return Task {}
        }

        isLoadingOptions = true
        errorMessage = nil
        let task = Task { @MainActor [weak self, typeRepository, labelRepository] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let allLabels = try labelRepository.fetchAll(includeArchived: true)
                    return (
                        try typeRepository.fetchAll(includeArchived: false),
                        allLabels.filter { !$0.isArchived },
                        allLabels
                    )
                }.value
                guard let self, !Task.isCancelled else { return }
                self.meetingTypes = result.0
                self.meetingLabels = result.1
                self.managedMeetingLabels = result.2
                self.isLoadingOptions = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingOptions = false
                self.report(error, action: "load meeting classification choices")
            }
        }
        optionsTask = task
        return task
    }

    public func classification(for transcriptionID: UUID) -> MeetingClassification? {
        classifications[transcriptionID]
    }

    @discardableResult
    public func loadClassification(for transcriptionID: UUID) -> Task<Void, Never> {
        classificationTasks[transcriptionID]?.cancel()
        guard let service else { return Task {} }
        let generation = (classificationLoadGenerations[transcriptionID] ?? 0) + 1
        classificationLoadGenerations[transcriptionID] = generation
        let task = Task { @MainActor [weak self, service] in
            do {
                let classification = try await Task.detached(priority: .utility) {
                    try service.classification(for: transcriptionID)
                }.value
                guard let self, !Task.isCancelled,
                    self.classificationLoadGenerations[transcriptionID] == generation
                else { return }
                self.classificationTasks[transcriptionID] = nil
                guard self.mutationTasks[transcriptionID] == nil else { return }
                self.classifications[transcriptionID] = classification
                self.classificationRevisions[transcriptionID, default: 0] += 1
            } catch {
                guard let self, !Task.isCancelled,
                    self.classificationLoadGenerations[transcriptionID] == generation
                else { return }
                self.classificationTasks[transcriptionID] = nil
                self.report(error, action: "load meeting classification")
            }
        }
        classificationTasks[transcriptionID] = task
        return task
    }

    /// Refresh every loaded meeting, including IDs already in the cache.
    /// Classification can change through the CLI or another app surface, and
    /// label-only changes do not necessarily change the Transcription value
    /// held by this view model.
    @discardableResult
    public func loadClassifications(for transcriptions: [Transcription]) -> [Task<Void, Never>] {
        transcriptions
            .map { loadClassification(for: $0.id) }
    }

    @discardableResult
    public func setMeetingType(_ meetingTypeID: UUID?, for transcriptionID: UUID) -> Task<Void, Never> {
        enqueue(.setMeetingType(meetingTypeID), for: transcriptionID)
    }

    @discardableResult
    public func toggleLabel(_ labelID: UUID, for transcriptionID: UUID) -> Task<Void, Never> {
        enqueue(.toggleLabel(labelID), for: transcriptionID)
    }

    @discardableResult
    public func createMeetingType(named name: String, assigningTo transcriptionID: UUID? = nil) -> Task<Void, Never> {
        guard let typeRepository else { return Task {} }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return Task {} }
        let meetingType = MeetingType(name: normalized, sortOrder: meetingTypes.count)

        return Task { @MainActor [weak self, typeRepository] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try typeRepository.save(meetingType)
                }.value
                guard let self else { return }
                await self.loadOptions().value
                if let transcriptionID {
                    await self.setMeetingType(meetingType.id, for: transcriptionID).value
                }
            } catch {
                self?.report(error, action: "create meeting type")
            }
        }
    }

    @discardableResult
    public func createMeetingLabel(named name: String, assigningTo transcriptionID: UUID? = nil) -> Task<Bool, Never> {
        guard !isUpdatingLabels else { return Task { false } }
        guard let labelRepository else {
            errorMessage = "Label management is unavailable."
            return Task { false }
        }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            errorMessage = "A label name is required."
            return Task { false }
        }
        let label = MeetingLabel(name: normalized, sortOrder: meetingLabels.count)

        isUpdatingLabels = true
        errorMessage = nil
        return Task { @MainActor [weak self, labelRepository] in
            defer { self?.isUpdatingLabels = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let existing = try labelRepository.fetchAll(includeArchived: true)
                    guard
                        !existing.contains(where: {
                            $0.name.compare(
                                normalized,
                                options: [.caseInsensitive, .diacriticInsensitive]
                            ) == .orderedSame
                        })
                    else {
                        throw MeetingLabelManagementError.duplicateName(normalized)
                    }
                    try labelRepository.save(label)
                }.value
                guard let self else { return false }
                await self.loadOptions().value
                if let transcriptionID {
                    await self.toggleLabel(label.id, for: transcriptionID).value
                }
                return true
            } catch {
                self?.report(error, action: "create meeting label")
                return false
            }
        }
    }

    @discardableResult
    public func archiveMeetingType(_ id: UUID) -> Task<Void, Never> {
        guard let typeRepository else { return Task {} }
        return Task { @MainActor [weak self, typeRepository] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try typeRepository.setArchived(id: id, isArchived: true)
                }.value
                guard let self else { return }
                await self.loadOptions().value
            } catch {
                self?.report(error, action: "archive meeting type")
            }
        }
    }

    @discardableResult
    public func updateMeetingLabel(
        _ id: UUID,
        with edit: MeetingLabelEdit
    ) -> Task<Bool, Never> {
        guard !isUpdatingLabels else { return Task { false } }
        guard let labelRepository else {
            errorMessage = "Label management is unavailable."
            return Task { false }
        }
        isUpdatingLabels = true
        errorMessage = nil
        return Task { @MainActor [weak self, labelRepository] in
            defer { self?.isUpdatingLabels = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    guard var label = try labelRepository.fetch(id: id) else {
                        throw MeetingLabelManagementError.missingLabel
                    }
                    switch edit {
                    case .rename(let name):
                        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !normalizedName.isEmpty else {
                            throw MeetingLabelManagementError.emptyName
                        }
                        let existing = try labelRepository.fetchAll(includeArchived: true)
                        guard
                            !existing.contains(where: {
                                $0.id != id
                                    && $0.name.compare(
                                        normalizedName,
                                        options: [.caseInsensitive, .diacriticInsensitive]
                                    ) == .orderedSame
                            })
                        else {
                            throw MeetingLabelManagementError.duplicateName(normalizedName)
                        }
                        label.name = normalizedName
                    case .color(let colorToken):
                        label.colorToken = colorToken
                    }
                    label.updatedAt = Date()
                    try labelRepository.save(label)
                }.value
                guard let self else { return false }
                await self.reloadLabelsAndClassifications()
                return true
            } catch {
                self?.report(error, action: "save label")
                return false
            }
        }
    }

    @discardableResult
    public func setMeetingLabelArchived(_ id: UUID, isArchived: Bool) -> Task<Bool, Never> {
        guard !isUpdatingLabels else { return Task { false } }
        guard let labelRepository else {
            errorMessage = "Label management is unavailable."
            return Task { false }
        }
        isUpdatingLabels = true
        errorMessage = nil
        return Task { @MainActor [weak self, labelRepository] in
            defer { self?.isUpdatingLabels = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    guard try labelRepository.fetch(id: id) != nil else {
                        throw MeetingLabelManagementError.missingLabel
                    }
                    try labelRepository.setArchived(id: id, isArchived: isArchived)
                }.value
                guard let self else { return false }
                await self.reloadLabelsAndClassifications()
                return true
            } catch {
                self?.report(error, action: isArchived ? "archive label" : "restore label")
                return false
            }
        }
    }

    @discardableResult
    public func archiveMeetingLabel(_ id: UUID) -> Task<Void, Never> {
        let task = setMeetingLabelArchived(id, isArchived: true)
        return Task {
            _ = await task.value
        }
    }

    public func clearError() {
        errorMessage = nil
    }

    private func enqueue(
        _ intent: ClassificationMutation,
        for transcriptionID: UUID
    ) -> Task<Void, Never> {
        guard let service else { return Task {} }
        if var desired = desiredClassifications[transcriptionID]
            ?? classifications[transcriptionID].map(DesiredClassification.init)
        {
            intent.apply(to: &desired)
            return enqueue(desired, for: transcriptionID)
        }

        // A missing cache entry is unknown, not an empty classification. Keep
        // ordered click intents until a database read provides the baseline.
        initialMutationIntents[transcriptionID, default: []].append(intent)
        if let task = mutationTasks[transcriptionID] {
            return task
        }
        classificationLoadGenerations[transcriptionID, default: 0] += 1
        classificationTasks[transcriptionID]?.cancel()
        classificationTasks[transcriptionID] = nil
        updatingTranscriptionIDs.insert(transcriptionID)
        errorMessage = nil

        let task = Task { @MainActor [weak self, service] in
            do {
                let baseline = try await Task.detached(priority: .userInitiated) {
                    try service.classification(for: transcriptionID)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.classifications[transcriptionID] = baseline
                var desired = DesiredClassification(baseline)
                for intent in self.initialMutationIntents.removeValue(forKey: transcriptionID) ?? [] {
                    intent.apply(to: &desired)
                }
                self.desiredClassifications[transcriptionID] = desired
                self.mutationGenerations[transcriptionID, default: 0] += 1
                self.publishOptimistic(desired, for: transcriptionID)
                await self.drainMutations(for: transcriptionID)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.initialMutationIntents[transcriptionID] = nil
                self.report(error, action: "load meeting classification")
                self.finishMutations(for: transcriptionID)
            }
        }
        mutationTasks[transcriptionID] = task
        return task
    }

    private func enqueue(
        _ desired: DesiredClassification,
        for transcriptionID: UUID
    ) -> Task<Void, Never> {
        desiredClassifications[transcriptionID] = desired
        mutationGenerations[transcriptionID, default: 0] += 1
        classificationLoadGenerations[transcriptionID, default: 0] += 1
        classificationTasks[transcriptionID]?.cancel()
        classificationTasks[transcriptionID] = nil
        updatingTranscriptionIDs.insert(transcriptionID)
        errorMessage = nil
        publishOptimistic(desired, for: transcriptionID)

        if let task = mutationTasks[transcriptionID] {
            return task
        }

        let task = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.drainMutations(for: transcriptionID)
        }
        mutationTasks[transcriptionID] = task
        return task
    }

    private func drainMutations(for transcriptionID: UUID) async {
        guard let service else {
            finishMutations(for: transcriptionID)
            return
        }

        while !Task.isCancelled, let desired = desiredClassifications[transcriptionID] {
            let generation = mutationGenerations[transcriptionID] ?? 0
            do {
                try await service.update(
                    meetingTypeId: desired.meetingTypeID,
                    labelIds: desired.labelIDs,
                    for: transcriptionID
                )
                let authoritative = try await Task.detached(priority: .utility) {
                    try service.classification(for: transcriptionID)
                }.value

                guard mutationGenerations[transcriptionID] == generation else {
                    continue
                }
                classifications[transcriptionID] = authoritative
                classificationRevisions[transcriptionID, default: 0] += 1
                desiredClassifications[transcriptionID] = nil
                finishMutations(for: transcriptionID)
                return
            } catch {
                guard mutationGenerations[transcriptionID] == generation else {
                    continue
                }
                if let authoritative = try? service.classification(for: transcriptionID) {
                    classifications[transcriptionID] = authoritative
                    classificationRevisions[transcriptionID, default: 0] += 1
                }
                desiredClassifications[transcriptionID] = nil
                report(error, action: "update meeting classification")
                finishMutations(for: transcriptionID)
                return
            }
        }
        finishMutations(for: transcriptionID)
    }

    private func publishOptimistic(_ desired: DesiredClassification, for transcriptionID: UUID) {
        let current = classifications[transcriptionID]
        let meetingType = desired.meetingTypeID.flatMap { id in
            meetingTypes.first { $0.id == id }
                ?? (current?.meetingType?.id == id ? current?.meetingType : nil)
        }
        var knownLabels = Dictionary(uniqueKeysWithValues: meetingLabels.map { ($0.id, $0) })
        for label in current?.labels ?? [] {
            knownLabels[label.id] = label
        }
        let labels = desired.labelIDs.compactMap { knownLabels[$0] }.sorted {
            if $0.sortOrder == $1.sortOrder {
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            return $0.sortOrder < $1.sortOrder
        }
        classifications[transcriptionID] = MeetingClassification(
            meetingType: meetingType,
            labels: labels
        )
    }

    private func finishMutations(for transcriptionID: UUID) {
        mutationTasks[transcriptionID] = nil
        updatingTranscriptionIDs.remove(transcriptionID)
        guard pendingClassificationRefreshes.remove(transcriptionID) != nil else { return }
        loadClassification(for: transcriptionID)
    }

    private func reloadLabelsAndClassifications() async {
        await loadOptions().value
        guard errorMessage == nil else { return }
        let loadedIDs = Set(classifications.keys)
        pendingClassificationRefreshes.formUnion(loadedIDs.filter { mutationTasks[$0] != nil })
        let stableIDs = loadedIDs.filter { mutationTasks[$0] == nil }
        for transcriptionID in stableIDs {
            await loadClassification(for: transcriptionID).value
        }
    }

    private func report(_ error: Error, action: String) {
        logger.error("Failed to \(action, privacy: .public): \(error.localizedDescription, privacy: .private)")
        errorMessage = "Unable to \(action): \(error.localizedDescription)"
    }
}

public enum MeetingLabelEdit: Sendable {
    case rename(String)
    case color(String?)
}

private enum MeetingLabelManagementError: LocalizedError, Sendable {
    case emptyName
    case duplicateName(String)
    case missingLabel

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "A label name is required."
        case .duplicateName(let name):
            return "A label named '\(name)' already exists."
        case .missingLabel:
            return "This label no longer exists."
        }
    }
}

private struct DesiredClassification: Sendable, Equatable {
    var meetingTypeID: UUID?
    var labelIDs: Set<UUID>

    init(_ classification: MeetingClassification) {
        meetingTypeID = classification.meetingType?.id
        labelIDs = Set(classification.labels.map(\.id))
    }
}

private enum ClassificationMutation {
    case setMeetingType(UUID?)
    case toggleLabel(UUID)

    func apply(to desired: inout DesiredClassification) {
        switch self {
        case .setMeetingType(let id):
            desired.meetingTypeID = id
        case .toggleLabel(let id):
            if desired.labelIDs.contains(id) {
                desired.labelIDs.remove(id)
            } else {
                desired.labelIDs.insert(id)
            }
        }
    }
}
