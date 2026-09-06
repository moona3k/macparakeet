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
    public private(set) var classifications: [UUID: MeetingClassification] = [:]
    public private(set) var updatingTranscriptionIDs: Set<UUID> = []
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
                    (
                        try typeRepository.fetchAll(includeArchived: false),
                        try labelRepository.fetchAll(includeArchived: false)
                    )
                }.value
                guard let self, !Task.isCancelled else { return }
                self.meetingTypes = result.0
                self.meetingLabels = result.1
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
    public func createMeetingLabel(named name: String, assigningTo transcriptionID: UUID? = nil) -> Task<Void, Never> {
        guard let labelRepository else { return Task {} }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return Task {} }
        let label = MeetingLabel(name: normalized, sortOrder: meetingLabels.count)

        return Task { @MainActor [weak self, labelRepository] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try labelRepository.save(label)
                }.value
                guard let self else { return }
                await self.loadOptions().value
                if let transcriptionID {
                    await self.toggleLabel(label.id, for: transcriptionID).value
                }
            } catch {
                self?.report(error, action: "create meeting label")
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
    public func archiveMeetingLabel(_ id: UUID) -> Task<Void, Never> {
        guard let labelRepository else { return Task {} }
        return Task { @MainActor [weak self, labelRepository] in
            do {
                try await Task.detached(priority: .userInitiated) {
                    try labelRepository.setArchived(id: id, isArchived: true)
                }.value
                guard let self else { return }
                await self.loadOptions().value
            } catch {
                self?.report(error, action: "archive meeting label")
            }
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
                desiredClassifications[transcriptionID] = nil
                finishMutations(for: transcriptionID)
                return
            } catch {
                guard mutationGenerations[transcriptionID] == generation else {
                    continue
                }
                if let authoritative = try? service.classification(for: transcriptionID) {
                    classifications[transcriptionID] = authoritative
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
    }

    private func report(_ error: Error, action: String) {
        logger.error("Failed to \(action, privacy: .public): \(error.localizedDescription, privacy: .private)")
        errorMessage = "Unable to \(action): \(error.localizedDescription)"
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
