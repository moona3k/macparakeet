import Foundation
import os

public final class VideoStreamService: Sendable {
    private let logger = Logger(subsystem: "com.macparakeet", category: "VideoStream")

    /// Shared cache across all instances — survives view recreation
    private static let cache = OSAllocatedUnfairLock(initialState: [String: CachedURL]())

    private struct CachedURL: Sendable {
        let url: URL
        let expiresAt: Date
    }

    /// TTL for cached stream URLs (YouTube URLs typically expire after ~2-6 hours)
    private static let cacheTTL: TimeInterval = 2 * 60 * 60

    /// Timeout for the entire yt-dlp extraction (pipe reads + termination)
    private static let extractionTimeout: TimeInterval = 30

    public init() {}

    /// Extract a streaming URL for a YouTube video. Caches per video ID.
    public func streamURL(for youtubeURL: String) async throws -> URL {
        let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) ?? youtubeURL

        // Check cache
        if let cached = Self.cache.withLock({ $0[videoID] }),
           cached.expiresAt > Date() {
            logger.notice("🎯 Cache HIT for \(videoID) (expires in \(Int(cached.expiresAt.timeIntervalSinceNow))s)")
            return cached.url
        }
        logger.notice("❌ Cache MISS for \(videoID), extracting via yt-dlp")

        let url = try await extractStreamURL(youtubeURL: youtubeURL)

        Self.cache.withLock {
            $0[videoID] = CachedURL(url: url, expiresAt: Date().addingTimeInterval(Self.cacheTTL))
        }
        logger.notice("✅ Cached stream URL for \(videoID) (TTL: \(Int(Self.cacheTTL))s)")

        return url
    }

    /// Invalidate cached URL for a video (e.g., after playback error).
    public func invalidateCache(for youtubeURL: String) {
        let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) ?? youtubeURL
        Self.cache.withLock { $0.removeValue(forKey: videoID) }
        logger.notice("🗑 Invalidated cache for \(videoID)")
    }

    // MARK: - Private

    private func extractStreamURL(youtubeURL: String) async throws -> URL {
        let ytDlpPath = try resolveYtDlpPath()
        logger.notice("▶️ Starting yt-dlp extraction for \(youtubeURL)")
        logger.notice("  yt-dlp path: \(ytDlpPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = [
            "-f", "b",
            "--get-url",
            "--no-playlist",
            "--", youtubeURL,
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

        let startTime = ContinuousClock.now

        try process.run()
        logger.notice("  yt-dlp process launched (PID: \(process.processIdentifier))")

        // Wrap EVERYTHING in a single timeout — pipe reads + termination.
        // If yt-dlp hangs and never closes stdout, the pipe read blocks forever
        // without this outer timeout.
        let result: (stdout: Data, stderr: Data) = try await withThrowingTaskGroup(of: (stdout: Data, stderr: Data).self) { group in
            group.addTask {
                // Read pipes on background threads (don't block cooperative pool)
                let stdoutData: Data = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                }
                let stderrData: Data = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async {
                        continuation.resume(returning: stderrPipe.fileHandleForReading.readDataToEndOfFile())
                    }
                }

                // Wait for process termination
                let resumed = OSAllocatedUnfairLock(initialState: false)
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    process.terminationHandler = { _ in
                        let alreadyResumed = resumed.withLock { flag -> Bool in
                            let was = flag; flag = true; return was
                        }
                        if !alreadyResumed { continuation.resume() }
                    }
                    if !process.isRunning {
                        let alreadyResumed = resumed.withLock { flag -> Bool in
                            let was = flag; flag = true; return was
                        }
                        if !alreadyResumed {
                            continuation.resume()
                            process.terminationHandler = nil
                        }
                    }
                }

                return (stdout: stdoutData, stderr: stderrData)
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(for: .seconds(Self.extractionTimeout))
                throw VideoStreamError.extractionFailed(
                    "Stream extraction timed out after \(Int(Self.extractionTimeout))s"
                )
            }

            // First task to complete wins — either extraction finishes or timeout fires
            let value = try await group.next()!
            // Cancel the loser (timeout or extraction)
            group.cancelAll()
            // Kill yt-dlp if it's still running (timeout won the race)
            if process.isRunning {
                process.terminate()
            }
            return value
        }

        let elapsed = ContinuousClock.now - startTime
        logger.notice("  yt-dlp finished in \(elapsed) (exit: \(process.terminationStatus))")

        let stdout = String(data: result.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: result.stderr, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !stderr.isEmpty {
            logger.notice("  yt-dlp stderr: \(stderr)")
        }

        guard process.terminationStatus == 0, !stdout.isEmpty else {
            logger.error("❌ yt-dlp extraction failed: \(stderr)")
            throw VideoStreamError.extractionFailed(stderr.isEmpty ? "No output from yt-dlp" : stderr)
        }

        // yt-dlp may return multiple URLs (video + audio); take the first
        let urlString = stdout.components(separatedBy: .newlines).first ?? stdout
        guard let url = URL(string: urlString) else {
            logger.error("❌ Invalid stream URL: \(urlString.prefix(100))")
            throw VideoStreamError.invalidStreamURL
        }

        logger.notice("✅ Extracted stream URL for \(youtubeURL) in \(elapsed)")
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
