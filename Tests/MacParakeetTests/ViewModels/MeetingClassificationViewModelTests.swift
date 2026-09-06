import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class MeetingClassificationViewModelTests: XCTestCase {
    func testLoadsActiveOptionsAndClassification() async {
        let customer = MeetingType(name: "Customer")
        let important = MeetingLabel(name: "Important")
        let typeRepo = MeetingTypeRepositoryMock(items: [customer])
        let labelRepo = MeetingLabelRepositoryMock(items: [important])
        let service = MeetingClassificationServiceMock()
        let transcriptionID = UUID()
        service.values[transcriptionID] = MeetingClassification(
            meetingType: customer,
            labels: [important]
        )
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: typeRepo,
            labelRepository: labelRepo,
            service: service
        )

        await viewModel.loadOptions().value
        await viewModel.loadClassification(for: transcriptionID).value

        XCTAssertEqual(viewModel.meetingTypes, [customer])
        XCTAssertEqual(viewModel.meetingLabels, [important])
        XCTAssertEqual(
            viewModel.classification(for: transcriptionID),
            MeetingClassification(meetingType: customer, labels: [important])
        )
    }

    func testSetMeetingTypeRefreshesResolvedClassification() async {
        let customer = MeetingType(name: "Customer")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableTypes = [customer.id: customer]
        service.values[transcriptionID] = MeetingClassification(meetingType: nil, labels: [])
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: [customer]),
            labelRepository: MeetingLabelRepositoryMock(items: []),
            service: service
        )
        await viewModel.loadClassification(for: transcriptionID).value

        await viewModel.setMeetingType(customer.id, for: transcriptionID).value

        XCTAssertEqual(service.updateCalls.count, 1)
        XCTAssertEqual(service.updateCalls.first?.transcriptionID, transcriptionID)
        XCTAssertEqual(service.updateCalls.first?.meetingTypeID, customer.id)
        XCTAssertEqual(viewModel.classification(for: transcriptionID)?.meetingType, customer)
        XCTAssertFalse(viewModel.updatingTranscriptionIDs.contains(transcriptionID))
    }

    func testToggleLabelPreservesOtherLabels() async {
        let customer = MeetingLabel(name: "Customer")
        let important = MeetingLabel(name: "Important")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableLabels = [customer.id: customer, important.id: important]
        service.values[transcriptionID] = MeetingClassification(meetingType: nil, labels: [customer])
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: []),
            labelRepository: MeetingLabelRepositoryMock(items: [customer, important]),
            service: service
        )
        await viewModel.loadClassification(for: transcriptionID).value

        await viewModel.toggleLabel(important.id, for: transcriptionID).value

        XCTAssertEqual(service.updateCalls.last?.transcriptionID, transcriptionID)
        XCTAssertEqual(service.updateCalls.last?.labelIDs, [customer.id, important.id])
        XCTAssertEqual(
            Set(viewModel.classification(for: transcriptionID)?.labels.map(\.id) ?? []),
            [customer.id, important.id]
        )
    }

    func testCreateLabelAssignsItToMeeting() async {
        let transcriptionID = UUID()
        let labelRepo = MeetingLabelRepositoryMock(items: [])
        let service = MeetingClassificationServiceMock()
        service.values[transcriptionID] = MeetingClassification(meetingType: nil, labels: [])
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: []),
            labelRepository: labelRepo,
            service: service
        )
        await viewModel.loadClassification(for: transcriptionID).value

        await viewModel.createMeetingLabel(named: "  Follow-up  ", assigningTo: transcriptionID).value

        let created = try? XCTUnwrap(labelRepo.items.first)
        XCTAssertEqual(created?.name, "Follow-up")
        XCTAssertEqual(service.updateCalls.last?.labelIDs, created.map { Set([$0.id]) })
    }

    func testEarlyLabelIntentsWaitForBaselineAndPreserveExistingTypeAndLabels() async {
        let customer = MeetingType(name: "Customer")
        let existing = MeetingLabel(name: "Existing")
        let removed = MeetingLabel(name: "Removed")
        let added = MeetingLabel(name: "Added")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableTypes = [customer.id: customer]
        service.availableLabels = [existing.id: existing, removed.id: removed, added.id: added]
        service.values[transcriptionID] = MeetingClassification(
            meetingType: customer, labels: [existing, removed]
        )
        let gate = ClassificationReadGate()
        service.onClassificationRead = { _, snapshot in gate.blockFirstReadReturning(snapshot) }
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: [customer]),
            labelRepository: MeetingLabelRepositoryMock(items: [existing, removed, added]),
            service: service
        )

        let first = viewModel.toggleLabel(added.id, for: transcriptionID)
        await Task.detached { gate.waitUntilFirstReadStarted() }.value
        let second = viewModel.toggleLabel(removed.id, for: transcriptionID)
        let third = viewModel.toggleLabel(existing.id, for: transcriptionID)
        let fourth = viewModel.toggleLabel(existing.id, for: transcriptionID)
        XCTAssertTrue(service.updateCalls.isEmpty)
        XCTAssertNil(viewModel.classification(for: transcriptionID))
        XCTAssertTrue(viewModel.updatingTranscriptionIDs.contains(transcriptionID))

        gate.allowFirstReadToFinish()
        for task in [first, second, third, fourth] {
            await task.value
        }

        XCTAssertEqual(service.updateCalls.count, 1)
        XCTAssertEqual(service.updateCalls.first?.meetingTypeID, customer.id)
        XCTAssertEqual(service.updateCalls.first?.labelIDs, [existing.id, added.id])
        XCTAssertEqual(viewModel.classification(for: transcriptionID)?.meetingType, customer)
        XCTAssertFalse(viewModel.updatingTranscriptionIDs.contains(transcriptionID))
    }

    func testEarlyMeetingTypeChangePreservesExistingLabels() async {
        let customer = MeetingType(name: "Customer")
        let existing = MeetingLabel(name: "Existing")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableTypes = [customer.id: customer]
        service.availableLabels = [existing.id: existing]
        service.values[transcriptionID] = MeetingClassification(meetingType: nil, labels: [existing])
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: [customer]),
            labelRepository: MeetingLabelRepositoryMock(items: [existing]),
            service: service
        )

        await viewModel.setMeetingType(customer.id, for: transcriptionID).value

        XCTAssertEqual(service.updateCalls.first?.meetingTypeID, customer.id)
        XCTAssertEqual(service.updateCalls.first?.labelIDs, [existing.id])
    }

    func testFailedInitialReadDoesNotWriteAndRetryDoesNotReplayFailedClicks() async {
        let existing = MeetingLabel(name: "Existing")
        let added = MeetingLabel(name: "Added")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableLabels = [existing.id: existing, added.id: added]
        service.values[transcriptionID] = MeetingClassification(meetingType: nil, labels: [existing])
        service.onClassificationRead = { _, _ in throw CocoaError(.fileReadUnknown) }
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: []),
            labelRepository: MeetingLabelRepositoryMock(items: [existing, added]),
            service: service
        )

        await viewModel.toggleLabel(existing.id, for: transcriptionID).value

        XCTAssertTrue(service.updateCalls.isEmpty)
        XCTAssertNil(viewModel.classification(for: transcriptionID))
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.updatingTranscriptionIDs.contains(transcriptionID))

        service.onClassificationRead = nil
        await viewModel.toggleLabel(added.id, for: transcriptionID).value

        XCTAssertEqual(service.updateCalls.first?.labelIDs, [existing.id, added.id])
        XCTAssertNil(viewModel.errorMessage)
    }

    func testRapidLabelTogglesAreCoalescedWithoutLosingEitherLabel() async {
        let customer = MeetingLabel(name: "Customer")
        let important = MeetingLabel(name: "Important")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableLabels = [customer.id: customer, important.id: important]
        service.values[transcriptionID] = MeetingClassification(meetingType: nil, labels: [])
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: []),
            labelRepository: MeetingLabelRepositoryMock(items: [customer, important]),
            service: service
        )
        await viewModel.loadOptions().value
        await viewModel.loadClassification(for: transcriptionID).value

        let first = viewModel.toggleLabel(customer.id, for: transcriptionID)
        let second = viewModel.toggleLabel(important.id, for: transcriptionID)
        await first.value
        await second.value

        XCTAssertEqual(service.updateCalls.count, 1)
        XCTAssertEqual(service.updateCalls.first?.labelIDs, [customer.id, important.id])
        XCTAssertEqual(
            Set(viewModel.classification(for: transcriptionID)?.labels.map(\.id) ?? []),
            [customer.id, important.id]
        )
    }

    func testRapidTypeChangesAreSerializedAndPersistLatestChoice() async {
        let customer = MeetingType(name: "Customer")
        let oneToOne = MeetingType(name: "1:1")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableTypes = [customer.id: customer, oneToOne.id: oneToOne]
        service.values[transcriptionID] = MeetingClassification(meetingType: nil, labels: [])
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: [customer, oneToOne]),
            labelRepository: MeetingLabelRepositoryMock(items: []),
            service: service
        )
        await viewModel.loadOptions().value
        await viewModel.loadClassification(for: transcriptionID).value

        let first = viewModel.setMeetingType(customer.id, for: transcriptionID)
        let second = viewModel.setMeetingType(oneToOne.id, for: transcriptionID)
        await first.value
        await second.value

        XCTAssertEqual(service.updateCalls.count, 1)
        XCTAssertEqual(service.updateCalls.first?.meetingTypeID, oneToOne.id)
        XCTAssertEqual(viewModel.classification(for: transcriptionID)?.meetingType, oneToOne)
    }

    func testDoubleClickingLabelEndsInOriginalState() async {
        let important = MeetingLabel(name: "Important")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableLabels = [important.id: important]
        service.values[transcriptionID] = MeetingClassification(meetingType: nil, labels: [])
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: []),
            labelRepository: MeetingLabelRepositoryMock(items: [important]),
            service: service
        )
        await viewModel.loadOptions().value
        await viewModel.loadClassification(for: transcriptionID).value

        let firstClick = viewModel.toggleLabel(important.id, for: transcriptionID)
        let secondClick = viewModel.toggleLabel(important.id, for: transcriptionID)
        await firstClick.value
        await secondClick.value

        XCTAssertEqual(service.updateCalls.count, 1)
        XCTAssertTrue(service.updateCalls.first?.labelIDs.isEmpty == true)
        XCTAssertTrue(viewModel.classification(for: transcriptionID)?.labels.isEmpty == true)
    }

    func testStaleLoadCannotOverwriteConcurrentMutation() async {
        let customer = MeetingType(name: "Customer")
        let existing = MeetingLabel(name: "Existing")
        let important = MeetingLabel(name: "Important")
        let transcriptionID = UUID()
        let service = MeetingClassificationServiceMock()
        service.availableTypes = [customer.id: customer]
        service.availableLabels = [existing.id: existing, important.id: important]
        service.values[transcriptionID] = MeetingClassification(meetingType: customer, labels: [existing])
        let readGate = ClassificationReadGate()
        service.onClassificationRead = { _, snapshot in
            readGate.blockFirstReadReturning(snapshot)
        }
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: [customer]),
            labelRepository: MeetingLabelRepositoryMock(items: [existing, important]),
            service: service
        )
        await viewModel.loadOptions().value

        let staleLoad = viewModel.loadClassification(for: transcriptionID)
        await Task.detached { readGate.waitUntilFirstReadStarted() }.value
        let mutation = viewModel.toggleLabel(important.id, for: transcriptionID)
        await mutation.value
        readGate.allowFirstReadToFinish()
        await staleLoad.value

        XCTAssertEqual(
            Set(viewModel.classification(for: transcriptionID)?.labels.map(\.id) ?? []),
            [existing.id, important.id]
        )
        XCTAssertEqual(viewModel.classification(for: transcriptionID)?.meetingType, customer)
    }

    func testLoadClassificationsRefreshesCachedMeetingAfterExternalChange() async {
        let customer = MeetingType(name: "Customer")
        let transcription = Transcription(
            fileName: "Review",
            status: .completed,
            sourceType: .meeting
        )
        let service = MeetingClassificationServiceMock()
        service.values[transcription.id] = MeetingClassification(meetingType: nil, labels: [])
        let viewModel = MeetingClassificationViewModel()
        viewModel.configure(
            typeRepository: MeetingTypeRepositoryMock(items: [customer]),
            labelRepository: MeetingLabelRepositoryMock(items: []),
            service: service
        )
        await viewModel.loadClassification(for: transcription.id).value
        XCTAssertNil(viewModel.classification(for: transcription.id)?.meetingType)

        service.values[transcription.id] = MeetingClassification(meetingType: customer, labels: [])
        let refreshes = viewModel.loadClassifications(for: [transcription])
        for refresh in refreshes {
            await refresh.value
        }

        XCTAssertEqual(viewModel.classification(for: transcription.id)?.meetingType, customer)
    }
}

private final class MeetingTypeRepositoryMock: MeetingTypeRepositoryProtocol, @unchecked Sendable {
    var items: [MeetingType]
    init(items: [MeetingType]) { self.items = items }
    func save(_ meetingType: MeetingType) throws { items.append(meetingType) }
    func fetch(id: UUID) throws -> MeetingType? { items.first { $0.id == id } }
    func fetchAll(includeArchived: Bool) throws -> [MeetingType] {
        includeArchived ? items : items.filter { !$0.isArchived }
    }
    func setArchived(id: UUID, isArchived: Bool) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isArchived = isArchived
    }
    func delete(id: UUID) throws -> Bool {
        let oldCount = items.count
        items.removeAll { $0.id == id }
        return oldCount != items.count
    }
}

private final class MeetingLabelRepositoryMock: MeetingLabelRepositoryProtocol, @unchecked Sendable {
    var items: [MeetingLabel]
    init(items: [MeetingLabel]) { self.items = items }
    func save(_ label: MeetingLabel) throws { items.append(label) }
    func fetch(id: UUID) throws -> MeetingLabel? { items.first { $0.id == id } }
    func fetchAll(includeArchived: Bool) throws -> [MeetingLabel] {
        includeArchived ? items : items.filter { !$0.isArchived }
    }
    func setArchived(id: UUID, isArchived: Bool) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isArchived = isArchived
    }
    func delete(id: UUID) throws -> Bool {
        let oldCount = items.count
        items.removeAll { $0.id == id }
        return oldCount != items.count
    }
}

private final class MeetingClassificationServiceMock: MeetingClassificationServiceProtocol, @unchecked Sendable {
    struct UpdateCall {
        let transcriptionID: UUID
        let meetingTypeID: UUID?
        let labelIDs: Set<UUID>
    }

    private let lock = NSLock()
    var values: [UUID: MeetingClassification] = [:]
    var availableTypes: [UUID: MeetingType] = [:]
    var availableLabels: [UUID: MeetingLabel] = [:]
    var setTypeCalls: [(UUID, UUID?)] = []
    var replaceLabelCalls: [(UUID, Set<UUID>)] = []
    var updateCalls: [UpdateCall] = []
    var onClassificationRead: ((UUID, MeetingClassification) throws -> MeetingClassification)?

    func classification(for transcriptionId: UUID) throws -> MeetingClassification {
        lock.lock()
        let snapshot = values[transcriptionId] ?? MeetingClassification(meetingType: nil, labels: [])
        let hook = onClassificationRead
        lock.unlock()
        return try hook?(transcriptionId, snapshot) ?? snapshot
    }

    func setMeetingType(_ meetingTypeId: UUID?, for transcriptionId: UUID) async throws {
        setTypeCalls.append((transcriptionId, meetingTypeId))
        var value = values[transcriptionId] ?? MeetingClassification(meetingType: nil, labels: [])
        value.meetingType = meetingTypeId.flatMap { availableTypes[$0] }
        values[transcriptionId] = value
    }

    func replaceLabels(_ labelIds: Set<UUID>, for transcriptionId: UUID) async throws {
        replaceLabelCalls.append((transcriptionId, labelIds))
        var value = values[transcriptionId] ?? MeetingClassification(meetingType: nil, labels: [])
        value.labels = labelIds.compactMap { availableLabels[$0] }.sorted { $0.name < $1.name }
        values[transcriptionId] = value
    }

    func update(meetingTypeId: UUID?, labelIds: Set<UUID>, for transcriptionId: UUID) async throws {
        recordUpdate(meetingTypeId: meetingTypeId, labelIds: labelIds, transcriptionId: transcriptionId)
    }

    private func recordUpdate(meetingTypeId: UUID?, labelIds: Set<UUID>, transcriptionId: UUID) {
        lock.lock()
        updateCalls.append(
            UpdateCall(
                transcriptionID: transcriptionId,
                meetingTypeID: meetingTypeId,
                labelIDs: labelIds
            ))
        values[transcriptionId] = MeetingClassification(
            meetingType: meetingTypeId.flatMap { availableTypes[$0] },
            labels: labelIds.compactMap { availableLabels[$0] }.sorted { $0.name < $1.name }
        )
        lock.unlock()
    }
}

private final class ClassificationReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var readCount = 0
    private let firstReadStarted = DispatchSemaphore(value: 0)
    private let allowFirstRead = DispatchSemaphore(value: 0)

    func blockFirstReadReturning(_ snapshot: MeetingClassification) -> MeetingClassification {
        lock.lock()
        readCount += 1
        let shouldBlock = readCount == 1
        lock.unlock()
        if shouldBlock {
            firstReadStarted.signal()
            allowFirstRead.wait()
        }
        return snapshot
    }

    func waitUntilFirstReadStarted() {
        firstReadStarted.wait()
    }

    func allowFirstReadToFinish() {
        allowFirstRead.signal()
    }
}
