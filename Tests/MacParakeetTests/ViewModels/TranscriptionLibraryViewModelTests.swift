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

    // MARK: - Load

    func testLoadTranscriptions() throws {
        try repo.save(Transcription(fileName: "a.mp3", status: .completed))
        try repo.save(Transcription(fileName: "b.mp3", status: .completed))

        vm.loadTranscriptions()
        XCTAssertEqual(vm.transcriptions.count, 2)
    }

    func testLoadTranscriptionsExcludesProcessingRows() throws {
        try repo.save(Transcription(fileName: "done.mp3", status: .completed))
        try repo.save(Transcription(fileName: "working.mp3", status: .processing))

        vm.loadTranscriptions()

        XCTAssertEqual(vm.transcriptions.map(\.fileName), ["done.mp3"])
        XCTAssertEqual(vm.filteredTranscriptions.map(\.fileName), ["done.mp3"])
    }

    func testLoadTranscriptionsExcludesCancelledAndErrorRows() throws {
        try repo.save(Transcription(fileName: "done.mp3", status: .completed))
        try repo.save(Transcription(fileName: "cancelled.mp3", status: .cancelled))
        try repo.save(Transcription(fileName: "failed.mp3", status: .error, errorMessage: "boom"))

        vm.loadTranscriptions()

        XCTAssertEqual(vm.transcriptions.count, 3)
        XCTAssertEqual(Set(vm.transcriptions.map(\.fileName)), ["done.mp3", "cancelled.mp3", "failed.mp3"])
        XCTAssertEqual(vm.filteredTranscriptions.count, 3)
        XCTAssertEqual(Set(vm.filteredTranscriptions.map(\.fileName)), ["done.mp3", "cancelled.mp3", "failed.mp3"])
    }

    // MARK: - Filter

    func testFilterAll() throws {
        try repo.save(Transcription(fileName: "local.mp3", status: .completed))
        try repo.save(Transcription(fileName: "youtube.mp3", status: .completed, sourceURL: "https://youtube.com/watch?v=abc"))
        vm.loadTranscriptions()

        vm.filter = .all
        XCTAssertEqual(vm.filteredTranscriptions.count, 2)
    }

    func testFilterYouTube() throws {
        try repo.save(Transcription(fileName: "local.mp3", status: .completed))
        try repo.save(Transcription(fileName: "youtube.mp3", status: .completed, sourceURL: "https://youtube.com/watch?v=abc"))
        vm.loadTranscriptions()

        vm.filter = .youtube
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "youtube.mp3")
    }

    func testFilterLocal() throws {
        try repo.save(Transcription(fileName: "local.mp3", status: .completed))
        try repo.save(Transcription(fileName: "youtube.mp3", status: .completed, sourceURL: "https://youtube.com/watch?v=abc"))
        vm.loadTranscriptions()

        vm.filter = .local
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "local.mp3")
    }

    func testFilterFavorites() throws {
        try repo.save(Transcription(fileName: "fav.mp3", status: .completed, isFavorite: true))
        try repo.save(Transcription(fileName: "normal.mp3", status: .completed))
        vm.loadTranscriptions()

        vm.filter = .favorites
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "fav.mp3")
    }

    // MARK: - Search

    func testSearchByTitle() throws {
        try repo.save(Transcription(fileName: "Swift Tutorial", status: .completed))
        try repo.save(Transcription(fileName: "Python Basics", status: .completed))
        vm.loadTranscriptions()

        vm.searchText = "swift"
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "Swift Tutorial")
    }

    func testSearchByTranscript() throws {
        var t = Transcription(fileName: "Recording", status: .completed)
        t.rawTranscript = "The quick brown fox jumps over the lazy dog"
        try repo.save(t)

        try repo.save(Transcription(fileName: "Other", status: .completed))
        vm.loadTranscriptions()

        vm.searchText = "brown fox"
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "Recording")
    }

    func testSearchByChannel() throws {
        try repo.save(Transcription(
            fileName: "Video",
            status: .completed,
            sourceURL: "https://youtube.com/watch?v=abc",
            channelName: "TechChannel"
        ))
        try repo.save(Transcription(fileName: "Other", status: .completed))
        vm.loadTranscriptions()

        vm.searchText = "techchannel"
        XCTAssertEqual(vm.filteredTranscriptions.count, 1)
    }

    // MARK: - Sort

    func testSortDateDescending() throws {
        let older = Transcription(createdAt: Date().addingTimeInterval(-100), fileName: "older.mp3", status: .completed)
        let newer = Transcription(createdAt: Date(), fileName: "newer.mp3", status: .completed)
        try repo.save(older)
        try repo.save(newer)
        vm.loadTranscriptions()

        vm.sortOrder = .dateDescending
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "newer.mp3")
    }

    func testSortTitleAscending() throws {
        try repo.save(Transcription(fileName: "Banana.mp3", status: .completed))
        try repo.save(Transcription(fileName: "Apple.mp3", status: .completed))
        vm.loadTranscriptions()

        vm.sortOrder = .titleAscending
        XCTAssertEqual(vm.filteredTranscriptions.first?.fileName, "Apple.mp3")
    }

    // MARK: - Favorites

    func testToggleFavorite() throws {
        let t = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(t)
        vm.loadTranscriptions()

        XCTAssertFalse(vm.transcriptions[0].isFavorite)
        vm.toggleFavorite(vm.transcriptions[0])
        XCTAssertTrue(vm.transcriptions[0].isFavorite)

        // Verify persisted
        let fetched = try repo.fetch(id: t.id)
        XCTAssertTrue(fetched?.isFavorite ?? false)
    }

    // MARK: - Delete

    func testDeleteTranscription() throws {
        let t = Transcription(fileName: "test.mp3", status: .completed)
        try repo.save(t)
        vm.loadTranscriptions()

        XCTAssertEqual(vm.transcriptions.count, 1)
        vm.deleteTranscription(t)
        XCTAssertEqual(vm.transcriptions.count, 0)

        let fetched = try repo.fetch(id: t.id)
        XCTAssertNil(fetched)
    }
}
