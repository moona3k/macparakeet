import CoreGraphics
import Foundation
import MacParakeetCore

/// Decoded Library artwork shared by every thumbnail card.
///
/// Each recording's artwork is decoded once, off the main actor, at card
/// size, and kept in memory. Cards read the decoded image, so scrolling a
/// row back into view or hovering a card never touches the disk or the JPEG
/// decoder on the main thread.
@MainActor
final class LibraryThumbnailStore {
    static let shared = LibraryThumbnailStore()

    /// Where a recording's artwork comes from.
    enum Source: Hashable, Sendable {
        /// Artwork already saved in the thumbnail cache.
        case cachedFile(URL)
        /// Artwork that must be downloaded (and saved) first.
        case remote(URL)
    }

    /// Longest side of a decoded thumbnail. Covers the widest adaptive grid
    /// card at 2x without holding full-size bitmaps.
    nonisolated static let maxPixelSize = 800

    private let thumbnailCache: ThumbnailCacheService
    private let images = NSCache<NSUUID, DecodedThumbnail>()
    private var inFlight: [UUID: Task<CGImage?, Never>] = [:]

    init(thumbnailCache: ThumbnailCacheService = .shared) {
        self.thumbnailCache = thumbnailCache
        images.countLimit = 160
        images.totalCostLimit = 128 * 1024 * 1024
    }

    func cachedImage(for id: UUID) -> CGImage? {
        images.object(forKey: id as NSUUID)?.image
    }

    /// Resolves where artwork for `transcription` can be loaded from, or
    /// `nil` when it has none. Costs one file-existence check.
    func source(for transcription: Transcription) -> Source? {
        if let file = thumbnailCache.cachedThumbnail(for: transcription.id) {
            return .cachedFile(file)
        }
        if let urlString = transcription.thumbnailURL, let url = URL(string: urlString) {
            return .remote(url)
        }
        if let sourceURL = transcription.sourceURL,
            let videoID = YouTubeURLValidator.extractVideoID(sourceURL)
        {
            return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg").map(Source.remote)
        }
        return nil
    }

    /// Returns the decoded artwork, downloading it first for a remote
    /// source. Concurrent requests for one recording share a single load.
    func image(for id: UUID, from source: Source) async -> CGImage? {
        if let cached = cachedImage(for: id) {
            return cached
        }
        if let pending = inFlight[id] {
            return await pending.value
        }

        let thumbnailCache = self.thumbnailCache
        let task = Task.detached(priority: .userInitiated) {
            await Self.decode(source, for: id, thumbnailCache: thumbnailCache)
        }
        inFlight[id] = task
        let image = await task.value
        inFlight[id] = nil

        if let image {
            images.setObject(
                DecodedThumbnail(image),
                forKey: id as NSUUID,
                cost: image.bytesPerRow * image.height
            )
        }
        return image
    }

    nonisolated private static func decode(
        _ source: Source,
        for id: UUID,
        thumbnailCache: ThumbnailCacheService
    ) async -> CGImage? {
        let fileURL: URL
        switch source {
        case .cachedFile(let url):
            fileURL = url
        case .remote(let url):
            guard let downloaded = try? await thumbnailCache.downloadThumbnail(from: url.absoluteString, for: id)
            else {
                return nil
            }
            fileURL = downloaded
        }
        return ThumbnailImageDecoder.image(contentsOf: fileURL, maxPixelSize: maxPixelSize)
    }
}

private final class DecodedThumbnail {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
