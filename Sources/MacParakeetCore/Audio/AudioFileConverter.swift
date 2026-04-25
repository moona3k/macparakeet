import Foundation
import os

public protocol AudioFileConverting: Sendable {
    func convert(fileURL: URL) async throws -> URL
    func mixToM4A(inputURLs: [URL], outputURL: URL) async throws
}

/// Converts audio/video files to 16kHz mono WAV using FFmpeg subprocess.
public final class AudioFileConverter: AudioFileConverting, Sendable {
    public init() {}

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

        let tempDir = try ensureTempDir()
        let primaryPath = try findFFmpeg()

        do {
            return try await runFFmpegConversion(
                ffmpegPath: primaryPath, inputURL: fileURL, tempDir: tempDir
            )
        } catch let error as AudioProcessorError {
            // If the bundled FFmpeg failed due to dyld (e.g., Team ID mismatch after
            // code signing), try the system FFmpeg from PATH as a fallback.
            guard case .conversionFailed(let reason) = error,
                  reason.contains("dyld") || reason.contains("Library not loaded"),
                  let fallbackPath = BinaryBootstrap.findSystemFFmpeg(),
                  fallbackPath != primaryPath
            else { throw error }

            return try await runFFmpegConversion(
                ffmpegPath: fallbackPath, inputURL: fileURL, tempDir: tempDir
            )
        }
    }

    /// Produce a final meeting M4A from one or more source tracks.
    /// For mic+system dual input, preserve channel separation as stereo:
    /// channel 1 = microphone, channel 2 = system.
    /// For single-input sessions, output a mono AAC file.
    public func mixToM4A(inputURLs: [URL], outputURL: URL) async throws {
        guard !inputURLs.isEmpty else {
            throw AudioProcessorError.conversionFailed("No audio files to mix")
        }

        let primaryPath = try findFFmpeg()

        do {
            try await runFFmpegMix(
                ffmpegPath: primaryPath,
                inputURLs: inputURLs,
                outputURL: outputURL
            )
        } catch let error as AudioProcessorError {
            guard case .conversionFailed(let reason) = error,
                  reason.contains("dyld") || reason.contains("Library not loaded"),
                  let fallbackPath = BinaryBootstrap.findSystemFFmpeg(),
                  fallbackPath != primaryPath
            else { throw error }

            try await runFFmpegMix(
                ffmpegPath: fallbackPath,
                inputURLs: inputURLs,
                outputURL: outputURL
            )
        }
    }

    /// Build the FFmpeg command arguments (useful for testing)
    public func ffmpegArguments(inputPath: String, outputPath: String) -> [String] {
        [
            "-nostdin",
            "-i", inputPath,
            "-ar", "16000",
            "-ac", "1",
            "-f", "wav",
            "-acodec", "pcm_f32le",
            "-y",
            outputPath
        ]
    }

    public func ffmpegMixArguments(inputPaths: [String], outputPath: String) -> [String] {
        var args = ["-nostdin"]
        for inputPath in inputPaths {
            args.append(contentsOf: ["-i", inputPath])
        }

        let outputArgs: [String]
        if inputPaths.count == 2 {
            args.append(contentsOf: [
                "-filter_complex",
                "[0:a]pan=stereo|c0=c0|c1=0*c0[a0];[1:a]pan=stereo|c0=0*c0|c1=c0[a1];[a0][a1]amix=inputs=2:duration=longest:normalize=0[a]",
                "-map", "[a]"
            ])
            outputArgs = [
                "-ar", "48000",
                "-ac", "2",
                "-c:a", "aac",
                "-b:a", "128k",
            ]
        } else if inputPaths.count > 2 {
            let inputRefs = inputPaths.indices.map { "[\($0):a]" }.joined()
            args.append(contentsOf: [
                "-filter_complex",
                "\(inputRefs)amix=inputs=\(inputPaths.count):duration=longest:normalize=1",
            ])
            outputArgs = [
                "-ar", "16000",
                "-ac", "1",
                "-c:a", "aac",
                "-b:a", "64k",
            ]
        } else {
            outputArgs = [
                "-ar", "16000",
                "-ac", "1",
                "-c:a", "aac",
                "-b:a", "64k",
            ]
        }

        args.append(contentsOf: outputArgs + [
            "-y", outputPath,
        ])
        return args
    }

    // MARK: - Private

    private func runFFmpegConversion(
        ffmpegPath: String, inputURL: URL, tempDir: URL
    ) async throws -> URL {
        let outputURL = tempDir.appendingPathComponent("\(UUID().uuidString).wav")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = [
            "-nostdin",          // Don't read stdin (prevents SIGTTIN stop signal)
            "-i", inputURL.path,
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
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { stderrHandle.closeFile() }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        try await runProcessAndWait(process, timeout: 600)

        if process.terminationStatus != 0 {
            stderrHandle.synchronizeFile()
            let stderrStr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "Unknown error"
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioProcessorError.conversionFailed(stderrStr)
        }

        return outputURL
    }

    private func runFFmpegMix(
        ffmpegPath: String,
        inputURLs: [URL],
        outputURL: URL
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = ffmpegMixArguments(
            inputPaths: inputURLs.map(\.path),
            outputPath: outputURL.path
        )

        let tempDir = try ensureTempDir()
        let stderrURL = tempDir.appendingPathComponent("ffmpeg-mix-stderr-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: stderrURL) }
        FileManager.default.createFile(atPath: stderrURL.path, contents: Data())
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { stderrHandle.closeFile() }

        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        try await runProcessAndWait(process, timeout: 600)

        if process.terminationStatus != 0 {
            stderrHandle.synchronizeFile()
            let stderrStr = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? "Unknown error"
            try? FileManager.default.removeItem(at: outputURL)
            throw AudioProcessorError.conversionFailed(stderrStr)
        }
    }

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
            return try BinaryBootstrap.requireRuntimeFFmpegPath()
        } catch {
            throw AudioProcessorError.conversionFailed(
                "FFmpeg is unavailable for this runtime. Reinstall MacParakeet, or for `swift run` set `MACPARAKEET_FFMPEG_PATH` or ensure `ffmpeg` is in PATH."
            )
        }
    }

    private func runProcessAndWait(_ process: Process, timeout: TimeInterval) async throws {
        try process.run()

        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    let shouldResume = resumed.withLock { done -> Bool in
                        guard !done else { return false }
                        done = true
                        return true
                    }
                    if shouldResume {
                        process.terminate()
                        continuation.resume(
                            throwing: AudioProcessorError.conversionFailed("FFmpeg conversion timed out")
                        )
                    }
                }

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
        } onCancel: {
            process.terminate()
        }

        try Task.checkCancellation()
    }
}
