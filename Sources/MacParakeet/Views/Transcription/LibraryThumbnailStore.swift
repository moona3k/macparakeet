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
        /// Artwork already saved in the thumbnail cache, with the remote
        /// artwork to fetch again if the saved file cannot be decoded.
        case cachedFile(URL, remoteFallback: URL?)
        /// Artwork that must be downloaded (and saved) first.
        case remote(URL)
    }

    /// Longest side of a decoded thumbnail. Covers the widest adaptive grid
    /// card at 2x without holding full-size bitmaps.
    nonisolated static let maxPixelSize = 800

    private let thumbnailCache: any ThumbnailCaching
    private let images = NSCache<NSUUID, DecodedThumbnail>()
    private var inFlight: [UUID: Task<CGImage?, Never>] = [:]

    init(thumbnailCache: any ThumbnailCaching = ThumbnailCacheService.shared) {
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
        let remote = Self.remoteURL(for: transcription)
        if let file = thumbnailCache.cachedThumbnail(for: transcription.id) {
            return .cachedFile(file, remoteFallback: remote)
        }
        return remote.map(Source.remote)
    }

    private static func remoteURL(for transcription: Transcription) -> URL? {
        if let urlString = transcription.thumbnailURL, let url = URL(string: urlString) {
            return url
        }
        if let sourceURL = transcription.sourceURL,
            let videoID = YouTubeURLValidator.extractVideoID(sourceURL)
        {
            return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
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
        thumbnailCache: any ThumbnailCaching
    ) async -> CGImage? {
        switch source {
        case .cachedFile(let file, let remoteFallback):
            if let image = ThumbnailImageDecoder.image(contentsOf: file, maxPixelSize: maxPixelSize) {
                return image
            }
            guard let remoteFallback else { return nil }
            // A damaged cache file (a partial write, say) must not hide
            // artwork that can still be fetched.
            thumbnailCache.deleteThumbnail(for: id)
            return await download(remoteFallback, for: id, thumbnailCache: thumbnailCache)
        case .remote(let url):
            return await download(url, for: id, thumbnailCache: thumbnailCache)
        }
    }

    nonisolated private static func download(
        _ url: URL,
        for id: UUID,
        thumbnailCache: any ThumbnailCaching
    ) async -> CGImage? {
        guard let file = try? await thumbnailCache.downloadThumbnail(from: url.absoluteString, for: id) else {
            return nil
        }
        return ThumbnailImageDecoder.image(contentsOf: file, maxPixelSize: maxPixelSize)
    }
}

private final class DecodedThumbnail {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
