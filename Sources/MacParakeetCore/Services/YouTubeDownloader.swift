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

        // Try to install by ensuring the environment (installs requirements.txt)
        _ = try await pythonBootstrap.ensureEnvironment()

        if FileManager.default.fileExists(atPath: venvBin) {
            return venvBin
        }

        throw YouTubeDownloadError.ytDlpNotFound
    }

    private func fetchMetadata(ytDlpPath: String, url: String) async throws -> VideoMetadata {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = [
            "--skip-download",
            "--dump-json",
            "--no-playlist",
            url,
        ]
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Unknown error"

            if errorOutput.contains("Video unavailable") || errorOutput.contains("Private video") {
                throw YouTubeDownloadError.videoNotFound
            }
            throw YouTubeDownloadError.downloadFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
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

        let process = Process()
        let stderr = Pipe()

        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = [
            "-f", "bestaudio/best",
            "--no-playlist",
            "--retries", "3",
            "--concurrent-fragments", "4",
            "-o", outputTemplate,
            url,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errorOutput = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? "Unknown error"
            throw YouTubeDownloadError.downloadFailed(errorOutput.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // Find the downloaded file (yt-dlp chooses the extension)
        let files = try fm.contentsOfDirectory(atPath: tempDir)
        guard let downloadedFile = files.first(where: { $0.hasPrefix(uuid) }) else {
            throw YouTubeDownloadError.downloadFailed("Downloaded file not found")
        }

        return URL(fileURLWithPath: "\(tempDir)/\(downloadedFile)")
    }
}
