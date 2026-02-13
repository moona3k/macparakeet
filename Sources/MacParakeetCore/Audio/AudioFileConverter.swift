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
        do {
            return try BinaryBootstrap.requireBundledFFmpegPath()
        } catch {
            throw AudioProcessorError.conversionFailed(
                "Bundled FFmpeg is missing. Reinstall MacParakeet."
            )
        }
    }
}
