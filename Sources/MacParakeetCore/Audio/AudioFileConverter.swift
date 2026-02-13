import Foundation

/// Converts audio/video files to 16kHz mono WAV using FFmpeg subprocess.
public final class AudioFileConverter: Sendable {
    /// Supported audio extensions
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "wav", "m4a", "flac", "ogg", "opus"
    ]

    /// Supported video extensions (audio will be extracted)
    public static let supportedVideoExtensions: Set<String> = [
        "mp4", "mov", "mkv", "webm", "avi"
    ]

    /// All supported extensions
    public static var supportedExtensions: Set<String> {
        supportedAudioExtensions.union(supportedVideoExtensions)
    }

    /// Check if a file extension is supported
    public static func isSupported(extension ext: String) -> Bool {
        supportedExtensions.contains(ext.lowercased())
    }

    /// Convert any supported audio/video file to 16kHz mono WAV.
    /// Returns the path to the converted WAV file in the temp directory.
    public func convert(fileURL: URL) async throws -> URL {
        let ext = fileURL.pathExtension.lowercased()
        guard Self.isSupported(extension: ext) else {
            throw AudioProcessorError.unsupportedFormat(ext)
        }

        // If already a 16kHz mono WAV, still convert to ensure correct format
        let tempDir = try ensureTempDir()
        let outputURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")

        let ffmpegPath = try findFFmpeg()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-i", fileURL.path,
            "-ar", "16000",      // 16kHz sample rate
            "-ac", "1",          // mono
            "-f", "wav",         // WAV format
            "-acodec", "pcm_f32le",  // Float32 PCM
            "-y",                // overwrite output
            outputURL.path
        ]

        // Use temp file for stderr to avoid pipe buffer deadlock on long files.
        // ffmpeg writes verbose progress to stderr; if it exceeds the 64KB pipe
        // buffer, both ffmpeg and waitUntilExit() block permanently.
        let stderrURL = tempDir.appendingPathComponent("ffmpeg-stderr-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            stderrHandle.closeFile()
            try? FileManager.default.removeItem(at: stderrURL)
        }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            stderrHandle.synchronizeFile()
            let stderrStr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "Unknown error"
            throw AudioProcessorError.conversionFailed(stderrStr)
        }

        return outputURL
    }

    /// Build the FFmpeg command arguments (useful for testing)
    public func ffmpegArguments(inputPath: String, outputPath: String) -> [String] {
        [
            "-i", inputPath,
            "-ar", "16000",
            "-ac", "1",
            "-f", "wav",
            "-acodec", "pcm_f32le",
            "-y",
            outputPath
        ]
    }

    // MARK: - Private

    private func ensureTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet", isDirectory: true)
        if !FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        }
        return tempDir
    }

    private func findFFmpeg() throws -> String {
        let fm = FileManager.default

        // Check bundled FFmpeg first
        if let bundledPath = Bundle.main.resourcePath.map({ $0 + "/ffmpeg" }),
           fm.fileExists(atPath: bundledPath) {
            return bundledPath
        }

        // Check imageio-ffmpeg in the Python venv (installed as a pip dependency).
        // The binary name includes platform info, so glob for it.
        let venvSitePackages = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("MacParakeet/python/lib")
            .path
        if let sitePackages = venvSitePackages {
            let binDir = "\(sitePackages)/python3.11/site-packages/imageio_ffmpeg/binaries"
            if let contents = try? fm.contentsOfDirectory(atPath: binDir) {
                if let ffmpegBin = contents.first(where: { $0.hasPrefix("ffmpeg") }) {
                    return "\(binDir)/\(ffmpegBin)"
                }
            }
        }

        // Common install paths
        let searchPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]

        for path in searchPaths {
            if fm.fileExists(atPath: path) {
                return path
            }
        }

        // Try which
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        whichProcess.arguments = ["ffmpeg"]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice

        try whichProcess.run()
        whichProcess.waitUntilExit()

        if whichProcess.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty {
                return path
            }
        }

        throw AudioProcessorError.conversionFailed(
            "FFmpeg is required but was not found. Please reinstall MacParakeet or install FFmpeg manually."
        )
    }
}
