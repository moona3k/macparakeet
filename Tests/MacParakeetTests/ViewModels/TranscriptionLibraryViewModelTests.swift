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

    func testLoadTranscriptionsExcludesProcessingRows() async throws {
        try repo.save(Transcription(fileName: "done.mp3", status: .completed))
        try repo.save(Transcription(fileName: "working.mp3", status: .processing))

        await load()

        XCTAssertEqual(vm.transcriptions.map(\.fileName), ["done.mp3"])
        XCTAssertEqual(vm.filteredTranscriptions.map(\.fileName), ["done.mp3"])
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
        try repo.save(Transcription(fileName: "local.mp3", status: .completed, sourceType: .file))

        await load(meetingVM)

        XCTAssertEqual(meetingVM.filteredTranscriptions.map(\.fileName), ["meeting.mp3"])
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
        let audioURL = folder.appendingPathComponent("meeting.m4a")
        let microphoneURL = folder.appendingPathComponent("microphone.m4a")
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
        let audioURL = folder.appendingPathComponent("meeting.m4a")
        let systemURL = folder.appendingPathComponent("system.m4a")
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

        XCTAssertEqual(result, BulkOperationResult(succeeded: 1, failed: 0, skipped: 2))
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
