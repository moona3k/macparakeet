import Foundation
import os

public final class ThumbnailCacheService: Sendable {
    private let cacheDir: String
    private let logger = Logger(subsystem: "com.macparakeet", category: "ThumbnailCache")

    public init(cacheDir: String = AppPaths.thumbnailsDir) {
        self.cacheDir = cacheDir
    }

    /// Returns the local cache path for a transcription's thumbnail, or nil if not cached.
    public func cachedThumbnail(for transcriptionId: UUID) -> URL? {
        let path = thumbnailPath(for: transcriptionId)
        return FileManager.default.fileExists(atPath: path.path) ? path : nil
    }

    /// Downloads a thumbnail from a URL and caches it locally.
    public func downloadThumbnail(from urlString: String, for transcriptionId: UUID) async throws -> URL {
        if let cached = cachedThumbnail(for: transcriptionId) {
            return cached
        }

        guard let url = URL(string: urlString) else {
            throw ThumbnailError.invalidURL
        }

        try ensureCacheDir()

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw ThumbnailError.downloadFailed
        }

        let dest = thumbnailPath(for: transcriptionId)
        try data.write(to: dest)
        logger.debug("Cached thumbnail for \(transcriptionId)")
        return dest
    }

    /// Extracts a frame from a local video file using FFmpeg.
    public func extractVideoFrame(from videoPath: String, for transcriptionId: UUID) async throws -> URL {
        if let cached = cachedThumbnail(for: transcriptionId) {
            return cached
        }

        guard let ffmpegPath = resolveFFmpegPath() else {
            throw ThumbnailError.ffmpegNotFound
        }

        try ensureCacheDir()

        let dest = thumbnailPath(for: transcriptionId)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", videoPath,
            "-vframes", "1",
            "-q:v", "2",
            "-y",
            dest.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()

        // Await termination without blocking the cooperative thread pool
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            if !process.isRunning {
                continuation.resume()
                process.terminationHandler = nil
            }
        }

        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: dest.path) else {
            throw ThumbnailError.extractionFailed
        }

        return dest
    }

    /// Deletes the cached thumbnail for a transcription.
    public func deleteThumbnail(for transcriptionId: UUID) {
        let path = thumbnailPath(for: transcriptionId)
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - Private

    private func thumbnailPath(for transcriptionId: UUID) -> URL {
        URL(fileURLWithPath: cacheDir)
            .appendingPathComponent("\(transcriptionId.uuidString).jpg")
    }

    private func ensureCacheDir() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: cacheDir) {
            try fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
        }
    }

    private func resolveFFmpegPath() -> String? {
        // Check app-bundled FFmpeg first, then runtime bin
        if let bundled = AppPaths.bundledFFmpegPath() {
            return bundled
        }
        let runtimePath = "\(AppPaths.binDir)/ffmpeg"
        return FileManager.default.isExecutableFile(atPath: runtimePath) ? runtimePath : nil
    }
}

public enum ThumbnailError: Error, LocalizedError {
    case invalidURL
    case downloadFailed
    case ffmpegNotFound
    case extractionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid thumbnail URL"
        case .downloadFailed: return "Failed to download thumbnail"
        case .ffmpegNotFound: return "FFmpeg not found for frame extraction"
        case .extractionFailed: return "Failed to extract video frame"
        }
    }
}
