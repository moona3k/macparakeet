import Foundation

public protocol AudioTrackProbing: Sendable {
    func tracks(in fileURL: URL) async throws -> [AudioTrackDescriptor]
}

/// Discovers embedded audio streams from FFmpeg's input summary.
///
/// MacParakeet already ships FFmpeg but not ffprobe. Keeping this parser behind
/// a small protocol gives the app deterministic numbered tracks even when a
/// container does not provide language metadata, without adding another
/// runtime binary.
public final class FFmpegAudioTrackProbe: AudioTrackProbing, Sendable {
    struct ProbeResult: Sendable {
        let output: String
        let terminationStatus: Int32
    }

    typealias RunProbe = @Sendable (URL) async throws -> ProbeResult

    private let runProbe: RunProbe

    public convenience init() {
        self.init(runProbe: { fileURL in
            try await Self.runFFmpegProbe(fileURL: fileURL)
        })
    }

    init(runProbe: @escaping RunProbe) {
        self.runProbe = runProbe
    }

    public func tracks(in fileURL: URL) async throws -> [AudioTrackDescriptor] {
        let result = try await runProbe(fileURL)
        guard result.terminationStatus == 0 else {
            throw AudioProcessorError.conversionFailed(
                AudioFileConverter.tailForError(result.output)
            )
        }
        return Self.parseTracks(from: result.output)
    }

    private static func parseTracks(from output: String) -> [AudioTrackDescriptor] {
        let pattern = #"^\s*Stream #0:(\d+)(?:\[[^]]+\])?(?:\(([^)]+)\))?: Audio:.*$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        var tracks: [AudioTrackDescriptor] = []
        for line in output.split(whereSeparator: \Character.isNewline) {
            let string = String(line)
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            if trimmed == "Stream mapping:" || trimmed.hasPrefix("Output #") {
                break
            }
            let range = NSRange(string.startIndex..., in: string)
            guard let match = expression.firstMatch(in: string, range: range),
                let streamRange = Range(match.range(at: 1), in: string),
                let streamIndex = Int(string[streamRange])
            else {
                continue
            }

            let languageCode: String?
            if let range = Range(match.range(at: 2), in: string) {
                languageCode = String(string[range])
            } else {
                languageCode = nil
            }

            tracks.append(
                AudioTrackDescriptor(
                    ordinal: tracks.count,
                    streamIndex: streamIndex,
                    languageCode: languageCode,
                    isDefault: string.localizedCaseInsensitiveContains("(default)")
                ))
        }
        return tracks
    }

    private static func runFFmpegProbe(fileURL: URL) async throws -> ProbeResult {
        let primaryPath: String
        do {
            primaryPath = try BinaryBootstrap.requireRuntimeFFmpegPath()
        } catch {
            throw AudioProcessorError.conversionFailed(
                "FFmpeg is unavailable for this runtime. Reinstall MacParakeet, or for `swift run` set `MACPARAKEET_FFMPEG_PATH` or ensure `ffmpeg` is in PATH."
            )
        }

        let primaryOutput = try await runFFmpegProbe(fileURL: fileURL, ffmpegPath: primaryPath)
        if (primaryOutput.output.contains("dyld")
            || primaryOutput.output.contains("Library not loaded")),
            let fallbackPath = BinaryBootstrap.findSystemFFmpeg(),
            fallbackPath != primaryPath
        {
            return try await runFFmpegProbe(fileURL: fileURL, ffmpegPath: fallbackPath)
        }
        return primaryOutput
    }

    private static func runFFmpegProbe(fileURL: URL, ffmpegPath: String) async throws -> ProbeResult {
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macparakeet-audio-tracks-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: logURL) }

        let handle = try FileHandle(forWritingTo: logURL)
        defer { try? handle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        // A bare `-i` always exits nonzero because no output was requested,
        // making an unreadable file indistinguishable from a successful probe.
        // A zero-duration null output validates the input without transcoding it.
        process.arguments = [
            "-hide_banner", "-nostdin", "-i", fileURL.path,
            "-c", "copy", "-t", "0", "-f", "null", "-",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = handle

        try process.run()
        try await ChildProcessWaiter.waitUntilExit(
            process,
            timeout: 30,
            timeoutError: AudioProcessorError.conversionFailed("Audio-track discovery timed out")
        )
        try handle.synchronize()
        return ProbeResult(
            output: (try? String(contentsOf: logURL, encoding: .utf8)) ?? "",
            terminationStatus: process.terminationStatus
        )
    }
}
