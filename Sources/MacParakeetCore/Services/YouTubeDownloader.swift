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
        case .invalidURL: return "Not a valid media URL"
        case .videoNotFound: return "Video not found, private, or unavailable"
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
    private static let downloadTimeout: TimeInterval = 60 * 60
    private static let audioFileExtensions: Set<String> = [
        "aac",
        "aiff",
        "flac",
        "m4a",
        "mka",
        "mp3",
        "mp4",
        "oga",
        "ogg",
        "opus",
        "wav",
        "webm",
    ]

    public struct DownloadResult: Sendable {
        public let audioFileURL: URL
        public let title: String
        public let durationSeconds: Int?
        public let channelName: String?
        public let thumbnailURL: String?
        public let videoDescription: String?
        public let uploadDate: String?

        public init(
            audioFileURL: URL,
            title: String,
            durationSeconds: Int?,
            channelName: String? = nil,
            thumbnailURL: String? = nil,
            videoDescription: String? = nil,
            uploadDate: String? = nil
        ) {
            self.audioFileURL = audioFileURL
            self.title = title
            self.durationSeconds = durationSeconds
            self.channelName = channelName
            self.thumbnailURL = thumbnailURL
            self.videoDescription = videoDescription
            self.uploadDate = uploadDate
        }
    }

    private let binaryBootstrap: BinaryBootstrap
    private let audioQuality: @Sendable () -> YouTubeAudioQuality

    public init(
        binaryBootstrap: BinaryBootstrap = BinaryBootstrap(),
        audioQuality: @escaping @Sendable () -> YouTubeAudioQuality = { .m4a }
    ) {
        self.binaryBootstrap = binaryBootstrap
        self.audioQuality = audioQuality
    }

    /// Download audio from any HTTP(S) media URL that yt-dlp supports.
    public func download(url: String, onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> DownloadResult {
        let mediaURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSupportedMediaURL(mediaURL) else {
            throw YouTubeDownloadError.invalidURL
        }

        let ytDlpPath = try await resolveYtDlpPath()
        do {
            return try await download(url: mediaURL, ytDlpPath: ytDlpPath, onProgress: onProgress)
        } catch {
            let originalError = error
            if Self.isPyInstallerLibraryValidationError(error) {
                let repairedPath = try await binaryBootstrap.reinstallYtDlpFromBundledSeedOrDownload()
                return try await download(url: mediaURL, ytDlpPath: repairedPath, onProgress: onProgress)
            }

            guard Self.shouldRetryWithFreshYtDlp(error) else {
                throw error
            }

            let freshPath: String
            do {
                freshPath = try await binaryBootstrap.ensureYtDlpAvailable(allowNetworkUpdate: true)
            } catch {
                throw originalError
            }
            return try await download(url: mediaURL, ytDlpPath: freshPath, onProgress: onProgress)
        }
    }

    nonisolated static func isSupportedMediaURL(_ url: String) -> Bool {
        YouTubeURLValidator.isYouTubeURL(url)
            || DownloadableMediaURLValidator.isDownloadableMediaURL(url)
    }

    // MARK: - Private

    private func download(
        url: String,
        ytDlpPath: String,
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> DownloadResult {

        // Step 1: Fetch metadata
        let metadata = try await fetchMetadata(ytDlpPath: ytDlpPath, url: url)

        // Step 2: Download audio
        let audioURL = try await downloadAudio(
            ytDlpPath: ytDlpPath,
            url: url,
            metadata: metadata,
            onProgress: onProgress
        )

        return DownloadResult(
            audioFileURL: audioURL,
            title: metadata.title,
            durationSeconds: metadata.durationSeconds,
            channelName: metadata.channelName,
            thumbnailURL: metadata.thumbnailURL,
            videoDescription: metadata.videoDescription,
            uploadDate: metadata.uploadDate
        )
    }

    /// Build a PATH that includes common binary locations plus app-managed bin directory.
    private nonisolated static func extendedPATH() -> String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        let extras = [
            AppPaths.binDir,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let existing = Set(current.split(separator: ":").map(String.init))
        let missing = extras.filter { !existing.contains($0) }
        return (missing + [current]).joined(separator: ":")
    }

    private struct VideoMetadata {
        let title: String
        let durationSeconds: Int?
        let channelName: String?
        let thumbnailURL: String?
        let videoDescription: String?
        let uploadDate: String?
    }

    private struct JavaScriptRuntime {
        let name: String
        let executablePath: String
    }

    private func resolveYtDlpPath() async throws -> String {
        let ytDlpPath = try await binaryBootstrap.ensureYtDlpAvailable()
        guard FileManager.default.isExecutableFile(atPath: ytDlpPath) else {
            throw YouTubeDownloadError.ytDlpNotFound
        }
        return ytDlpPath
    }

    private func ffmpegDirectory() throws -> String {
        let ffmpegPath = try BinaryBootstrap.requireRuntimeFFmpegPath()
        return (ffmpegPath as NSString).deletingLastPathComponent
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
            throw YouTubeDownloadError.downloadFailed(Self.normalizeYtDlpError(errorOutput))
        }

        let data = Data(result.stdout.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeDownloadError.downloadFailed("Failed to parse video metadata")
        }

        let title = json["title"] as? String ?? "Untitled"
        let duration = json["duration"] as? Int
        let channel = json["channel"] as? String ?? json["uploader"] as? String
        let thumbnail = json["thumbnail"] as? String
        let description = json["description"] as? String
        let uploadDate = json["upload_date"] as? String ?? json["release_date"] as? String

        return VideoMetadata(
            title: title,
            durationSeconds: duration,
            channelName: channel,
            thumbnailURL: thumbnail,
            videoDescription: description,
            uploadDate: uploadDate
        )
    }

    private func downloadAudio(
        ytDlpPath: String,
        url: String,
        metadata: VideoMetadata,
        onProgress: (@Sendable (Int) -> Void)?
    ) async throws -> URL {
        let tempDir = AppPaths.youtubeDownloadsDir
        let fm = FileManager.default
        if !fm.fileExists(atPath: tempDir) {
            try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        }

        let ffmpegDir = try ffmpegDirectory()

        let uuid = UUID().uuidString
        let outputTemplate = "\(tempDir)/\(uuid).%(ext)s"
        var succeeded = false
        defer {
            if !succeeded {
                Self.removeDownloadArtifacts(in: URL(fileURLWithPath: tempDir, isDirectory: true), uuid: uuid)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytDlpPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.extendedPATH()
        process.environment = env

        let args = Self.downloadAudioArguments(
            ffmpegDir: ffmpegDir,
            outputTemplate: outputTemplate,
            url: url,
            quality: audioQuality(),
            javaScriptRuntimeArguments: javaScriptRuntimeArguments()
        )
        process.arguments = args

        // yt-dlp sends [download] progress lines to stdout (not stderr).
        // Pipe both streams so we can parse progress from stdout and capture
        // errors from stderr.
        let stdoutPipe = Pipe()
        let stdoutHandle = stdoutPipe.fileHandleForReading
        process.standardOutput = stdoutPipe

        let stderrPipe = Pipe()
        let stderrHandle = stderrPipe.fileHandleForReading
        process.standardError = stderrPipe

        let stderrAll = OSAllocatedUnfairLock(initialState: Data())
        let stdoutBuffer = OSAllocatedUnfairLock(initialState: Data())
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

        @Sendable func parseProgressLines(from buffer: OSAllocatedUnfairLock<Data>, chunk: Data) {
            let lines = buffer.withLock { buf in
                Self.extractLines(from: &buf, appending: chunk)
            }
            for line in lines {
                if let pct = Self.parseDownloadProgressPercent(from: line) {
                    emitProgress(pct)
                }
            }
        }

        stdoutHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            parseProgressLines(from: stdoutBuffer, chunk: chunk)
        }

        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrAll.withLock { $0.append(chunk) }
            parseProgressLines(from: stderrBuffer, chunk: chunk)
        }

        defer {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
        }

        try process.run()
        try await ChildProcessWaiter.waitUntilExit(
            process,
            timeout: Self.downloadTimeout,
            timeoutError: YouTubeDownloadError.timedOut
        )

        // Drain remaining data from both pipes
        let stdoutTail = stdoutHandle.readDataToEndOfFile()
        let stderrTail = stderrHandle.readDataToEndOfFile()
        stderrAll.withLock { $0.append(stderrTail) }

        for (buffer, tail) in [(stdoutBuffer, stdoutTail), (stderrBuffer, stderrTail)] {
            let lines = buffer.withLock { buf in
                Self.extractLines(from: &buf, appending: tail, consumeTrailingLine: true)
            }
            for line in lines {
                if let pct = Self.parseDownloadProgressPercent(from: line) {
                    emitProgress(pct)
                }
            }
        }

        let result = YtDlpResult(
            terminationStatus: process.terminationStatus,
            stdout: "",
            stderr: String(data: stderrAll.withLock { $0 }, encoding: .utf8) ?? ""
        )

        guard result.terminationStatus == 0 else {
            let errorOutput = result.stderr.isEmpty ? "Unknown error" : result.stderr
            throw YouTubeDownloadError.downloadFailed(Self.normalizeYtDlpError(errorOutput))
        }

        let files = try fm.contentsOfDirectory(atPath: tempDir)
        guard let downloadedFile = Self.selectDownloadedAudioFile(from: files, uuid: uuid) else {
            throw YouTubeDownloadError.downloadFailed("Downloaded file not found")
        }

        let downloadedURL = URL(fileURLWithPath: tempDir, isDirectory: true)
            .appendingPathComponent(downloadedFile)
        let audioURL = try Self.moveDownloadedAudioToReadableURL(
            downloadedURL,
            title: metadata.title,
            channelName: metadata.channelName,
            uploadDate: metadata.uploadDate
        )
        Self.removeDownloadArtifacts(in: URL(fileURLWithPath: tempDir, isDirectory: true), uuid: uuid)
        succeeded = true
        return audioURL
    }

    nonisolated static func removeDownloadArtifacts(in directory: URL, uuid: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files where file.lastPathComponent.hasPrefix(uuid) {
            try? fm.removeItem(at: file)
        }
    }

    nonisolated static func downloadAudioArguments(
        ffmpegDir: String,
        outputTemplate: String,
        url: String,
        quality: YouTubeAudioQuality,
        javaScriptRuntimeArguments: [String] = []
    ) -> [String] {
        var args = commonYtDlpArguments(
            ffmpegDir: ffmpegDir,
            javaScriptRuntimeArguments: javaScriptRuntimeArguments
        )
        args += [
            "-f", quality.ytDlpFormatSelector,
            "--no-playlist",
            "--retries", "3",
            "--concurrent-fragments", "4",
            "--embed-metadata",
            "--newline",
            "-o", outputTemplate,
            "--", url,
        ]
        return args
    }

    nonisolated static func commonYtDlpArguments(
        ffmpegDir: String,
        javaScriptRuntimeArguments: [String] = []
    ) -> [String] {
        var args: [String] = []
        if !javaScriptRuntimeArguments.isEmpty {
            args += ["--no-js-runtimes"] + javaScriptRuntimeArguments
        }
        args += ["--ffmpeg-location", ffmpegDir]
        return args
    }

    nonisolated static func selectDownloadedAudioFile(from fileNames: [String], uuid: String) -> String? {
        let candidates = fileNames
            .filter { $0.hasPrefix(uuid) }
            .filter { !isYtDlpTemporaryArtifact($0) }

        if let audioCandidate = candidates.first(where: { isSupportedDownloadedAudioFile($0) }) {
            return audioCandidate
        }

        return nil
    }

    nonisolated static func readableAudioFileStem(
        title: String,
        channelName: String?,
        uploadDate: String?
    ) -> String {
        let normalizedTitle = normalizedFileNamePart(title)
        let parts = [
            formattedUploadDate(uploadDate),
            normalizedFileNamePart(channelName),
            normalizedTitle == "Untitled" ? nil : normalizedTitle,
        ].compactMap { $0 }

        return sanitizedReadableStem(parts.joined(separator: " - "))
    }

    nonisolated static func readableAudioFileURL(
        in directory: URL,
        title: String,
        channelName: String?,
        uploadDate: String?,
        fileExtension: String
    ) -> URL {
        let stem = readableAudioFileStem(
            title: title,
            channelName: channelName,
            uploadDate: uploadDate
        )
        let normalizedExtension = normalizedFileExtension(fileExtension)
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent("\(stem).\(normalizedExtension)")
        var counter = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(counter)).\(normalizedExtension)")
            counter += 1
        }
        return candidate
    }

    nonisolated static func moveDownloadedAudioToReadableURL(
        _ downloadedURL: URL,
        title: String,
        channelName: String?,
        uploadDate: String?
    ) throws -> URL {
        let targetURL = readableAudioFileURL(
            in: downloadedURL.deletingLastPathComponent(),
            title: title,
            channelName: channelName,
            uploadDate: uploadDate,
            fileExtension: downloadedURL.pathExtension
        )
        guard targetURL != downloadedURL else {
            return downloadedURL
        }
        try FileManager.default.moveItem(at: downloadedURL, to: targetURL)
        return targetURL
    }

    private nonisolated static func isSupportedDownloadedAudioFile(_ fileName: String) -> Bool {
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return audioFileExtensions.contains(ext) && AudioFileConverter.isSupported(extension: ext)
    }

    private nonisolated static func formattedUploadDate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count == 10,
           trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)] == "-",
           trimmed[trimmed.index(trimmed.startIndex, offsetBy: 7)] == "-"
        {
            return trimmed
        }
        guard trimmed.count == 8,
              trimmed.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
            return nil
        }
        let yearEnd = trimmed.index(trimmed.startIndex, offsetBy: 4)
        let monthEnd = trimmed.index(yearEnd, offsetBy: 2)
        return "\(trimmed[..<yearEnd])-\(trimmed[yearEnd..<monthEnd])-\(trimmed[monthEnd...])"
    }

    private nonisolated static func normalizedFileNamePart(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }

    private nonisolated static func sanitizedReadableStem(_ raw: String) -> String {
        var disallowed = CharacterSet(charactersIn: "/:\\\"")
        disallowed.formUnion(.controlCharacters)
        let cleaned = raw
            .components(separatedBy: disallowed)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        let capped = cappedUTF8String(cleaned, maxBytes: 180)
        return capped.isEmpty ? "YouTube Audio" : capped
    }

    private nonisolated static func normalizedFileExtension(_ fileExtension: String) -> String {
        let normalized = fileExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
            .lowercased()
        return normalized.isEmpty ? "m4a" : normalized
    }

    private nonisolated static func cappedUTF8String(_ value: String, maxBytes: Int) -> String {
        var result = ""
        result.reserveCapacity(min(value.count, maxBytes))
        for character in value {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maxBytes else { break }
            result = candidate
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isYtDlpTemporaryArtifact(_ fileName: String) -> Bool {
        let lowercased = fileName.lowercased()
        return lowercased.hasSuffix(".part")
            || lowercased.contains(".part-")
            || lowercased.hasSuffix(".ytdl")
            || lowercased.hasSuffix(".temp")
            || lowercased.hasSuffix(".tmp")
            || lowercased.hasSuffix(".frag")
            || lowercased.hasSuffix(".info.json")
            || lowercased.hasSuffix(".description")
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
                !line.isEmpty
            {
                lines.append(line)
            }
        }

        if consumeTrailingLine, !buffer.isEmpty {
            if let line = String(data: buffer, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !line.isEmpty
            {
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

    private func javaScriptRuntimeArguments() -> [String] {
        guard let runtime = findJavaScriptRuntime() else { return [] }
        return ["--js-runtimes", "\(runtime.name):\(runtime.executablePath)"]
    }

    private func findJavaScriptRuntime() -> JavaScriptRuntime? {
        let resourcePath = Bundle.main.resourcePath
        let candidates: [(name: String, binaryNames: [String], preferredPaths: [String])] = [
            (
                "node",
                ["node"],
                Self.bundledRuntimePaths(baseName: "node", resourcePath: resourcePath) + [
                    "/opt/homebrew/bin/node",
                    "/usr/local/bin/node",
                    "/usr/bin/node",
                ]
            ),
            (
                "deno",
                ["deno"],
                Self.bundledRuntimePaths(baseName: "deno", resourcePath: resourcePath) + [
                    "/opt/homebrew/bin/deno",
                    "/usr/local/bin/deno",
                    "/usr/bin/deno",
                ]
            ),
            (
                "quickjs",
                ["qjs", "quickjs"],
                Self.bundledRuntimePaths(baseName: "qjs", resourcePath: resourcePath)
                    + Self.bundledRuntimePaths(baseName: "quickjs", resourcePath: resourcePath)
                    + [
                        "/opt/homebrew/bin/qjs",
                        "/usr/local/bin/qjs",
                        "/usr/bin/qjs",
                    ]
            ),
        ]

        for candidate in candidates {
            if let path = candidate.preferredPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                return JavaScriptRuntime(name: candidate.name, executablePath: path)
            }
            for binaryName in candidate.binaryNames {
                if let discovered = Self.findExecutable(named: binaryName, inPATH: Self.extendedPATH()) {
                    return JavaScriptRuntime(name: candidate.name, executablePath: discovered)
                }
            }
        }

        return nil
    }

    private nonisolated static func bundledRuntimePaths(baseName: String, resourcePath: String?) -> [String] {
        guard let resourcePath else { return [] }
        #if arch(arm64)
        let archName = "arm64"
        #else
        let archName = "x86_64"
        #endif
        return [
            "\(resourcePath)/\(baseName)",
            "\(resourcePath)/\(baseName)-\(archName)",
        ]
    }

    private nonisolated static func findExecutable(named binaryName: String, inPATH path: String) -> String? {
        let fm = FileManager.default
        for rawComponent in path.split(separator: ":") {
            let component = String(rawComponent)
            guard !component.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: component, isDirectory: true)
                .appendingPathComponent(binaryName)
                .path
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    private nonisolated static func normalizeYtDlpError(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Unknown error" }

        let normalized = trimmed.lowercased()
        if normalized.contains("no supported javascript runtime could be found") {
            return "No supported JavaScript runtime found for media extraction. Install Node.js (recommended) or Deno and retry."
        }

        if normalized.contains("ffmpeg") && normalized.contains("not found") {
            return "FFmpeg is missing or inaccessible for this runtime."
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        func sanitized(_ value: String) -> String {
            String(TelemetryErrorClassifier.sanitize(value).prefix(512))
        }

        if let errorLine = lines.first(where: { $0.localizedCaseInsensitiveContains("error:") }) {
            return sanitized(errorLine)
        }

        if let nonWarningLine = lines.first(where: { !$0.localizedCaseInsensitiveContains("warning:") }) {
            return sanitized(nonWarningLine)
        }

        return sanitized(lines.first ?? trimmed)
    }

    nonisolated static func isPyInstallerLibraryValidationError(_ error: Error) -> Bool {
        guard case YouTubeDownloadError.downloadFailed(let reason) = error else {
            return false
        }
        let normalized = reason.lowercased()
        return normalized.contains("failed to load python shared library")
            || (normalized.contains("pyi-") && normalized.contains("different team ids"))
    }

    private nonisolated static func shouldRetryWithFreshYtDlp(_ error: Error) -> Bool {
        switch error {
        case YouTubeDownloadError.downloadFailed, YouTubeDownloadError.timedOut:
            return true
        default:
            return false
        }
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
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.extendedPATH()
        process.environment = env

        process.arguments = Self.commonYtDlpArguments(
            ffmpegDir: try ffmpegDirectory(),
            javaScriptRuntimeArguments: javaScriptRuntimeArguments()
        ) + arguments
        process.standardOutput = captureStdout ? stdoutHandle : FileHandle.nullDevice
        process.standardError = stderrHandle

        try process.run()
        try await ChildProcessWaiter.waitUntilExit(
            process,
            timeout: 30,
            timeoutError: YouTubeDownloadError.timedOut
        )

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
