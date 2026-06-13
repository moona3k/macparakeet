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
        XCTAssertTrue(FileManager.default.createFile(atPath: audioURL.path, contents: Data("audio".utf8)))
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
        XCTAssertEqual(vm.transcriptions.first?.id, t.id)
        XCTAssertNil(vm.transcriptions.first?.filePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
}
