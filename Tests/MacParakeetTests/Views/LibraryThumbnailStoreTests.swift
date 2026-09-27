import Foundation
import XCTest
@testable import MacParakeet
@testable import MacParakeetCore

@MainActor
final class LibraryThumbnailStoreTests: XCTestCase {
    private var cacheDir: URL!
    private var cache: FakeThumbnailCache!
    private var store: LibraryThumbnailStore!

    override func setUp() async throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("library-thumbnail-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        cache = FakeThumbnailCache(directory: cacheDir)
        store = LibraryThumbnailStore(thumbnailCache: cache)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: cacheDir)
    }

    func testDecodesCachedArtworkAtCardSizeAndKeepsItInMemory() async throws {
        let transcription = Transcription(fileName: "local.mp4", status: .completed)
        try TestJPEG.write(width: 1920, height: 1080, to: cache.fileURL(for: transcription.id))

        let source = try XCTUnwrap(store.source(for: transcription))
        let loaded = await store.image(for: transcription.id, from: source)
        let image = try XCTUnwrap(loaded)

        XCTAssertEqual(max(image.width, image.height), LibraryThumbnailStore.maxPixelSize)
        XCTAssertNotNil(store.cachedImage(for: transcription.id))
        XCTAssertEqual(cache.downloadCount, 0)
    }

    func testUndecodableCacheFileFallsBackToRemoteArtwork() async throws {
        let transcription = Transcription(
            fileName: "video.mp3",
            status: .completed,
            thumbnailURL: "https://example.com/artwork.jpg",
            sourceType: .youtube
        )
        try Data("partial write".utf8).write(to: cache.fileURL(for: transcription.id))

        let source = try XCTUnwrap(store.source(for: transcription))
        let image = await store.image(for: transcription.id, from: source)

        XCTAssertNotNil(image)
        XCTAssertEqual(cache.deleteCount, 1)
        XCTAssertEqual(cache.downloadCount, 1)
    }

    func testUndecodableCacheFileWithoutRemoteArtworkLoadsNothing() async throws {
        let transcription = Transcription(fileName: "local.mp4", status: .completed)
        try Data("partial write".utf8).write(to: cache.fileURL(for: transcription.id))

        let source = try XCTUnwrap(store.source(for: transcription))
        let image = await store.image(for: transcription.id, from: source)

        XCTAssertNil(image)
        XCTAssertEqual(cache.deleteCount, 0)
    }

    func testConcurrentRequestsShareOneDownload() async throws {
        let transcription = Transcription(
            fileName: "video.mp3",
            status: .completed,
            thumbnailURL: "https://example.com/artwork.jpg",
            sourceType: .youtube
        )
        let source = try XCTUnwrap(store.source(for: transcription))
        guard case .remote = source else { return XCTFail("Expected a remote source, got \(source)") }

        async let first = store.image(for: transcription.id, from: source)
        async let second = store.image(for: transcription.id, from: source)
        let images = await [first, second]

        XCTAssertTrue(images.allSatisfy { $0 != nil })
        XCTAssertEqual(cache.downloadCount, 1)
    }

    func testRecordingWithoutArtworkHasNoSource() {
        let transcription = Transcription(fileName: "voice-memo.m4a", status: .completed)

        XCTAssertNil(store.source(for: transcription))
    }
}

/// Thumbnail cache backed by a temporary directory whose downloads write a
/// valid JPEG instead of touching the network.
private final class FakeThumbnailCache: ThumbnailCaching, @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private var downloads = 0
    private var deletes = 0

    init(directory: URL) {
        self.directory = directory
    }

    var downloadCount: Int { lock.withLock { downloads } }
    var deleteCount: Int { lock.withLock { deletes } }

    func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }

    func cachedThumbnail(for transcriptionId: UUID) -> URL? {
        let url = fileURL(for: transcriptionId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func cacheThumbnailData(_ data: Data, for transcriptionId: UUID) throws -> URL {
        let url = fileURL(for: transcriptionId)
        try data.write(to: url)
        return url
    }

    func downloadThumbnail(from urlString: String, for transcriptionId: UUID) async throws -> URL {
        if let cached = cachedThumbnail(for: transcriptionId) {
            return cached
        }
        lock.withLock { downloads += 1 }
        let url = fileURL(for: transcriptionId)
        try TestJPEG.write(width: 1280, height: 720, to: url)
        return url
    }

    func extractVideoFrame(from videoPath: String, for transcriptionId: UUID) async throws -> URL {
        throw ThumbnailError.extractionFailed
    }

    func deleteThumbnail(for transcriptionId: UUID) {
        lock.withLock { deletes += 1 }
        try? FileManager.default.removeItem(at: fileURL(for: transcriptionId))
    }
}
