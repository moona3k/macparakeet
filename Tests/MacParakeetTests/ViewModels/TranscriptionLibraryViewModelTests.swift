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

    func testMeetingRowFileStateIsCachedUntilLoadedStatusRefresh() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-row-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audioURL = folder.appendingPathComponent("meeting-playback.m4a")
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
        defer { try? FileManager.default.removeItem(at: folder) }

        let meeting = Transcription(
            fileName: "Meeting",
            filePath: audioURL.path,
            status: .processing,
            sourceType: .meeting
        )
        try repo.save(meeting)
        await load()

        let loaded = try XCTUnwrap(vm.transcriptions.first)
        let cached = vm.meetingRowFileState(for: loaded)
        XCTAssertEqual(cached.audioState, .saved)
        XCTAssertFalse(cached.isAudioRemovable)
        XCTAssertTrue(cached.isArtifactFolderAvailable)

        try FileManager.default.removeItem(at: audioURL)

        // Rendering reads the snapshot rather than re-statting the filesystem.
        XCTAssertEqual(vm.meetingRowFileState(for: loaded), cached)

        try repo.updateStatus(id: meeting.id, status: .completed, errorMessage: nil)
        await load()

        let refreshed = try XCTUnwrap(vm.transcriptions.first)
        XCTAssertEqual(vm.meetingRowFileState(for: refreshed).audioState, .missing)
        XCTAssertFalse(vm.meetingRowFileState(for: refreshed).isAudioRemovable)
    }

    // MARK: - Filter

    func testFilterAll() async throws {
        try repo.save(Transcription(fileName: "local.mp3", status: .completed))
        try repo.save(Transcription(
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
        try repo.save(Transcription(
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
        try repo.save(Transcription(fileName: "youtube.mp3", status: .completed, sourceURL: "https://youtube.com/watch?v=abc", sourceType: .youtube))
        try repo.save(Transcription(
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
        try repo.save(Transcription(fileName: "youtube.mp3", status: .completed, sourceURL: "https://youtube.com/watch?v=abc", sourceType: .youtube))

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

        try repo.save(Transcription(fileName: "fav meeting.mp3", status: .completed, isFavorite: true, sourceType: .meeting))
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
        try repo.save(Transcription(
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
        vm.renameTranscriptionTitle(vm.transcriptions[0], to: "Auto Derived Title")

        let loaded = try XCTUnwrap(vm.transcriptions.first)
        XCTAssertNil(loaded.titleOverride)
        XCTAssertEqual(loaded.effectiveDisplayTitle, "Auto Derived Title")
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
        try repo.save(Transcription(createdAt: Date(timeIntervalSince1970: 3), fileName: "third.mp3", status: .completed))
        try repo.save(Transcription(createdAt: Date(timeIntervalSince1970: 2), fileName: "second.mp3", status: .completed))
        try repo.save(Transcription(createdAt: Date(timeIntervalSince1970: 1), fileName: "first.mp3", status: .completed))

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
        let second = Transcription(createdAt: Date(timeIntervalSince1970: 1), fileName: "second.mp3", status: .completed)
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
        let rowState = vm.meetingRowFileState(for: try XCTUnwrap(vm.transcriptions.first))
        XCTAssertEqual(rowState.audioState, .removed)
        XCTAssertFalse(rowState.isAudioRemovable)
        XCTAssertTrue(rowState.isArtifactFolderAvailable)
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
