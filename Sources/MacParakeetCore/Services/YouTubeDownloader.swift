import Foundation

public enum YouTubeDownloadError: Error, LocalizedError {
    case invalidURL
    case videoNotFound
    case downloadFailed(String)
    case ytDlpNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Not a valid YouTube URL"
        case .videoNotFound: return "Video not found or is private"
        case .downloadFailed(let reason): return "Download failed: \(reason)"
        case .ytDlpNotFound: return "yt-dlp not found. Run the app once to install dependencies."
        }
    }
}

public protocol YouTubeDownloading: Sendable {
    func download(url: String) async throws -> YouTubeDownloader.DownloadResult
}

public actor YouTubeDownloader {
    public struct DownloadResult: Sendable {
        public let audioFileURL: URL
        public let title: String
        public let durationSeconds: Int?

        public init(audioFileURL: URL, title: String, durationSeconds: Int?) {
            self.audioFileURL = audioFileURL
            self.title = title
            self.durationSeconds = durationSeconds
        }
    }

    private let pythonBootstrap: PythonBootstrap

    public init(pythonBootstrap: PythonBootstrap) {
        self.pythonBootstrap = pythonBootstrap
    }

    /// Download audio from a YouTube URL.
    public func download(url: String) async throws -> DownloadResult {
        guard YouTubeURLValidator.isYouTubeURL(url) else {
            throw YouTubeDownloadError.invalidURL
        }

        let ytDlpPath = try await resolveYtDlpPath()

        // Step 1: Fetch metadata
        let metadata = try await fetchMetadata(ytDlpPath: ytDlpPath, url: url)

        // Step 2: Download audio
        let audioURL = try await downloadAudio(ytDlpPath: ytDlpPath, url: url)

        return DownloadResult(
            audioFileURL: audioURL,
            title: metadata.title,
            durationSeconds: metadata.durationSeconds
        )
    }

    // MARK: - Private

    private struct VideoMetadata {
        let title: String
        let durationSeconds: Int?
    }

    private func resolveYtDlpPath() async throws -> String {
        let venvBin = "\(pythonBootstrap.venvPath)/bin/yt-dlp"
        if FileManager.default.fileExists(atPath: venvBin) {
            return venvBin
        }

        // Venv may exist but yt-dlp wasn't installed yet (added after initial bootstrap).
        // Re-run requirements install to pick up new dependencies.
        try await pythonBootstrap.installRequirements()

        if FileManager.default.fileExists(atPath: venvBin) {
            return venvBin
        }

        throw YouTubeDownloadError.ytDlpNotFound
    }

    private func fetchMetadata(ytDlpPath: String, url: String) async throws -> VideoMetadata {
        let result = try runYtDlp(
            ytDlpPath: ytDlpPath,
            arguments: [
            "--skip-download",
            "--dump-json",
            "--no-playlist",
            url,
        ],
            captureStdout: true
        )

        guard result.terminationStatus == 0 else {
            let errorOutput = result.stderr.isEmpty ? "Unknown error" : result.stderr
            let normalized = errorOutput.lowercased()
            if normalized.contains("video unavailable") || normalized.contains("private video") {
                throw YouTubeDownloadError.videoNotFound
            }
            throw YouTubeDownloadError.downloadFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = Data(result.stdout.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeDownloadError.downloadFailed("Failed to parse video metadata")
        }

        let title = json["title"] as? String ?? "Untitled"
        let duration = json["duration"] as? Int

        return VideoMetadata(title: title, durationSeconds: duration)
    }

    private func downloadAudio(ytDlpPath: String, url: String) async throws -> URL {
        let tempDir = AppPaths.tempDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: tempDir) {
            try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        }

        let uuid = UUID().uuidString
        let outputTemplate = "\(tempDir)/\(uuid).%(ext)s"

        let result = try runYtDlp(
            ytDlpPath: ytDlpPath,
            arguments: [
            "-f", "bestaudio/best",
            "--no-playlist",
            "--retries", "3",
            "--concurrent-fragments", "4",
            "-o", outputTemplate,
            url,
        ]
        )

        guard result.terminationStatus == 0 else {
            let errorOutput = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw YouTubeDownloadError.downloadFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Find the downloaded file (yt-dlp chooses the extension)
        let files = try fm.contentsOfDirectory(atPath: tempDir)
        guard let downloadedFile = files.first(where: { $0.hasPrefix(uuid) }) else {
            throw YouTubeDownloadError.downloadFailed("Downloaded file not found")
        }

        return URL(fileURLWithPath: "\(tempDir)/\(downloadedFile)")
    }

    private struct YtDlpResult {
        let terminationStatus: Int32
        let stdout: String
        let stderr: String
    }

    private func runYtDlp(
        ytDlpPath: String,
        arguments: [String],
        captureStdout: Bool = false
    ) throws -> YtDlpResult {
        let fm = FileManager.default
        let tempDir = AppPaths.tempDir
        if !fm.fileExists(atPath: tempDir) {
            try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        }

        let stderrURL = URL(fileURLWithPath: tempDir)
            .appendingPathComponent("yt-dlp-stderr-\(UUID().uuidString).log")
        let stdoutURL = URL(fileURLWithPath: tempDir)
            .appendingPathComponent("yt-dlp-stdout-\(UUID().uuidString).log")

        _ = fm.createFile(atPath: stderrURL.path, contents: Data())
        if captureStdout {
            _ = fm.createFile(atPath: stdoutURL.path, contents: Data())
        }

        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        let stdoutHandle = captureStdout ? try FileHandle(forWritingTo: stdoutURL) : nil

        defer {
            stderrHandle.closeFile()
            stdoutHandle?.closeFile()
            try? fm.removeItem(at: stderrURL)
            if captureStdout {
                try? fm.removeItem(at: stdoutURL)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = arguments
        process.standardOutput = captureStdout ? stdoutHandle : FileHandle.nullDevice
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()

        stderrHandle.synchronizeFile()
        stdoutHandle?.synchronizeFile()

        let stderr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""
        let stdout = captureStdout ? ((try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? "") : ""

        return YtDlpResult(
            terminationStatus: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }
}

extension YouTubeDownloader: YouTubeDownloading {}
