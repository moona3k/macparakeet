import Foundation
import MacParakeetCore

/// One app-owned split task. Closing a sheet does not cancel processing;
/// durable Core receipts recover the same recordings after interruption.
@MainActor
@Observable
public final class MeetingSplitViewModel {
    public struct EditingState: Equatable {
        public var sourceId: UUID
        public var sourceTitle: String
        public var totalDurationMs: Int
        public var sourceIdentity: String
        public var cutPointsMs: [Int]
        public var partTitles: [String]
    }

    public enum LoadState: Equatable {
        case idle, loading, ready
        case failed(String)
    }

    public private(set) var loadState: LoadState = .idle
    public private(set) var editing: EditingState?
    public private(set) var boundaryText: [String] = []
    public private(set) var validationError: String?
    public private(set) var resumableOperation: MeetingSplitOperation?
    public private(set) var activeSourceId: UUID?
    public private(set) var activeSourceTitle = ""
    public private(set) var progress: MeetingSplitProcessingProgress?
    public private(set) var completedOperation: MeetingSplitOperation?
    public private(set) var processingErrorMessage: String?
    public private(set) var presentationNotice: String?
    public private(set) var isExternallyOwned = false
    public private(set) var isStopping = false
    public private(set) var availableChildIds: Set<UUID> = []

    public var isProcessingActive: Bool { processingTask != nil }
    public var operation: MeetingSplitOperation? { completedOperation ?? resumableOperation }
    public var canContinue: Bool {
        guard !isProcessingActive, !isExternallyOwned, let operation else { return false }
        return operation.status == .preparing || (operation.status == .committed
            && operation.childProgress.contains {
                $0.stage != .automationCompleted && availableChildIds.contains($0.childId)
            })
    }
    public var canStartNewSplit: Bool {
        loadState == .ready && operation?.status == .committed
            && !isProcessingActive && !isExternallyOwned
    }
    public var canSubmit: Bool {
        loadState == .ready && editing != nil && validationError == nil
            && !isProcessingActive && operation == nil && !isExternallyOwned
    }

    private var service: (any MeetingSplitServicing)?
    private var recordingLookup: @Sendable (UUID) throws -> Transcription?
    private var processingTask: Task<Void, Never>?
    private var presentationGeneration = UUID()
    private var processingGeneration = UUID()
    private var creationKey = UUID().uuidString

    public init(
        service: (any MeetingSplitServicing)? = nil,
        recordingLookup: @escaping @Sendable (UUID) throws -> Transcription? = { _ in nil }
    ) {
        self.service = service
        self.recordingLookup = recordingLookup
    }

    public func configure(
        service: any MeetingSplitServicing,
        recordingLookup: @escaping @Sendable (UUID) throws -> Transcription? = { _ in nil }
    ) {
        self.service = service
        self.recordingLookup = recordingLookup
    }

    public func present(sourceId: UUID, sourceTitle: String, operationId: UUID? = nil) async {
        await present(sourceId: sourceId, sourceTitle: sourceTitle, operationId: operationId, discoverExisting: true)
    }

    /// Leaves the receipt and its recordings saved while editing a fresh request.
    public func startNewSplit() async {
        guard canStartNewSplit, let operation else { return }
        await present(sourceId: operation.sourceId, sourceTitle: activeSourceTitle,
                      operationId: nil, discoverExisting: false)
    }

    private func present(sourceId: UUID, sourceTitle: String, operationId: UUID?, discoverExisting: Bool) async {
        if isProcessingActive {
            presentationNotice = activeSourceId == sourceId ? nil
                : "Finish or stop the split for “\(activeSourceTitle)” before starting another."
            return
        }
        guard let service else {
            loadState = .failed("Split and transcribe is not available right now.")
            return
        }
        acknowledgeFinishedProcessing()
        editing = nil
        boundaryText = []
        activeSourceTitle = sourceTitle
        let generation = UUID()
        presentationGeneration = generation
        loadState = .loading
        presentationNotice = nil
        processingErrorMessage = nil
        isExternallyOwned = false

        do {
            let lookup = recordingLookup
            let existing = try await Task.detached {
                if let operationId { return try service.operation(id: operationId) }
                guard discoverExisting else { return nil as MeetingSplitOperation? }
                return try service.operations(sourceId: sourceId)
                    .filter {
                        if $0.status == .preparing { return true }
                        guard $0.status == .committed else { return false }
                        return try $0.childProgress.contains {
                            guard $0.stage != .automationCompleted else { return false }
                            return try lookup($0.childId) != nil
                        }
                    }
                    .max { $0.createdAt < $1.createdAt }
            }.value
            guard presentationGeneration == generation else { return }
            if let existing {
                activeSourceId = existing.sourceId
                activeSourceTitle = sourceTitle
                completedOperation = nil
                resumableOperation = existing
                editing = nil
                try await refreshAvailability(existing)
                let ownership = try await Task.detached {
                    try service.operationOwnership(operationId: existing.id)
                }.value
                guard presentationGeneration == generation else { return }
                isExternallyOwned = ownership == .activelyOwned
                loadState = .ready
                return
            }
            guard operationId == nil else { throw MeetingSplitRepositoryError.operationNotFound }
            let preview = try await service.preview(sourceId: sourceId, cutPointsMs: [])
            guard presentationGeneration == generation else { return }
            acknowledgeFinishedProcessing()
            activeSourceTitle = preview.sourceTitle
            editing = EditingState(
                sourceId: sourceId, sourceTitle: preview.sourceTitle,
                totalDurationMs: preview.totalDurationMs, sourceIdentity: preview.sourceIdentity,
                cutPointsMs: [max(1, preview.totalDurationMs / 2)],
                partTitles: ["\(preview.sourceTitle) — Part 1", "\(preview.sourceTitle) — Part 2"]
            )
            creationKey = UUID().uuidString
            boundaryText = editing?.cutPointsMs.map(MeetingSplitTimecode.format) ?? []
            loadState = .ready
            revalidate()
        } catch {
            guard presentationGeneration == generation else { return }
            loadState = .failed(error.localizedDescription)
            processingErrorMessage = error.localizedDescription
            // A failed ownership probe must not advertise an available retry.
            if operation != nil { isExternallyOwned = true }
        }
    }

    public func addSplit() {
        guard var state = editing, validationError == nil, !isProcessingActive else { return }
        let boundaries = [0] + state.cutPointsMs + [state.totalDurationMs]
        let index = (0..<(boundaries.count - 1)).max {
            let left = boundaries[$0 + 1] - boundaries[$0]
            let right = boundaries[$1 + 1] - boundaries[$1]
            return left == right ? $0 > $1 : left < right
        } ?? 0
        let span = boundaries[index + 1] - boundaries[index]
        guard span >= 2 else { return }
        for part in state.partTitles.indices where part > index {
            if state.partTitles[part] == "\(state.sourceTitle) — Part \(part + 1)" {
                state.partTitles[part] = "\(state.sourceTitle) — Part \(part + 2)"
            }
        }
        state.cutPointsMs.insert(boundaries[index] + span / 2, at: index)
        state.partTitles.insert("\(state.sourceTitle) — Part \(index + 2)", at: index + 1)
        editing = state
        boundaryText = state.cutPointsMs.map(MeetingSplitTimecode.format)
        revalidate()
    }

    public func removeCut(at index: Int) {
        guard var state = editing, !isProcessingActive,
              state.cutPointsMs.count > 1, state.cutPointsMs.indices.contains(index) else { return }
        for part in state.partTitles.indices where part > index + 1 {
            if state.partTitles[part] == "\(state.sourceTitle) — Part \(part + 1)" {
                state.partTitles[part] = "\(state.sourceTitle) — Part \(part)"
            }
        }
        state.cutPointsMs.remove(at: index)
        state.partTitles.remove(at: index + 1)
        editing = state
        boundaryText.remove(at: index)
        revalidate()
    }

    public func updateCut(at index: Int, toMs value: Int) {
        guard var state = editing, !isProcessingActive, state.cutPointsMs.indices.contains(index) else { return }
        state.cutPointsMs[index] = value
        editing = state
        boundaryText[index] = MeetingSplitTimecode.format(value)
        revalidate()
    }

    public func updateCutText(at index: Int, to text: String) {
        guard var state = editing, !isProcessingActive, boundaryText.indices.contains(index) else { return }
        boundaryText[index] = text
        if let milliseconds = MeetingSplitTimecode.parse(text) {
            state.cutPointsMs[index] = milliseconds
            editing = state
        }
        revalidate()
    }

    public func updateTitle(at index: Int, to title: String) {
        guard var state = editing, !isProcessingActive, state.partTitles.indices.contains(index) else { return }
        state.partTitles[index] = title
        editing = state
        revalidate()
    }

    private func revalidate() {
        guard let state = editing else { validationError = nil; return }
        guard boundaryText.allSatisfy({ MeetingSplitTimecode.parse($0) != nil }) else {
            validationError = "Enter each split time as m:ss or h:mm:ss."
            return
        }
        do {
            _ = try MeetingSplitGeometry.ranges(durationMs: state.totalDurationMs, cutPointsMs: state.cutPointsMs)
            validationError = state.partTitles.allSatisfy {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            } ? nil : "Every part needs a title."
        } catch {
            validationError = error.localizedDescription
        }
    }

    @discardableResult
    public func submit() -> Bool {
        guard let service, let state = editing, canSubmit else { return false }
        let key = creationKey
        beginProcessing(sourceId: state.sourceId, sourceTitle: state.sourceTitle, key: key) { callback in
            try await service.createAndProcess(
                idempotencyKey: key, sourceId: state.sourceId,
                cutPointsMs: state.cutPointsMs, titles: state.partTitles,
                expectedSourceIdentity: state.sourceIdentity, onProgress: callback
            )
        }
        return true
    }

    /// Both interrupted preparation and published parts resume from the
    /// frozen request. Neither path generates another set of meeting IDs.
    @discardableResult
    public func resume(operationId: UUID, sourceTitle: String) -> Bool {
        guard let service, canContinue,
              let saved = operation, saved.id == operationId, saved.status != .discarded else { return false }
        beginProcessing(sourceId: saved.sourceId, sourceTitle: sourceTitle, key: saved.idempotencyKey) { callback in
            if saved.status == .preparing {
                return try await service.createAndProcess(
                    idempotencyKey: saved.idempotencyKey, sourceId: saved.sourceId,
                    cutPointsMs: saved.request.children.dropLast().map(\.endMs),
                    titles: saved.request.children.map(\.title),
                    expectedSourceIdentity: saved.request.expectedSourceIdentity, onProgress: callback
                )
            }
            return try await service.resumeProcessing(operationId: saved.id, onProgress: callback)
        }
        return true
    }

    private func beginProcessing(
        sourceId: UUID, sourceTitle: String, key: String,
        run: @escaping @Sendable (@escaping @Sendable (MeetingSplitProcessingProgress) -> Void) async throws -> MeetingSplitOperation
    ) {
        activeSourceId = sourceId
        activeSourceTitle = sourceTitle
        progress = nil
        resumableOperation = operation
        completedOperation = nil
        processingErrorMessage = nil
        isStopping = false
        let generation = UUID()
        processingGeneration = generation
        processingTask = Task { [weak self] in
            guard let self else { return }
            let callback: @Sendable (MeetingSplitProcessingProgress) -> Void = { [weak self] event in
                Task { @MainActor in
                    guard let self, self.processingGeneration == generation, self.isProcessingActive else { return }
                    self.progress = event
                    await self.refreshReceipt(sourceId: sourceId, key: key)
                }
            }
            do {
                let result = try await run(callback)
                completedOperation = result
                resumableOperation = nil
                try await refreshAvailability(result)
                if result.childProgress.contains(where: { $0.outcome == .failed }) {
                    processingErrorMessage = "Some parts need another attempt. Saved audio and completed work are kept."
                }
            } catch is CancellationError {
                await refreshReceipt(sourceId: sourceId, key: key)
            } catch {
                processingErrorMessage = error.localizedDescription
                await refreshReceipt(sourceId: sourceId, key: key)
            }
            processingGeneration = UUID() // Ignore already-enqueued progress callbacks.
            progress = nil
            processingTask = nil
            isStopping = false
        }
    }

    private func refreshReceipt(sourceId: UUID, key: String) async {
        guard let service else { return }
        let generation = processingGeneration
        do {
            let receipt = try await Task.detached {
                try service.operations(sourceId: sourceId).first { $0.idempotencyKey == key }
            }.value
            guard processingGeneration == generation, let receipt else { return }
            if completedOperation == nil { resumableOperation = receipt }
            try await refreshAvailability(receipt)
        } catch {
            if processingErrorMessage == nil { processingErrorMessage = error.localizedDescription }
        }
    }

    private func refreshAvailability(_ receipt: MeetingSplitOperation) async throws {
        let lookup = recordingLookup
        let presentation = presentationGeneration
        let processing = processingGeneration
        let available = try await Task.detached {
            try Set(receipt.childIds.filter { try lookup($0) != nil })
        }.value
        guard presentation == presentationGeneration, processing == processingGeneration else { return }
        availableChildIds = available
    }

    public func savedRecording(id: UUID) async throws -> Transcription? {
        let lookup = recordingLookup
        return try await Task.detached { try lookup(id) }.value
    }

    public func stop() {
        guard isProcessingActive else { return }
        isStopping = true
        processingTask?.cancel()
    }

    public func discardPreparing(operationId: UUID) async throws {
        guard let service, !isProcessingActive, !isExternallyOwned else { return }
        _ = try await Task.detached { try service.discard(operationId: operationId) }.value
        acknowledgeFinishedProcessing()
        editing = nil
    }

    public func acknowledgeFinishedProcessing() {
        guard !isProcessingActive else { return }
        activeSourceId = nil
        completedOperation = nil
        resumableOperation = nil
        processingErrorMessage = nil
        progress = nil
        isExternallyOwned = false
        isStopping = false
        availableChildIds = []
        creationKey = UUID().uuidString
    }
}
