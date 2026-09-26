import XCTest
@testable import MacParakeetCore
@testable import MacParakeetViewModels

@MainActor
final class LibrarySourceLabelStyleTests: XCTestCase {
    /// A hidden label is safe only when the actual rows belong to the selected
    /// source. Exercise query narrowing and displayed attribution together.
    func testLoadedSourcesAndLabelStyleForEveryScopeAndFilter() async throws {
        let database = try DatabaseManager()
        let repository = TranscriptionRepository(dbQueue: database.dbQueue)
        let local = Transcription(fileName: "local.wav", status: .completed, sourceType: .file)
        let favoriteLocal = Transcription(
            fileName: "favorite.wav", status: .completed, isFavorite: true, sourceType: .file)
        let video = Transcription(
            fileName: "video.mp4", status: .completed,
            sourceURL: "https://youtube.com/watch?v=example", sourceType: .youtube)
        let favoriteVideo = Transcription(
            fileName: "favorite-video.mp4", status: .completed,
            sourceURL: "https://vimeo.com/123456", isFavorite: true, sourceType: .youtube)
        let podcast = Transcription(fileName: "podcast.mp3", status: .completed, sourceType: .podcast)
        let favoritePodcast = Transcription(
            fileName: "favorite-podcast.mp3", status: .completed, isFavorite: true, sourceType: .podcast)
        let meeting = Transcription(fileName: "meeting.m4a", status: .completed, sourceType: .meeting)
        let favoriteMeeting = Transcription(
            fileName: "favorite-meeting.m4a", status: .completed, isFavorite: true, sourceType: .meeting)
        let rows = [local, favoriteLocal, video, favoriteVideo, podcast, favoritePodcast, meeting, favoriteMeeting]
        for row in rows {
            try repository.save(row)
        }

        let cases: [(TranscriptionLibraryScope, LibraryFilter, [UUID], LibrarySourceLabelStyle)] = [
            (.all, .all, rows.map(\.id), .visible),
            (.all, .favorites, [favoriteLocal.id, favoriteVideo.id, favoritePodcast.id, favoriteMeeting.id], .visible),
            (.all, .youtube, [video.id, favoriteVideo.id], .brandMarkOnly),
            (.all, .podcast, [podcast.id, favoritePodcast.id], .hidden),
            (.all, .local, [local.id, favoriteLocal.id], .hidden),
            (.all, .meeting, [meeting.id, favoriteMeeting.id], .hidden),
            (.meetings, .all, [meeting.id, favoriteMeeting.id], .hidden),
            (.meetings, .favorites, [favoriteMeeting.id], .hidden),
            (.meetings, .youtube, [], .hidden),
            (.meetings, .podcast, [], .hidden),
            (.meetings, .local, [], .hidden),
            (.meetings, .meeting, [meeting.id, favoriteMeeting.id], .hidden),
        ]

        for (scope, filter, expectedIDs, style) in cases {
            let viewModel = TranscriptionLibraryViewModel(scope: scope)
            viewModel.configure(transcriptionRepo: repository)
            viewModel.filter = filter
            await viewModel.loadTranscriptions().value

            let context = "scope=\(scope), filter=\(filter.rawValue)"
            XCTAssertEqual(Set(viewModel.filteredTranscriptions.map(\.id)), Set(expectedIDs), context)
            XCTAssertEqual(viewModel.filteredTranscriptions.count, expectedIDs.count, context)
            XCTAssertEqual(viewModel.displayedSourceLabelStyle, style, context)
        }
        XCTAssertEqual(cases.count, 2 * LibraryFilter.allCases.count, "Cover every scope and filter pair")
    }
}
