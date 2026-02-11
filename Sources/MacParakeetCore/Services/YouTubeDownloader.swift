import Foundation
import os

public enum YouTubeDownloadError: Error, LocalizedError {
    case invalidURL
    case videoNotFound
    case downloadFailed(String)
    case ytDlpNotFound
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Not a valid YouTube URL"
        case .videoNotFound: return "Video not found or is private"
        case .downloadFailed(let reason): return "Download failed: \(reason)"
        case .ytDlpNotFound: return "yt-dlp not found. Run the app once to install dependencies."
        case .timedOut: return "Download timed out — the connection may have stalled"
        }
    }
}

public protocol YouTubeDownloading: Sendable {
    func download(url: String, onProgress: (@Sendable (Int) -> Void)?) async throws -> YouTubeDownloader.DownloadResult
}

extension YouTubeDownloading {
    public func download(url: String) async throws -> YouTubeDownloader.DownloadResult {
        try await download(url: url, onProgress: nil)
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
    public func download(url: String, onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> DownloadResult {
        guard YouTubeURLValidator.isYouTubeURL(url) else {
            throw YouTubeDownloadError.invalidURL
        }

        let ytDlpPath = try await resolveYtDlpPath()

        // Step 1: Fetch metadata
        let metadata = try await fetchMetadata(ytDlpPath: ytDlpPath, url: url)

        // Step 2: Download audio
        let audioURL = try await downloadAudio(ytDlpPath: ytDlpPath, url: url, onProgress: onProgress)

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
        let result = try await runYtDlp(
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

    private func downloadAudio(
        ytDlpPath: String,
        url: String,
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> URL {
        let tempDir = AppPaths.youtubeDownloadsDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: tempDir) {
            try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        }

        let uuid = UUID().uuidString
        let outputTemplate = "\(tempDir)/\(uuid).%(ext)s"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        process.arguments = [
            "-f", "bestaudio/best",
            "--no-playlist",
            "--retries", "3",
            "--concurrent-fragments", "4",
            "--newline",
            "-o", outputTemplate,
            url,
        ]
        process.standardOutput = FileHandle.nullDevice

        let stderrPipe = Pipe()
        let stderrHandle = stderrPipe.fileHandleForReading
        process.standardError = stderrPipe

        let stderrAll = OSAllocatedUnfairLock(initialState: Data())
        let stderrBuffer = OSAllocatedUnfairLock(initialState: Data())
        let lastProgress = OSAllocatedUnfairLock(initialState: -1)

        @Sendable func emitProgress(_ percent: Int) {
            let clamped = max(0, min(percent, 100))
            let shouldEmit = lastProgress.withLock { last -> Bool in
                guard clamped != last else { return false }
                last = clamped
                return true
            }
            if shouldEmit {
                onProgress?(clamped)
            }
        }

        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrAll.withLock { $0.append(chunk) }
            let lines = stderrBuffer.withLock { buffer in
                Self.extractLines(from: &buffer, appending: chunk)
            }
            for line in lines {
                if let pct = Self.parseDownloadProgressPercent(from: line) {
                    emitProgress(pct)
                }
            }
        }

        do {
            try process.run()
            try await waitForProcess(process, timeout: 600)
        } catch {
            stderrHandle.readabilityHandler = nil
            throw error
        }

        stderrHandle.readabilityHandler = nil
        let tailData = stderrHandle.readDataToEndOfFile()
        stderrAll.withLock { $0.append(tailData) }
        let tailLines = stderrBuffer.withLock { buffer in
            Self.extractLines(from: &buffer, appending: tailData, consumeTrailingLine: true)
        }
        for line in tailLines {
            if let pct = Self.parseDownloadProgressPercent(from: line) {
                emitProgress(pct)
            }
        }

        let result = YtDlpResult(
            terminationStatus: process.terminationStatus,
            stdout: "",
            stderr: String(data: stderrAll.withLock { $0 }, encoding: .utf8) ?? ""
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

    nonisolated static func parseDownloadProgressPercent(from line: String) -> Int? {
        guard line.localizedCaseInsensitiveContains("[download]"),
              let match = line.range(of: #"([0-9]+(?:\.[0-9]+)?)%"#, options: .regularExpression)
        else {
            return nil
        }
        let pctString = line[match].dropLast()
        guard let raw = Double(pctString) else { return nil }
        return max(0, min(Int(raw.rounded()), 100))
    }

    private nonisolated static func extractLines(
        from buffer: inout Data,
        appending chunk: Data,
        consumeTrailingLine: Bool = false
    ) -> [String] {
        buffer.append(chunk)
        var lines: [String] = []

        while let newlineIdx = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.prefix(upTo: newlineIdx)
            buffer.removeSubrange(..<buffer.index(after: newlineIdx))
            if let line = String(data: Data(lineData), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
            }
        }

        if consumeTrailingLine, !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                lines.append(line)
            }
            buffer.removeAll(keepingCapacity: true)
        }

        return lines
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
    ) async throws -> YtDlpResult {
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
        try await waitForProcess(process, timeout: 30)

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

    private func waitForProcess(_ process: Process, timeout: TimeInterval) async throws {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    continuation.resume()
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    process.terminate()
                    continuation.resume(throwing: YouTubeDownloadError.timedOut)
                }
            }

            // Handle race: process may have exited before terminationHandler was set
            if !process.isRunning {
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if shouldResume {
                    continuation.resume()
                }
            }
        }
    }
}

extension YouTubeDownloader: YouTubeDownloading {}
