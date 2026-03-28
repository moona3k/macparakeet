import Foundation
import os

public final class VideoStreamService: Sendable {
    private let logger = Logger(subsystem: "com.macparakeet", category: "VideoStream")
    private let cache = OSAllocatedUnfairLock(initialState: [String: CachedURL]())

    private struct CachedURL: Sendable {
        let url: URL
        let expiresAt: Date
    }

    /// TTL for cached stream URLs (YouTube URLs typically expire after ~2-6 hours)
    private static let cacheTTL: TimeInterval = 2 * 60 * 60

    public init() {}

    /// Extract a streaming URL for a YouTube video. Caches per video ID.
    public func streamURL(for youtubeURL: String) async throws -> URL {
        let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) ?? youtubeURL

        // Check cache
        if let cached = cache.withLock({ $0[videoID] }),
           cached.expiresAt > Date() {
            return cached.url
        }

        let url = try await extractStreamURL(youtubeURL: youtubeURL)

        cache.withLock {
            $0[videoID] = CachedURL(url: url, expiresAt: Date().addingTimeInterval(Self.cacheTTL))
        }

        return url
    }

    /// Invalidate cached URL for a video (e.g., after playback error).
    public func invalidateCache(for youtubeURL: String) {
        let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) ?? youtubeURL
        cache.withLock { $0.removeValue(forKey: videoID) }
    }

    // MARK: - Private

    private func extractStreamURL(youtubeURL: String) async throws -> URL {
        let ytDlpPath = try resolveYtDlpPath()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = [
            "-f", "best",
            "--get-url",
            "--no-playlist",
            "--extractor-args", "youtube:player_client=tv,android",
            youtubeURL,
        ]

        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? "/usr/bin:/bin"
        let extras = [AppPaths.binDir, "/opt/homebrew/bin", "/usr/local/bin"]
        let existing = Set(current.split(separator: ":").map(String.init))
        let missing = extras.filter { !existing.contains($0) }
        env["PATH"] = (missing + [current]).joined(separator: ":")
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read pipes BEFORE waiting (prevents deadlock if output exceeds pipe buffer)
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        // Await termination without blocking the cooperative thread pool
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            if !process.isRunning {
                continuation.resume()
                process.terminationHandler = nil
            }
        }

        let stdout = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard process.terminationStatus == 0, !stdout.isEmpty else {
            let stderr = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown error"
            logger.error("yt-dlp stream extraction failed: \(stderr)")
            throw VideoStreamError.extractionFailed(stderr)
        }

        // yt-dlp may return multiple URLs (video + audio); take the first
        let urlString = stdout.components(separatedBy: .newlines).first ?? stdout
        guard let url = URL(string: urlString) else {
            throw VideoStreamError.invalidStreamURL
        }

        logger.debug("Extracted stream URL for \(youtubeURL)")
        return url
    }

    private func resolveYtDlpPath() throws -> String {
        let candidates = [
            AppPaths.ytDlpBinaryPath,
            "/opt/homebrew/bin/yt-dlp",
            "/usr/local/bin/yt-dlp",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        throw VideoStreamError.ytDlpNotFound
    }
}

public enum VideoStreamError: Error, LocalizedError {
    case ytDlpNotFound
    case extractionFailed(String)
    case invalidStreamURL

    public var errorDescription: String? {
        switch self {
        case .ytDlpNotFound:
            return "yt-dlp not found for video streaming"
        case .extractionFailed(let reason):
            return "Failed to extract stream URL: \(reason)"
        case .invalidStreamURL:
            return "Extracted URL is not valid"
        }
    }
}
