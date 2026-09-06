import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class TranscriptionLibraryViewModelTests: XCTestCase {
    var vm: TranscriptionLibraryViewModel!
    var repo: TranscriptionRepository!

    override func setUp() async throws {
        let manager = try DatabaseManager()
        repo = TranscriptionRepository(dbQueue: manager.dbQueue)
        vm = TranscriptionLibraryViewModel()
        vm.configure(transcriptionRepo: repo)
    }

    private func load(_ viewModel: TranscriptionLibraryViewModel? = nil) async {
        await (viewModel ?? vm).loadTranscriptions().value
    }

    // MARK: - Load

    func testLoadTranscriptions() async throws {
        try repo.save(Transcription(fileName: "a.mp3", status: .completed))
        try repo.save(Transcription(fileName: "b.mp3", status: .completed))

        await load()
        XCTAssertEqual(vm.transcriptions.count, 2)
    }

    func testLoadTranscriptionsIncludesProcessingMeetingRowsOnly() async throws {
        try repo.save(Transcription(fileName: "done.mp3", status: .completed, sourceType: .file))
        try repo.save(Transcription(fileName: "working-file.mp3", status: .processing, sourceType: .file))
        try repo.save(Transcription(fileName: "working-video.mp3", status: .processing, sourceType: .youtube))
        try repo.save(Transcription(fileName: "working-meeting.m4a", status: .processing, sourceType: .meeting))

        await load()

        XCTAssertEqual(Set(vm.transcriptions.map(\.fileName)), ["done.mp3", "working-meeting.m4a"])
        XCTAssertEqual(Set(vm.filteredTranscriptions.map(\.fileName)), ["done.mp3", "working-meeting.m4a"])
    }

    func testLoadTranscriptionsIncludesCancelledAndErrorRows() async throws {
        try repo.save(Transcription(fileName: "done.mp3", status: .completed))
        try repo.save(Transcription(fileName: "cancelled.mp3", status: .cancelled))
        try repo.save(Transcription(fileName: "failed.mp3", status: .error, errorMessage: "boom"))

        await load()

        XCTAssertEqual(vm.transcriptions.count, 3)
        XCTAssertEqual(Set(vm.transcriptions.map(\.fileName)), ["done.mp3", "cancelled.mp3", "failed.mp3"])
        XCTAssertEqual(vm.filteredTranscriptions.count, 3)
        XCTAssertEqual(Set(vm.filteredTranscriptions.map(\.fileName)), ["done.mp3", "cancelled.mp3", "failed.mp3"])
    }

    // MARK: - Filter

    func testFilterAll() async throws {
        try repo.save(Transcription(fileName: "local.mp3", status: .completed))
        try repo.save(
            Transcription(
                fileName: "youtube.mp3",
                status: .completed,
                sourceURL: "https://youtube.com/watch?v=abc",
                sourceType: .youtube
            ))

        vm.filter = .all
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 2)
    }

    func testFilterYouTube() async throws {
        try repo.save(Transcription(fileName: "local.mp3", status: .completed))
        try repo.save(
            Transcription(
                fileName: "youtube.mp3",
                status: .completed,
                sourceURL: "https://youtube.com/watch?v=abc",
                sourceType: .youtube
            ))

        vm.filter = .youtube
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "youtube.mp3")
    }

    func testFilterPodcast() async throws {
        try repo.save(Transcription(fileName: "local.mp3", status: .completed, sourceType: .file))
        try repo.save(
            Transcription(
                fileName: "youtube.mp3", status: .completed, sourceURL: "https://youtube.com/watch?v=abc",
                sourceType: .youtube))
        try repo.save(
            Transcription(
                fileName: "episode.mp3",
                status: .completed,
                sourceURL: "https://podcasts.apple.com/us/podcast/x/id1?i=2",
                sourceType: .podcast
            ))

        vm.filter = .podcast
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "episode.mp3")
    }

    func testFilterLocal() async throws {
        try repo.save(Transcription(fileName: "local.mp3", status: .completed, sourceType: .file))
        try repo.save(Transcription(fileName: "meeting.mp3", status: .completed, sourceType: .meeting))
        try repo.save(
            Transcription(
                fileName: "youtube.mp3", status: .completed, sourceURL: "https://youtube.com/watch?v=abc",
                sourceType: .youtube))

        vm.filter = .local
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "local.mp3")
    }

    func testFilterFavorites() async throws {
        try repo.save(Transcription(fileName: "fav.mp3", status: .completed, isFavorite: true))
        try repo.save(Transcription(fileName: "normal.mp3", status: .completed))

        vm.filter = .favorites
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "fav.mp3")
    }

    func testFilterMeetings() async throws {
        try repo.save(Transcription(fileName: "meeting.mp3", status: .completed, sourceType: .meeting))
        try repo.save(Transcription(fileName: "local.mp3", status: .completed, sourceType: .file))

        vm.filter = .meeting
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "meeting.mp3")
    }

    func testMeetingTypeFiltersUseAnySemanticsBeforePagination() async throws {
        let customer = MeetingType(name: "Customer")
        let oneToOne = MeetingType(name: "1:1")
        let manager = try DatabaseManager()
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let meetingTypeRepo = MeetingTypeRepository(dbQueue: manager.dbQueue)
        try meetingTypeRepo.save(customer)
        try meetingTypeRepo.save(oneToOne)
        try transcriptionRepo.save(Transcription(
            createdAt: Date(timeIntervalSince1970: 3),
            fileName: "Other",
            status: .completed,
            sourceType: .meeting
        ))
        try transcriptionRepo.save(Transcription(
            createdAt: Date(timeIntervalSince1970: 2),
            fileName: "Customer",
            status: .completed,
            sourceType: .meeting,
            meetingTypeId: customer.id
        ))
        try transcriptionRepo.save(Transcription(
            createdAt: Date(timeIntervalSince1970: 1),
            fileName: "One-to-one",
            status: .completed,
            sourceType: .meeting,
            meetingTypeId: oneToOne.id
        ))

        let viewModel = TranscriptionLibraryViewModel(scope: .meetings)
        viewModel.configure(transcriptionRepo: transcriptionRepo)
        viewModel.pageSize = 1
        viewModel.toggleMeetingTypeFilter(customer.id)
        viewModel.toggleMeetingTypeFilter(oneToOne.id)
        await load(viewModel)

        XCTAssertEqual(viewModel.filteredTranscriptions.map(\.fileName), ["Customer"])
        XCTAssertTrue(viewModel.hasMore)
    }

    func testUnclassifiedMeetingFilterIsMutuallyExclusiveWithTypeFilters() async throws {
        let customer = MeetingType(name: "Customer")
        let manager = try DatabaseManager()
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let meetingTypeRepo = MeetingTypeRepository(dbQueue: manager.dbQueue)
        try meetingTypeRepo.save(customer)
        try transcriptionRepo.save(Transcription(
            fileName: "Typed",
            status: .completed,
            sourceType: .meeting,
            meetingTypeId: customer.id
        ))
        try transcriptionRepo.save(Transcription(
            fileName: "Unclassified",
            status: .completed,
            sourceType: .meeting
        ))

        let viewModel = TranscriptionLibraryViewModel(scope: .meetings)
        viewModel.configure(transcriptionRepo: transcriptionRepo)
        viewModel.toggleMeetingTypeFilter(customer.id)
        viewModel.setUnclassifiedMeetingsFilter(true)
        await load(viewModel)

        XCTAssertTrue(viewModel.selectedMeetingTypeIDs.isEmpty)
        XCTAssertTrue(viewModel.unclassifiedMeetingsOnly)
        XCTAssertEqual(viewModel.filteredTranscriptions.map(\.fileName), ["Unclassified"])
    }

    func testMeetingLabelFiltersUseAnySemantics() async throws {
        let manager = try DatabaseManager()
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let labelRepo = MeetingLabelRepository(dbQueue: manager.dbQueue)
        let assignmentRepo = TranscriptionMeetingLabelRepository(dbQueue: manager.dbQueue)
        let customer = MeetingLabel(name: "Customer")
        let important = MeetingLabel(name: "Important")
        try labelRepo.save(customer)
        try labelRepo.save(important)

        let first = Transcription(fileName: "First", status: .completed, sourceType: .meeting)
        let second = Transcription(fileName: "Second", status: .completed, sourceType: .meeting)
        let third = Transcription(fileName: "Third", status: .completed, sourceType: .meeting)
        try transcriptionRepo.save(first)
        try transcriptionRepo.save(second)
        try transcriptionRepo.save(third)
        try assignmentRepo.add(labelId: customer.id, to: first.id)
        try assignmentRepo.add(labelId: important.id, to: second.id)

        let viewModel = TranscriptionLibraryViewModel(scope: .meetings)
        viewModel.configure(transcriptionRepo: transcriptionRepo)
        viewModel.toggleMeetingLabelFilter(customer.id)
        viewModel.toggleMeetingLabelFilter(important.id)
        await load(viewModel)

        XCTAssertEqual(Set(viewModel.filteredTranscriptions.map(\.fileName)), ["First", "Second"])
    }

    func testLabelFilterAppliesInsidePodcastSourceTab() async throws {
        let manager = try DatabaseManager()
        let transcriptionRepo = TranscriptionRepository(dbQueue: manager.dbQueue)
        let labelRepo = MeetingLabelRepository(dbQueue: manager.dbQueue)
        let assignmentRepo = TranscriptionMeetingLabelRepository(dbQueue: manager.dbQueue)
        let research = MeetingLabel(name: "Research")
        try labelRepo.save(research)

        let selected = Transcription(fileName: "Selected", status: .completed, sourceType: .podcast)
        let other = Transcription(fileName: "Other", status: .completed, sourceType: .podcast)
        let local = Transcription(fileName: "Local", status: .completed, sourceType: .file)
        try transcriptionRepo.save(selected)
        try transcriptionRepo.save(other)
        try transcriptionRepo.save(local)
        try assignmentRepo.add(labelId: research.id, to: selected.id)
        try assignmentRepo.add(labelId: research.id, to: local.id)

        let viewModel = TranscriptionLibraryViewModel()
        viewModel.configure(transcriptionRepo: transcriptionRepo)
        viewModel.filter = .podcast
        viewModel.toggleMeetingLabelFilter(research.id)
        await load(viewModel)

        XCTAssertEqual(viewModel.filteredTranscriptions.map(\.fileName), ["Selected"])
    }

    func testMeetingsScopeOnlyShowsMeetings() async throws {
        let meetingVM = TranscriptionLibraryViewModel(scope: .meetings)
        meetingVM.configure(transcriptionRepo: repo)

        try repo.save(Transcription(fileName: "meeting.mp3", status: .completed, sourceType: .meeting))
        try repo.save(Transcription(fileName: "processing meeting.mp3", status: .processing, sourceType: .meeting))
        try repo.save(Transcription(fileName: "failed meeting.mp3", status: .error, sourceType: .meeting))
        try repo.save(Transcription(fileName: "local.mp3", status: .completed, sourceType: .file))

        await load(meetingVM)

        XCTAssertEqual(
            Set(meetingVM.filteredTranscriptions.map(\.fileName)),
            ["meeting.mp3", "processing meeting.mp3", "failed meeting.mp3"]
        )
    }

    func testMeetingsScopeComposesWithFavoritesAndConflictingFilters() async throws {
        let meetingVM = TranscriptionLibraryViewModel(scope: .meetings)
        meetingVM.configure(transcriptionRepo: repo)

        try repo.save(
            Transcription(fileName: "fav meeting.mp3", status: .completed, isFavorite: true, sourceType: .meeting))
        try repo.save(Transcription(fileName: "normal meeting.mp3", status: .completed, sourceType: .meeting))
        try repo.save(Transcription(fileName: "fav local.mp3", status: .completed, isFavorite: true, sourceType: .file))

        meetingVM.filter = .favorites
        await load(meetingVM)
        XCTAssertEqual(meetingVM.filteredTranscriptions.map(\.fileName), ["fav meeting.mp3"])

        meetingVM.filter = .local
        await load(meetingVM)
        XCTAssertTrue(meetingVM.filteredTranscriptions.isEmpty)
    }

    // MARK: - Search

    func testSearchByTitle() async throws {
        try repo.save(Transcription(fileName: "Swift Tutorial", status: .completed))
        try repo.save(Transcription(fileName: "Python Basics", status: .completed))

        vm.searchText = "swift"
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "Swift Tutorial")
    }

    func testSearchByTranscript() async throws {
        var t = Transcription(fileName: "Recording", status: .completed)
        t.rawTranscript = "The quick brown fox jumps over the lazy dog"
        try repo.save(t)

        try repo.save(Transcription(fileName: "Other", status: .completed))

        vm.searchText = "brown fox"
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "Recording")
    }

    func testSearchByChannel() async throws {
        try repo.save(
            Transcription(
                fileName: "Video",
                status: .completed,
                sourceURL: "https://youtube.com/watch?v=abc",
                channelName: "TechChannel"
            ))
        try repo.save(Transcription(fileName: "Other", status: .completed))

        vm.searchText = "techchannel"
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
    }

    // MARK: - Sort

    func testSortDateDescending() async throws {
        let older = Transcription(createdAt: Date().addingTimeInterval(-100), fileName: "older.mp3", status: .completed)
        let newer = Transcription(createdAt: Date(), fileName: "newer.mp3", status: .completed)
        try repo.save(older)
        try repo.save(newer)

        vm.sortOrder = .dateDescending
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "newer.mp3")
    }

    func testSortTitleAscending() async throws {
        try repo.save(Transcription(fileName: "Banana.mp3", status: .completed))
        try repo.save(Transcription(fileName: "Apple.mp3", status: .completed))

        vm.sortOrder = .titleAscending
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "Apple.mp3")
    }

    func testRenameLocalTranscriptionTitleUpdatesOverrideAndPreservesSourceMetadata() async throws {
        let transcription = Transcription(
            fileName: "IMG_1942.m4a",
            filePath: "/tmp/IMG_1942.m4a",
            status: .completed,
            derivedTitle: "Auto Derived Title"
        )
        try repo.save(transcription)
        vm.filter = .local
        await load()

        vm.renameTranscriptionTitle(vm.transcriptions[0], to: "  Q3 Vendor Notes  ")

        let loaded = try XCTUnwrap(vm.transcriptions.first)
        XCTAssertEqual(loaded.titleOverride, "Q3 Vendor Notes")
        XCTAssertEqual(loaded.effectiveDisplayTitle, "Q3 Vendor Notes")
        XCTAssertEqual(loaded.fileName, "IMG_1942.m4a")
        XCTAssertEqual(loaded.filePath, "/tmp/IMG_1942.m4a")
        XCTAssertEqual(loaded.derivedTitle, "Auto Derived Title")

        let fetched = try XCTUnwrap(repo.fetch(id: transcription.id))
        XCTAssertEqual(fetched.titleOverride, "Q3 Vendor Notes")
        XCTAssertEqual(fetched.fileName, "IMG_1942.m4a")
        XCTAssertEqual(fetched.filePath, "/tmp/IMG_1942.m4a")
        XCTAssertEqual(fetched.derivedTitle, "Auto Derived Title")
    }

    func testRenameLocalTranscriptionTitleRejectsBlankAndNoOpTitles() async throws {
        let transcription = Transcription(
            fileName: "IMG_1942.m4a",
            status: .completed,
            derivedTitle: "Auto Derived Title"
        )
        try repo.save(transcription)
        await load()

        vm.renameTranscriptionTitle(vm.transcriptions[0], to: "   ")
        vm.renameTranscriptionTitle(vm.transcriptions[0], to: "IMG_1942.m4a")

        let loaded = try XCTUnwrap(vm.transcriptions.first)
        XCTAssertNil(loaded.titleOverride)
        XCTAssertEqual(loaded.effectiveDisplayTitle, "IMG_1942.m4a")
        XCTAssertNil(try repo.fetch(id: transcription.id)?.titleOverride)
    }

    func testRenameLocalTranscriptionTitleReloadsCurrentSortOrder() async throws {
        let first = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            fileName: "z-source.m4a",
            status: .completed
        )
        let second = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            fileName: "b-source.m4a",
            status: .completed
        )
        try repo.save(first)
        try repo.save(second)
        vm.filter = .local
        vm.sortOrder = .titleAscending
        await load()

        XCTAssertEqual(vm.filteredTranscriptions.map(\.id), [second.id, first.id])

        XCTAssertTrue(vm.renameTranscriptionTitle(first, to: "Aardvark Notes"))

        XCTAssertEqual(vm.filteredTranscriptions.map(\.id), [first.id, second.id])
    }

    func testRenameLocalTranscriptionTitleReportsRefreshFailureAfterSuccessfulWrite() async throws {
        let mockRepo = MockTranscriptionRepository()
        let viewModel = TranscriptionLibraryViewModel()
        let transcription = Transcription(
            fileName: "IMG_1942.m4a",
            status: .completed,
            derivedTitle: "Auto Derived Title"
        )
        mockRepo.transcriptions = [transcription]
        viewModel.configure(transcriptionRepo: mockRepo)
        await load(viewModel)

        mockRepo.fetchAllError = LibraryRenameTestError.reloadFailed
        XCTAssertTrue(viewModel.renameTranscriptionTitle(viewModel.transcriptions[0], to: "Q3 Vendor Notes"))

        XCTAssertEqual(mockRepo.updateTitleOverrideCalls.count, 1)
        XCTAssertEqual(mockRepo.transcriptions.first?.titleOverride, "Q3 Vendor Notes")
        XCTAssertTrue(
            viewModel.errorMessage?.contains("Renamed transcription, but failed to refresh Library") ?? false
        )
        XCTAssertFalse(viewModel.errorMessage?.contains("Failed to rename transcription") ?? true)
    }

    func testRenameLocalTranscriptionTitleReturnsFalseWhenWriteFails() async throws {
        let mockRepo = MockTranscriptionRepository()
        let viewModel = TranscriptionLibraryViewModel()
        let transcription = Transcription(
            fileName: "IMG_1942.m4a",
            status: .completed,
            derivedTitle: "Auto Derived Title"
        )
        mockRepo.transcriptions = [transcription]
        mockRepo.updateTitleOverrideError = LibraryRenameTestError.persistenceFailed
        viewModel.configure(transcriptionRepo: mockRepo)
        await load(viewModel)

        let renamed = viewModel.renameTranscriptionTitle(viewModel.transcriptions[0], to: "Q3 Vendor Notes")

        XCTAssertFalse(renamed)
        XCTAssertEqual(mockRepo.updateTitleOverrideCalls.count, 1)
        XCTAssertNil(mockRepo.transcriptions.first?.titleOverride)
        XCTAssertTrue(viewModel.errorMessage?.contains("Failed to rename transcription") ?? false)
    }

    func testRenameLocalTranscriptionTitlePreventsStaleInFlightLoadFromOverwritingRefresh() async throws {
        let mockRepo = MockTranscriptionRepository()
        let viewModel = TranscriptionLibraryViewModel()
        let transcription = Transcription(
            fileName: "IMG_1942.m4a",
            status: .completed,
            derivedTitle: "Auto Derived Title"
        )
        let gate = StaleFetchGate()
        mockRepo.transcriptions = [transcription]
        mockRepo.fetchAllHandler = { [mockRepo, gate] limit in
            let callNumber = gate.nextCallNumber()
            let snapshot = mockRepo.transcriptions
            if callNumber == 1 {
                gate.blockFirstFetchUntilAllowed()
            }
            let sorted = snapshot.sorted { $0.createdAt > $1.createdAt }
            if let limit { return Array(sorted.prefix(limit)) }
            return sorted
        }
        viewModel.configure(transcriptionRepo: mockRepo)

        let staleLoad = viewModel.loadTranscriptions()
        await Task.detached {
            gate.waitForFirstFetchStarted()
        }.value

        XCTAssertTrue(viewModel.renameTranscriptionTitle(transcription, to: "Q3 Vendor Notes"))
        XCTAssertEqual(viewModel.transcriptions.first?.titleOverride, "Q3 Vendor Notes")

        gate.allowFirstFetchToFinish()
        await staleLoad.value

        XCTAssertEqual(viewModel.transcriptions.first?.titleOverride, "Q3 Vendor Notes")
        XCTAssertEqual(viewModel.transcriptions.first?.effectiveDisplayTitle, "Q3 Vendor Notes")
    }

    func testApplyMeetingRenameReordersTitleAscendingLoadedWindow() async throws {
        let first = Transcription(fileName: "Zulu Review", status: .completed, sourceType: .meeting)
        let second = Transcription(fileName: "Beta Review", status: .completed, sourceType: .meeting)
        try repo.save(first)
        try repo.save(second)
        vm.pageSize = 1
        vm.sortOrder = .titleAscending
        await load()
        let nextPage = try XCTUnwrap(vm.loadMoreTranscriptions())
        await nextPage.value
        XCTAssertEqual(vm.filteredTranscriptions.map(\.id), [second.id, first.id])

        try repo.updateFileName(id: first.id, fileName: "Aardvark Review")
        vm.applyMeetingRename(MeetingRename(id: first.id, title: "Aardvark Review"))

        XCTAssertEqual(vm.filteredTranscriptions.map(\.id), [first.id, second.id])
        XCTAssertEqual(vm.filteredTranscriptions.map(\.effectiveDisplayTitle), ["Aardvark Review", "Beta Review"])
        XCTAssertFalse(vm.hasMore)
    }

    func testApplyMeetingRenameAddsPreviouslyUnloadedTitleSearchMatch() async throws {
        let meeting = Transcription(fileName: "Planning", status: .completed, sourceType: .meeting)
        try repo.save(meeting)
        vm.searchText = "  Review  "
        await load()
        XCTAssertTrue(vm.filteredTranscriptions.isEmpty)

        try repo.updateFileName(id: meeting.id, fileName: "Design Review")
        vm.applyMeetingRename(MeetingRename(id: meeting.id, title: "Design Review"))

        XCTAssertEqual(vm.filteredTranscriptions.map(\.id), [meeting.id])
        XCTAssertEqual(vm.filteredTranscriptions.first?.effectiveDisplayTitle, "Design Review")
    }

    func testApplyMeetingRenameRemovesRenamedAwayTitleSearchMatch() async throws {
        let meeting = Transcription(fileName: "Design Review", status: .completed, sourceType: .meeting)
        try repo.save(meeting)
        vm.searchText = "Review"
        await load()
        XCTAssertEqual(vm.filteredTranscriptions.map(\.id), [meeting.id])
        vm.toggleSelection(for: meeting)

        try repo.updateFileName(id: meeting.id, fileName: "Planning")
        vm.applyMeetingRename(MeetingRename(id: meeting.id, title: "Planning"))

        XCTAssertTrue(vm.transcriptions.isEmpty)
        XCTAssertTrue(vm.filteredTranscriptions.isEmpty)
        XCTAssertTrue(vm.groupedTranscriptions.isEmpty)
        XCTAssertFalse(vm.hasSelectedTranscriptions)
        XCTAssertFalse(vm.hasMore)
    }

    func testApplyMeetingRenamePreventsStaleLoadFromRestoringTitleOrderAndSearchMembership() async throws {
        let mockRepo = MockTranscriptionRepository()
        let viewModel = TranscriptionLibraryViewModel()
        let renamedFirst = Transcription(fileName: "Zulu Review", status: .completed, sourceType: .meeting)
        let renamedAway = Transcription(fileName: "Beta Review", status: .completed, sourceType: .meeting)
        let unchanged = Transcription(fileName: "Middle Review", status: .completed, sourceType: .meeting)
        let gate = StaleFetchGate()
        mockRepo.transcriptions = [renamedFirst, renamedAway, unchanged]
        mockRepo.fetchAllHandler = { [mockRepo, gate] _ in
            let callNumber = gate.nextCallNumber()
            let snapshot = mockRepo.transcriptions
            if callNumber == 1 {
                gate.blockFirstFetchUntilAllowed()
            }
            return snapshot
        }
        viewModel.sortOrder = .titleAscending
        viewModel.searchText = "Review"
        viewModel.configure(transcriptionRepo: mockRepo)

        let staleLoad = viewModel.loadTranscriptions()
        await Task.detached {
            gate.waitForFirstFetchStarted()
        }.value

        try mockRepo.updateFileName(id: renamedFirst.id, fileName: "Aardvark Review")
        viewModel.applyMeetingRename(MeetingRename(id: renamedFirst.id, title: "Aardvark Review"))
        try mockRepo.updateFileName(id: renamedAway.id, fileName: "Planning")
        viewModel.applyMeetingRename(MeetingRename(id: renamedAway.id, title: "Planning"))
        XCTAssertEqual(viewModel.filteredTranscriptions.map(\.id), [renamedFirst.id, unchanged.id])

        gate.allowFirstFetchToFinish()
        await staleLoad.value

        XCTAssertEqual(viewModel.filteredTranscriptions.map(\.id), [renamedFirst.id, unchanged.id])
        XCTAssertEqual(
            viewModel.filteredTranscriptions.map(\.effectiveDisplayTitle),
            ["Aardvark Review", "Middle Review"]
        )
    }

    func testApplyMeetingRenameRejectsStaleUnloadedLibrarySnapshot() async throws {
        try await assertMeetingRenameRejectsStaleDateWindow(scope: .all, loadMore: false)
    }

    func testApplyMeetingRenameRejectsStaleUnloadedRecentMeetingsSnapshot() async throws {
        try await assertMeetingRenameRejectsStaleDateWindow(scope: .meetings, loadMore: false)
    }

    func testApplyMeetingRenamePreservesInFlightLibraryPagination() async throws {
        try await assertMeetingRenameRejectsStaleDateWindow(scope: .all, loadMore: true)
    }

    func testApplyMeetingRenamePreservesInFlightRecentMeetingsPagination() async throws {
        try await assertMeetingRenameRejectsStaleDateWindow(scope: .meetings, loadMore: true)
    }

    func testApplyMeetingRenameUpdatesIdleDateWindowWithoutRequery() async throws {
        let mockRepo = MockTranscriptionRepository()
        let meeting = Transcription(fileName: "Old meeting", status: .completed, sourceType: .meeting)
        mockRepo.transcriptions = [meeting]
        vm.configure(transcriptionRepo: mockRepo)
        await load()
        mockRepo.fetchAllError = LibraryRenameTestError.reloadFailed

        try mockRepo.updateFileName(id: meeting.id, fileName: "Renamed meeting")
        vm.applyMeetingRename(MeetingRename(id: meeting.id, title: "Renamed meeting"))

        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "Renamed meeting")
        XCTAssertEqual(vm.groupedTranscriptions.first?.items.first?.fileName, "Renamed meeting")
    }

    func testApplyMeetingRenameLeavesNonMeetingQueryLoadActive() async throws {
        let mockRepo = MockTranscriptionRepository()
        let local = Transcription(fileName: "Local recording", status: .completed, sourceType: .file)
        let gate = StaleFetchGate()
        mockRepo.fetchAllHandler = { _ in
            guard gate.nextCallNumber() == 1 else { throw LibraryRenameTestError.reloadFailed }
            gate.blockFirstFetchUntilAllowed()
            return [local]
        }
        let viewModel = TranscriptionLibraryViewModel()
        viewModel.filter = .local
        viewModel.sortOrder = .titleAscending
        viewModel.configure(transcriptionRepo: mockRepo)
        let activeLoad = viewModel.loadTranscriptions()
        defer { gate.allowFirstFetchToFinish() }
        await Task.detached { gate.waitForFirstFetchStarted() }.value

        viewModel.applyMeetingRename(MeetingRename(id: UUID(), title: "Renamed meeting"))

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.isLoading)
        gate.allowFirstFetchToFinish()
        await activeLoad.value
        XCTAssertEqual(viewModel.filteredTranscriptions.map(\.id), [local.id])
        XCTAssertFalse(viewModel.isLoading)
    }

    private func assertMeetingRenameRejectsStaleDateWindow(
        scope: TranscriptionLibraryScope,
        loadMore: Bool
    ) async throws {
        let repository = try XCTUnwrap(repo)
        let meetings = (0..<3).map { index in
            Transcription(
                createdAt: Date(timeIntervalSince1970: Double(3 - index)),
                fileName: "Meeting \(index)",
                status: .completed,
                sourceType: .meeting
            )
        }
        for meeting in meetings {
            try repository.save(meeting)
        }
        let mockRepo = MockTranscriptionRepository()
        mockRepo.fetchAllHandler = { try repository.fetchAll(limit: $0) }
        let viewModel = TranscriptionLibraryViewModel(scope: scope)
        viewModel.pageSize = 1
        viewModel.configure(transcriptionRepo: mockRepo)
        if loadMore {
            await viewModel.loadTranscriptions().value
            XCTAssertEqual(viewModel.transcriptions.map(\.id), [meetings[0].id])
        }

        let gate = StaleFetchGate()
        mockRepo.fetchAllHandler = { limit in
            let callNumber = gate.nextCallNumber()
            let snapshot = try repository.fetchAll(limit: limit)
            if callNumber == 1 {
                gate.blockFirstFetchUntilAllowed()
            }
            return snapshot
        }
        let staleLoad: Task<Void, Never>
        if loadMore {
            staleLoad = try XCTUnwrap(viewModel.loadMoreTranscriptions())
        } else {
            staleLoad = viewModel.loadTranscriptions()
        }
        defer { gate.allowFirstFetchToFinish() }
        await Task.detached { gate.waitForFirstFetchStarted() }.value
        let renamed = meetings[loadMore ? 1 : 0]
        XCTAssertFalse(viewModel.transcriptions.contains { $0.id == renamed.id })

        try repository.updateFileName(id: renamed.id, fileName: "Renamed meeting")
        viewModel.applyMeetingRename(MeetingRename(id: renamed.id, title: "Renamed meeting"))

        let expectedIDs = Array(meetings.prefix(loadMore ? 2 : 1)).map(\.id)
        XCTAssertEqual(viewModel.transcriptions.map(\.id), expectedIDs)
        XCTAssertEqual(viewModel.transcriptions.last?.fileName, "Renamed meeting")
        XCTAssertTrue(viewModel.hasMore)
        XCTAssertFalse(viewModel.isLoading)
        gate.allowFirstFetchToFinish()
        await staleLoad.value
        XCTAssertEqual(viewModel.transcriptions.map(\.id), expectedIDs)
        XCTAssertEqual(viewModel.transcriptions.last?.fileName, "Renamed meeting")

        let nextPage = try XCTUnwrap(viewModel.loadMoreTranscriptions())
        await nextPage.value
        XCTAssertEqual(
            viewModel.transcriptions.map(\.id),
            Array(meetings.prefix(loadMore ? 3 : 2)).map(\.id)
        )
        XCTAssertEqual(viewModel.transcriptions.first { $0.id == renamed.id }?.fileName, "Renamed meeting")
        XCTAssertEqual(viewModel.hasMore, !loadMore)
    }

    // MARK: - Favorites

    func testToggleFavorite() async throws {
        let t = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(t)
        await load()

        XCTAssertFalse(vm.transcriptions[0].isFavorite)
        vm.toggleFavorite(vm.transcriptions[0])
        XCTAssertTrue(vm.transcriptions[0].isFavorite)

        // Verify persisted
        let fetched = try repo.fetch(id: t.id)
        XCTAssertTrue(fetched?.isFavorite ?? false)
    }

    func testToggleFavoriteOffInFavoritesFilterRemovesRowWithoutReload() async throws {
        let favorite = Transcription(fileName: "fav.mp3", status: .completed, isFavorite: true)
        let normal = Transcription(fileName: "normal.mp3", status: .completed)
        try repo.save(favorite)
        try repo.save(normal)

        vm.filter = .favorites
        await load()

        XCTAssertEqual(vm.filteredTranscriptions.map(\.id), [favorite.id])
        vm.toggleFavorite(vm.filteredTranscriptions[0])

        XCTAssertTrue(vm.filteredTranscriptions.isEmpty)
        XCTAssertFalse(try repo.fetch(id: favorite.id)?.isFavorite ?? true)
    }

    // MARK: - Retry

    func testRetryMeetingTranscriptionReloadsSameRowAfterCallback() async throws {
        let failed = Transcription(
            fileName: "Design Review",
            status: .error,
            errorMessage: "decoder failed",
            sourceType: .meeting
        )
        try repo.save(failed)
        await load()

        var retriedIDs: [UUID] = []
        vm.onRetryMeetingTranscription = { transcription in
            retriedIDs.append(transcription.id)
            try self.repo.updateStatus(
                id: transcription.id,
                status: .completed,
                errorMessage: nil
            )
        }

        let retryTask = vm.retryMeetingTranscription(failed)

        XCTAssertTrue(vm.isRetryingMeetingTranscription(failed))
        XCTAssertEqual(vm.transcriptions.first?.status, .error)

        await retryTask.value

        XCTAssertEqual(retriedIDs, [failed.id])
        XCTAssertFalse(vm.isRetryingMeetingTranscription(failed))
        XCTAssertEqual(vm.transcriptions.map(\.id), [failed.id])
        XCTAssertEqual(vm.transcriptions.first?.status, .completed)
        XCTAssertNil(vm.transcriptions.first?.errorMessage)
        XCTAssertEqual(try repo.count(), 1)
    }

    func testRetryMeetingTranscriptionAcceptsCancelledMeetingRows() async throws {
        let cancelled = Transcription(
            fileName: "Interrupted Design Review",
            status: .cancelled,
            sourceType: .meeting
        )
        try repo.save(cancelled)
        await load()

        var retriedIDs: [UUID] = []
        vm.onRetryMeetingTranscription = { transcription in
            retriedIDs.append(transcription.id)
            try self.repo.updateStatus(
                id: transcription.id,
                status: .completed,
                errorMessage: nil
            )
        }

        let retryTask = vm.retryMeetingTranscription(cancelled)
        await retryTask.value

        XCTAssertEqual(retriedIDs, [cancelled.id])
        XCTAssertFalse(vm.isRetryingMeetingTranscription(cancelled))
        XCTAssertEqual(vm.transcriptions.map(\.id), [cancelled.id])
        XCTAssertEqual(vm.transcriptions.first?.status, .completed)
    }

    func testRetryMeetingTranscriptionRefreshesRowWhenLoadedWindowReloadWouldFail() async throws {
        let mockRepo = MockTranscriptionRepository()
        let viewModel = TranscriptionLibraryViewModel()
        let failed = Transcription(
            fileName: "Refresh Failure Meeting",
            status: .error,
            errorMessage: "Previous failure",
            sourceType: .meeting
        )
        mockRepo.transcriptions = [failed]
        viewModel.configure(transcriptionRepo: mockRepo)
        await load(viewModel)

        mockRepo.fetchAllError = LibraryRenameTestError.reloadFailed
        viewModel.onRetryMeetingTranscription = { transcription in
            try mockRepo.updateStatus(
                id: transcription.id,
                status: .completed,
                errorMessage: nil
            )
        }

        let retryTask = viewModel.retryMeetingTranscription(failed)
        await retryTask.value

        XCTAssertEqual(viewModel.transcriptions.map(\.id), [failed.id])
        XCTAssertEqual(viewModel.transcriptions.first?.status, .completed)
        XCTAssertNil(viewModel.transcriptions.first?.errorMessage)
    }

    func testRetryMeetingTranscriptionRefreshesOnlyAffectedRowAndPreservesLoadedWindow() async throws {
        let mockRepo = MockTranscriptionRepository()
        let viewModel = TranscriptionLibraryViewModel()
        viewModel.pageSize = 2
        let first = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 300),
            fileName: "First",
            status: .completed,
            sourceType: .meeting
        )
        let second = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 200),
            fileName: "Second",
            status: .completed,
            sourceType: .meeting
        )
        let failed = Transcription(
            createdAt: Date(timeIntervalSinceReferenceDate: 100),
            fileName: "Third",
            status: .error,
            errorMessage: "Previous failure",
            sourceType: .meeting
        )
        mockRepo.transcriptions = [first, second, failed]
        viewModel.configure(transcriptionRepo: mockRepo)

        await load(viewModel)
        XCTAssertEqual(viewModel.transcriptions.map(\.id), [first.id, second.id])
        XCTAssertTrue(viewModel.hasMore)
        await viewModel.loadMoreTranscriptions()?.value
        let loadedIDs = viewModel.transcriptions.map(\.id)
        let fetchAllCallCount = mockRepo.fetchAllCalls.count

        viewModel.onRetryMeetingTranscription = { transcription in
            try mockRepo.updateStatus(
                id: transcription.id,
                status: .completed,
                errorMessage: nil
            )
        }

        let retryTask = viewModel.retryMeetingTranscription(failed)
        await retryTask.value

        XCTAssertEqual(mockRepo.fetchAllCalls.count, fetchAllCallCount)
        XCTAssertEqual(viewModel.transcriptions.map(\.id), loadedIDs)
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(viewModel.transcriptions.last?.status, .completed)
        XCTAssertNil(viewModel.transcriptions.last?.errorMessage)
    }

    // MARK: - Bulk Selection

    func testBeginBulkSelectionToggleClearAndExit() async throws {
        let first = Transcription(fileName: "first.mp3", status: .completed)
        let second = Transcription(fileName: "second.mp3", status: .completed)
        try repo.save(first)
        try repo.save(second)
        await load()

        vm.beginBulkSelection(startingWith: first)

        XCTAssertTrue(vm.isBulkSelectionModeEnabled)
        XCTAssertTrue(vm.isTranscriptionSelected(first))
        XCTAssertEqual(vm.selectedTranscriptionCount, 1)

        vm.toggleSelection(for: second)
        XCTAssertEqual(vm.selectedTranscriptionIDs, [first.id, second.id])

        vm.toggleSelection(for: first)
        XCTAssertEqual(vm.selectedTranscriptionIDs, [second.id])

        vm.clearSelection()
        XCTAssertTrue(vm.isBulkSelectionModeEnabled)
        XCTAssertTrue(vm.selectedTranscriptionIDs.isEmpty)

        vm.exitBulkSelection()
        XCTAssertFalse(vm.isBulkSelectionModeEnabled)
        XCTAssertTrue(vm.selectedTranscriptionIDs.isEmpty)
    }

    func testSelectLoadedVisibleTranscriptionsExcludesUnloadedRows() async throws {
        vm.pageSize = 2
        try repo.save(
            Transcription(createdAt: Date(timeIntervalSince1970: 3), fileName: "third.mp3", status: .completed))
        try repo.save(
            Transcription(createdAt: Date(timeIntervalSince1970: 2), fileName: "second.mp3", status: .completed))
        try repo.save(
            Transcription(createdAt: Date(timeIntervalSince1970: 1), fileName: "first.mp3", status: .completed))

        await load()

        XCTAssertEqual(vm.filteredTranscriptions.count, 2)
        XCTAssertTrue(vm.hasMore)

        vm.beginBulkSelection()
        vm.selectLoadedVisibleTranscriptions()

        XCTAssertEqual(vm.selectedTranscriptionIDs, Set(vm.filteredTranscriptions.map(\.id)))
        XCTAssertEqual(vm.selectedTranscriptionCount, 2)
        XCTAssertTrue(vm.areAllLoadedVisibleTranscriptionsSelected)
    }

    func testSelectLoadedVisibleTranscriptionsRespectsSearch() async throws {
        let matching = Transcription(fileName: "Swift Tutorial", status: .completed)
        let other = Transcription(fileName: "Python Basics", status: .completed)
        try repo.save(matching)
        try repo.save(other)

        vm.searchText = "swift"
        await load()

        vm.beginBulkSelection()
        vm.selectLoadedVisibleTranscriptions()

        XCTAssertEqual(vm.selectedTranscriptionIDs, [matching.id])
    }

    func testSelectedLoadedTranscriptionsForExportFollowsVisibleOrder() async throws {
        let first = Transcription(createdAt: Date(timeIntervalSince1970: 2), fileName: "first.mp3", status: .completed)
        let second = Transcription(
            createdAt: Date(timeIntervalSince1970: 1), fileName: "second.mp3", status: .completed)
        try repo.save(second)
        try repo.save(first)

        await load()

        vm.beginBulkSelection()
        vm.selectLoadedVisibleTranscriptions()

        XCTAssertEqual(vm.filteredTranscriptions.map(\.id), [first.id, second.id])
        XCTAssertEqual(vm.selectedLoadedTranscriptionsForExport.map(\.id), [first.id, second.id])
    }

    func testAllLoadedVisibleTranscriptionsSelectedWhenSearchHasNoMatches() async throws {
        let matching = Transcription(fileName: "Swift Tutorial", status: .completed)
        try repo.save(matching)

        await load()

        vm.beginBulkSelection(startingWith: matching)
        vm.searchText = "no matches"
        await load()

        XCTAssertTrue(vm.filteredTranscriptions.isEmpty)
        XCTAssertTrue(vm.selectedTranscriptionIDs.isEmpty)
        XCTAssertTrue(vm.areAllLoadedVisibleTranscriptionsSelected)
    }

    // MARK: - Delete

    func testDeleteTranscription() async throws {
        let t = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(t)
        await load()

        XCTAssertEqual(vm.transcriptions.count, 1)
        vm.deleteTranscription(t)
        XCTAssertEqual(vm.transcriptions.count, 0)

        let fetched = try repo.fetch(id: t.id)
        XCTAssertNil(fetched)
    }

    func testDeleteCleanupFailureKeepsTranscriptionRowAndListItem() async throws {
        try AppPaths.ensureDirectories()
        let protectedDir = URL(fileURLWithPath: AppPaths.youtubeDownloadsDir, isDirectory: true)
            .appendingPathComponent("library-protected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedDir, withIntermediateDirectories: true)
        let audioURL = protectedDir.appendingPathComponent("asset.m4a")
        _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDir.path)
            try? FileManager.default.removeItem(at: protectedDir)
        }

        let t = Transcription(
            fileName: "yt",
            filePath: audioURL.path,
            status: .completed,
            sourceType: .youtube
        )
        try repo.save(t)
        await load()

        vm.deleteTranscription(t)

        XCTAssertNotNil(try repo.fetch(id: t.id))
        XCTAssertEqual(vm.transcriptions.map(\.id), [t.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertNotNil(vm.errorMessage)
    }

    func testDeleteMeetingAudioKeepsTranscriptionAndClearsFilePath() async throws {
        try AppPaths.ensureDirectories()
        let folder = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent("library-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting-playback.m4a")
        let microphoneURL = folder.appendingPathComponent("microphone-raw.m4a")
        let notesURL = folder.appendingPathComponent("notes.md")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("mic".utf8)))
        try "meeting notes".write(to: notesURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: folder) }

        let t = Transcription(
            fileName: "Meeting",
            filePath: audioURL.path,
            status: .completed,
            sourceType: .meeting
        )
        try repo.save(t)
        await load()

        vm.deleteMeetingAudio(t)

        let fetched = try XCTUnwrap(repo.fetch(id: t.id))
        XCTAssertNil(fetched.filePath)
        XCTAssertEqual(fetched.meetingArtifactFolderPath, folder.standardizedFileURL.path)
        XCTAssertEqual(vm.transcriptions.first?.id, t.id)
        XCTAssertNil(vm.transcriptions.first?.filePath)
        XCTAssertEqual(vm.transcriptions.first?.meetingArtifactFolderPath, folder.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: notesURL.path))
    }

    func testDeleteMeetingAudioRefusesProcessingMeeting() async throws {
        try AppPaths.ensureDirectories()
        let folder = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent("library-processing-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting-playback.m4a")
        let microphoneURL = folder.appendingPathComponent("microphone-raw.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: microphoneURL.path, contents: Data("mic".utf8)))
        defer { try? FileManager.default.removeItem(at: folder) }

        let t = Transcription(
            fileName: "Meeting",
            filePath: audioURL.path,
            status: .processing,
            sourceType: .meeting
        )
        try repo.save(t)
        await load()

        XCTAssertTrue(MeetingAudioFile.isAvailable(for: t))
        XCTAssertFalse(MeetingAudioFile.isRemovable(for: t))
        vm.deleteMeetingAudio(t)

        let fetched = try XCTUnwrap(repo.fetch(id: t.id))
        XCTAssertEqual(fetched.filePath, audioURL.path)
        XCTAssertNil(fetched.meetingArtifactFolderPath)
        XCTAssertEqual(vm.transcriptions.first?.filePath, audioURL.path)
        XCTAssertEqual(
            vm.errorMessage,
            TranscriptionAssetCleanup.meetingAudioFinalizationInProgressMessage
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
    }

    func testConfirmBulkOperationRunsAfterPendingClearedByAlertDismissal() async throws {
        // Reproduces the alert race: tapping the destructive confirm button
        // dismisses the alert, whose isPresented setter nils pendingBulkOperation
        // (via cancelPendingBulkOperation) BEFORE the deferred Task body runs.
        // The view captures the operation synchronously and calls
        // confirmBulkOperation(_:), which must still delete even though
        // pendingBulkOperation is already nil. Re-reading the pending state here
        // (the old behavior) would no-op and nothing would delete.
        let first = Transcription(fileName: "first.mp3", status: .completed)
        let second = Transcription(fileName: "second.mp3", status: .completed)
        try repo.save(first)
        try repo.save(second)
        await load()

        vm.beginBulkSelection(startingWith: first)
        vm.toggleSelection(for: second)
        vm.requestDeleteSelectedItems()

        // Snapshot as the view's button action does, then simulate the alert's
        // dismissal clearing the pending state out from under the deferred Task.
        let operation = try XCTUnwrap(vm.pendingBulkOperation)
        vm.cancelPendingBulkOperation()
        XCTAssertNil(vm.pendingBulkOperation)

        let result = await vm.confirmBulkOperation(operation)

        XCTAssertEqual(result, BulkOperationResult(succeeded: 2, failed: 0))
        XCTAssertNil(try repo.fetch(id: first.id))
        XCTAssertNil(try repo.fetch(id: second.id))
        XCTAssertTrue(vm.transcriptions.isEmpty)
        XCTAssertFalse(vm.isBulkOperationInProgress)
        XCTAssertFalse(vm.isBulkSelectionModeEnabled)
        XCTAssertTrue(vm.selectedTranscriptionIDs.isEmpty)
    }

    func testBulkDeleteSelectedItemsRemovesRowsAndExitsMode() async throws {
        let first = Transcription(fileName: "first.mp3", status: .completed)
        let second = Transcription(fileName: "second.mp3", status: .completed)
        try repo.save(first)
        try repo.save(second)
        await load()

        vm.beginBulkSelection(startingWith: first)
        vm.toggleSelection(for: second)
        vm.requestDeleteSelectedItems()

        let result = await vm.confirmPendingBulkOperation()

        XCTAssertEqual(result, BulkOperationResult(succeeded: 2, failed: 0))
        XCTAssertNil(try repo.fetch(id: first.id))
        XCTAssertNil(try repo.fetch(id: second.id))
        XCTAssertTrue(vm.transcriptions.isEmpty)
        XCTAssertFalse(vm.isBulkOperationInProgress)
        XCTAssertFalse(vm.isBulkSelectionModeEnabled)
        XCTAssertTrue(vm.selectedTranscriptionIDs.isEmpty)
    }

    func testBulkDeletePartialFailureKeepsFailedRowSelected() async throws {
        try AppPaths.ensureDirectories()
        let protectedDir = URL(fileURLWithPath: AppPaths.youtubeDownloadsDir, isDirectory: true)
            .appendingPathComponent("library-bulk-protected-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: protectedDir, withIntermediateDirectories: true)
        let audioURL = protectedDir.appendingPathComponent("asset.m4a")
        _ = FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: protectedDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: protectedDir.path)
            try? FileManager.default.removeItem(at: protectedDir)
        }

        let good = Transcription(fileName: "good.mp3", status: .completed, sourceType: .file)
        let failing = Transcription(
            fileName: "yt",
            filePath: audioURL.path,
            status: .completed,
            sourceType: .youtube
        )
        try repo.save(good)
        try repo.save(failing)
        await load()

        vm.beginBulkSelection(startingWith: good)
        vm.toggleSelection(for: failing)
        vm.requestDeleteSelectedItems()

        let result = await vm.confirmPendingBulkOperation()

        XCTAssertEqual(result, BulkOperationResult(succeeded: 1, failed: 1))
        XCTAssertNil(try repo.fetch(id: good.id))
        XCTAssertNotNil(try repo.fetch(id: failing.id))
        XCTAssertEqual(vm.transcriptions.map(\.id), [failing.id])
        XCTAssertFalse(vm.isBulkOperationInProgress)
        XCTAssertTrue(vm.isBulkSelectionModeEnabled)
        XCTAssertEqual(vm.selectedTranscriptionIDs, [failing.id])
        XCTAssertNotNil(vm.errorMessage)
    }

    func testBulkDeleteKeepsSelectionModeAndIgnoresSelectionChangesWhileInProgress() async throws {
        let failing = Transcription(fileName: "failing.mp3", status: .completed, sourceType: .file)
        let newSelection = Transcription(fileName: "new.mp3", status: .completed, sourceType: .file)
        let deleteGate = DeleteGate()
        let blockingRepo = MockTranscriptionRepository()
        blockingRepo.transcriptions = [failing, newSelection]
        blockingRepo.deleteResult = false
        blockingRepo.onDelete = { _ in
            deleteGate.blockUntilAllowed()
        }
        let blockingVM = TranscriptionLibraryViewModel()
        blockingVM.configure(transcriptionRepo: blockingRepo)
        await load(blockingVM)

        blockingVM.beginBulkSelection(startingWith: failing)
        blockingVM.requestDeleteSelectedItems()

        let operation = Task {
            await blockingVM.confirmPendingBulkOperation()
        }
        await Task.detached {
            deleteGate.waitForDeleteStarted()
        }.value

        XCTAssertTrue(blockingVM.isBulkOperationInProgress)
        XCTAssertTrue(blockingVM.isBulkSelectionModeEnabled)
        XCTAssertEqual(blockingVM.selectedTranscriptionIDs, [failing.id])

        blockingVM.beginBulkSelection(startingWith: newSelection)
        blockingVM.toggleSelection(for: newSelection)
        XCTAssertEqual(blockingVM.selectedTranscriptionIDs, [failing.id])

        deleteGate.allowFinish()
        let result = await operation.value

        XCTAssertEqual(result, BulkOperationResult(succeeded: 0, failed: 1))
        XCTAssertFalse(blockingVM.isBulkOperationInProgress)
        XCTAssertTrue(blockingVM.isBulkSelectionModeEnabled)
        XCTAssertEqual(blockingVM.selectedTranscriptionIDs, [failing.id])
        XCTAssertNotNil(blockingVM.errorMessage)
    }

    func testBulkDeleteAudioOnlyClearsMeetingAudioAndSkipsIneligibleSelection() async throws {
        try AppPaths.ensureDirectories()
        let folder = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent("library-bulk-meeting-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting-playback.m4a")
        let systemURL = folder.appendingPathComponent("system-raw.m4a")
        let manifestURL = folder.appendingPathComponent(MeetingArtifactStore.manifestFileName)
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: systemURL.path, contents: Data("system".utf8)))
        try Data(#"{"schema":"com.macparakeet.meeting-session"}"#.utf8).write(to: manifestURL)
        defer { try? FileManager.default.removeItem(at: folder) }

        let meeting = Transcription(
            fileName: "Meeting",
            filePath: audioURL.path,
            status: .completed,
            sourceType: .meeting
        )
        let meetingWithoutAudio = Transcription(
            fileName: "No Audio",
            status: .completed,
            sourceType: .meeting
        )
        let local = Transcription(fileName: "local.mp3", status: .completed, sourceType: .file)
        try repo.save(meeting)
        try repo.save(meetingWithoutAudio)
        try repo.save(local)
        await load()

        vm.beginBulkSelection(startingWith: meeting)
        vm.toggleSelection(for: meetingWithoutAudio)
        vm.toggleSelection(for: local)

        XCTAssertEqual(vm.selectedMeetingAudioCount, 1)
        vm.requestDeleteSelectedMeetingAudio()
        let result = await vm.confirmPendingBulkOperation()

        // skipped counts only the audio-less meeting; the non-meeting `local`
        // file is ineligible for meeting-audio removal and must not inflate it.
        XCTAssertEqual(result, BulkOperationResult(succeeded: 1, failed: 0, skipped: 1))
        XCTAssertFalse(vm.isBulkOperationInProgress)
        XCTAssertFalse(vm.isBulkSelectionModeEnabled)
        XCTAssertTrue(vm.selectedTranscriptionIDs.isEmpty)
        let fetchedMeeting = try XCTUnwrap(repo.fetch(id: meeting.id))
        XCTAssertNil(fetchedMeeting.filePath)
        XCTAssertEqual(fetchedMeeting.meetingArtifactFolderPath, folder.standardizedFileURL.path)
        XCTAssertNotNil(try repo.fetch(id: meetingWithoutAudio.id))
        XCTAssertNotNil(try repo.fetch(id: local.id))
        XCTAssertEqual(vm.transcriptions.count, 3)
        let visibleMeeting = try XCTUnwrap(vm.transcriptions.first(where: { $0.id == meeting.id }))
        XCTAssertNil(visibleMeeting.filePath)
        XCTAssertEqual(visibleMeeting.meetingArtifactFolderPath, folder.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: audioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testRequestDeleteAudioOnlySkipCountExcludesNonMeetings() async throws {
        // Mixed Library selection: meetings and non-meetings together. The
        // "Remove Audio" skipped count must reflect meetings-without-removable-audio
        // only, so the confirmation copy never mislabels videos/podcasts/local
        // files as skipped meetings.
        try AppPaths.ensureDirectories()
        let folder = URL(fileURLWithPath: AppPaths.meetingRecordingsDir, isDirectory: true)
            .appendingPathComponent("library-mixed-skip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting-playback.m4a")
        let processingAudioURL = folder.appendingPathComponent("processing-meeting-playback.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        XCTAssertTrue(FileManager.default.createFile(atPath: processingAudioURL.path, contents: Data("audio".utf8)))
        defer { try? FileManager.default.removeItem(at: folder) }

        let meetingWithAudio = Transcription(
            fileName: "Meeting",
            filePath: audioURL.path,
            status: .completed,
            sourceType: .meeting
        )
        let meetingWithoutAudio = Transcription(fileName: "No Audio", status: .completed, sourceType: .meeting)
        let processingMeeting = Transcription(
            fileName: "Processing",
            filePath: processingAudioURL.path,
            status: .processing,
            sourceType: .meeting
        )
        let youtube = Transcription(
            fileName: "video",
            status: .completed,
            sourceURL: "https://youtube.com/watch?v=abc",
            sourceType: .youtube
        )
        let podcast = Transcription(fileName: "episode", status: .completed, sourceType: .podcast)
        let local = Transcription(fileName: "local.mp3", status: .completed, sourceType: .file)
        for transcription in [meetingWithAudio, meetingWithoutAudio, processingMeeting, youtube, podcast, local] {
            try repo.save(transcription)
        }
        await load()

        vm.beginBulkSelection(startingWith: meetingWithAudio)
        for transcription in [meetingWithoutAudio, processingMeeting, youtube, podcast, local] {
            vm.toggleSelection(for: transcription)
        }

        XCTAssertEqual(vm.selectedTranscriptionCount, 6)
        XCTAssertEqual(vm.selectedMeetingAudioCount, 1)
        vm.requestDeleteSelectedMeetingAudio()
        let operation = try XCTUnwrap(vm.pendingBulkOperation)
        XCTAssertTrue(operation.isDeleteAudioOnly)
        XCTAssertEqual(operation.targetCount, 1)
        // Only the audio-less and still-processing meetings are skipped — the
        // three non-meeting items are not counted (the old behavior reported 5).
        XCTAssertEqual(operation.skippedCount, 2)
    }
}

private enum LibraryRenameTestError: Error {
    case reloadFailed
    case persistenceFailed
}

private final class StaleFetchGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private let firstFetchStarted = DispatchSemaphore(value: 0)
    private let allowFirstFetch = DispatchSemaphore(value: 0)

    func nextCallNumber() -> Int {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        return callCount
    }

    func blockFirstFetchUntilAllowed() {
        firstFetchStarted.signal()
        allowFirstFetch.wait()
    }

    func waitForFirstFetchStarted() {
        firstFetchStarted.wait()
    }

    func allowFirstFetchToFinish() {
        allowFirstFetch.signal()
    }
}

private final class DeleteGate: @unchecked Sendable {
    private let deleteStarted = DispatchSemaphore(value: 0)
    private let allowDelete = DispatchSemaphore(value: 0)

    func blockUntilAllowed() {
        deleteStarted.signal()
        allowDelete.wait()
    }

    func waitForDeleteStarted() {
        deleteStarted.wait()
    }

    func allowFinish() {
        allowDelete.signal()
    }
}
