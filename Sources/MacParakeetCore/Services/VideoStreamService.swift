import Foundation
import os

public enum VideoPreparationStage: Sendable, Equatable {
    case extracting
    case downloading
    case combining
}

public protocol VideoStreamProviding: Sendable {
    func playbackResource(
        for youtubeURL: String,
        onStageChange: @escaping @Sendable (VideoPreparationStage) async -> Void
    ) async throws -> VideoPlaybackResource
}

/// Retain this alongside the player. Only fallback media created for this
/// resource is removed when its last owner releases it.
public final class VideoPlaybackResource: Sendable {
    public let url: URL
    private let temporaryDirectory: URL?

    public init(url: URL) {
        self.url = url
        temporaryDirectory = nil
    }

    init(url: URL, temporaryDirectory: URL) {
        self.url = url
        self.temporaryDirectory = temporaryDirectory
    }

    deinit {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }
}

public final class VideoStreamService: VideoStreamProviding, Sendable {
    typealias ProcessRunner = @Sendable (String, [String], TimeInterval, URL) async throws -> String

    private struct CachedURL: Sendable {
        let url: URL
        let expiresAt: Date
    }

    private static let sharedCache = OSAllocatedUnfairLock(initialState: [String: CachedURL]())
    private let cache: OSAllocatedUnfairLock<[String: CachedURL]>
    private let ytDlpPath: @Sendable () throws -> String
    private let ffmpegPath: @Sendable () throws -> String
    private let temporaryRoot: URL
    private let run: ProcessRunner

    private static let cacheTTL: TimeInterval = 2 * 60 * 60
    private static let maximumTrackBytes: UInt64 = 512 * 1024 * 1024
    private static let containerOverheadBytes: UInt64 = 16 * 1024 * 1024
    private static let videoFormat = "bv[ext=mp4][vcodec^=avc1][height<=1080][protocol=https][filesize<=?512M]"
    private static let audioFormat = "ba[ext=m4a][acodec^=mp4a][protocol=https][filesize<=?512M]"

    public init() {
        cache = Self.sharedCache
        ytDlpPath = { try Self.resolveYtDlpPath() }
        ffmpegPath = { try BinaryBootstrap.requireRuntimeFFmpegPath() }
        temporaryRoot = FileManager.default.temporaryDirectory
        run = { try await Self.runProcess($0, arguments: $1, timeout: $2, directory: $3) }
    }

    init(
        ytDlpPath: @escaping @Sendable () throws -> String,
        ffmpegPath: @escaping @Sendable () throws -> String,
        temporaryRoot: URL,
        runner: @escaping ProcessRunner
    ) {
        cache = OSAllocatedUnfairLock(initialState: [:])
        self.ytDlpPath = ytDlpPath
        self.ffmpegPath = ffmpegPath
        self.temporaryRoot = temporaryRoot
        run = runner
    }

    public func playbackResource(
        for youtubeURL: String,
        onStageChange: @escaping @Sendable (VideoPreparationStage) async -> Void = { _ in }
    ) async throws -> VideoPlaybackResource {
        try Task.checkCancellation()
        let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) ?? youtubeURL
        if let cached = cache.withLock({ $0[videoID] }), cached.expiresAt > Date() {
            return VideoPlaybackResource(url: cached.url)
        }

        let executable = try ytDlpPath()
        let directory = temporaryRoot.appendingPathComponent("macparakeet-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var ownsDirectory = true
        defer {
            if ownsDirectory {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        await onStageChange(.extracting)
        try Task.checkCancellation()
        let output = try await run(executable, [
            "--ignore-config", "--no-cache-dir", "--no-playlist",
            "-f", "b/\(Self.videoFormat)+\(Self.audioFormat)",
            "--get-url", "--", youtubeURL,
        ], 30, directory)
        try Task.checkCancellation()
        let urls = try Self.streamURLs(from: output)
        if urls.count == 1 {
            let url = urls[0]
            cache.withLock { $0[videoID] = CachedURL(url: url, expiresAt: Date().addingTimeInterval(Self.cacheTTL)) }
            return VideoPlaybackResource(url: url)
        }

        // Download separately so yt-dlp never owns an FFmpeg child process.
        // Our own process waiter can then cancel each subprocess completely.
        let ffmpeg = try ffmpegPath()
        await onStageChange(.downloading)
        try Task.checkCancellation()
        _ = try await run(executable, [
            "--ignore-config", "--no-cache-dir", "--no-playlist", "--quiet", "--no-progress",
            "--fixup", "never", "--no-part", "--max-filesize", "512M",
            "--socket-timeout", "15", "--retries", "1",
            "-f", "\(Self.videoFormat),\(Self.audioFormat)",
            "-o", directory.appendingPathComponent("source.%(ext)s").path,
            "--", youtubeURL,
        ], 600, directory)
        try Task.checkCancellation()

        let video = directory.appendingPathComponent("source.mp4")
        let audio = directory.appendingPathComponent("source.m4a")
        try Self.validateFile(video, maximumBytes: Self.maximumTrackBytes)
        try Self.validateFile(audio, maximumBytes: Self.maximumTrackBytes)

        await onStageChange(.combining)
        try Task.checkCancellation()
        let merged = directory.appendingPathComponent("playback.mp4")
        _ = try await run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", video.path, "-i", audio.path,
            "-map", "0:v:0", "-map", "1:a:0", "-c", "copy",
            "-movflags", "+faststart", "-y", merged.path,
        ], 120, directory)
        try Task.checkCancellation()
        try Self.validateFile(merged, maximumBytes: 2 * Self.maximumTrackBytes + Self.containerOverheadBytes)
        try FileManager.default.removeItem(at: video)
        try FileManager.default.removeItem(at: audio)

        let resource = VideoPlaybackResource(url: merged, temporaryDirectory: directory)
        ownsDirectory = false
        return resource
    }

    public func invalidateCache(for youtubeURL: String) {
        let videoID = YouTubeURLValidator.extractVideoID(youtubeURL) ?? youtubeURL
        _ = cache.withLock { $0.removeValue(forKey: videoID) }
    }

    private static func streamURLs(from output: String) throws -> [URL] {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard (1...2).contains(lines.count) else { throw VideoStreamError.invalidStreamURL }
        return try lines.map { line in
            guard !line.contains(where: \.isWhitespace),
                  let url = URL(string: line),
                  let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
                  let host = url.host, !host.isEmpty else {
                throw VideoStreamError.invalidStreamURL
            }
            return url
        }
    }

    private static func validateFile(_ url: URL, maximumBytes: UInt64) throws {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? NSNumber,
              size.uint64Value > 0, size.uint64Value <= maximumBytes else {
            throw VideoStreamError.preparationFailed(
                "Could not prepare both video and audio. Each downloaded track must be smaller than 512 MB."
            )
        }
    }

    /// Files avoid pipe-buffer deadlocks during downloads; reads stay bounded.
    static func runProcess(_ executable: String, arguments: [String], timeout: TimeInterval, directory: URL) async throws -> String {
        try Task.checkCancellation()
        let stdoutURL = directory.appendingPathComponent("process.stdout")
        let stderrURL = directory.appendingPathComponent("process.stderr")
        try Data().write(to: stdoutURL)
        try Data().write(to: stderrURL)
        defer {
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }
        let stdout = try FileHandle(forWritingTo: stdoutURL)
        defer { try? stdout.close() }
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderr.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr

        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = ([AppPaths.binDir, "/opt/homebrew/bin", "/usr/local/bin", path]).joined(separator: ":")
        process.environment = environment

        try process.run()
        try await ChildProcessWaiter.waitUntilExit(
            process,
            timeout: timeout,
            timeoutError: VideoStreamError.preparationFailed("Video preparation timed out. Please try again.")
        )
        guard process.terminationStatus == 0 else {
            let detail = try readOutput(stderrURL, limit: 16 * 1024)
            throw VideoStreamError.preparationFailed(
                detail.isEmpty ? "The media helper exited without producing playable video." : String(TelemetryErrorClassifier.sanitize(detail).prefix(512))
            )
        }
        return try readOutput(stdoutURL, limit: 64 * 1024)
    }

    private static func readOutput(_ url: URL, limit: Int) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw VideoStreamError.preparationFailed("The media helper returned too much output.")
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveYtDlpPath() throws -> String {
        let candidates = [BinaryBootstrap.resolveYtDlpPath(), "/opt/homebrew/bin/yt-dlp", "/usr/local/bin/yt-dlp"].compactMap { $0 }
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw VideoStreamError.ytDlpNotFound
        }
        return path
    }
}

public enum VideoStreamError: Error, LocalizedError {
    case ytDlpNotFound
    case preparationFailed(String)
    case invalidStreamURL

    public var errorDescription: String? {
        switch self {
        case .ytDlpNotFound:
            return "yt-dlp not found for video streaming"
        case .preparationFailed(let reason):
            return "Failed to prepare video: \(reason)"
        case .invalidStreamURL:
            return "The media helper did not return a supported video stream."
        }
    }
}
