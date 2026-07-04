import FluidAudio
import Foundation

struct HarnessError: Error, CustomStringConvertible {
    let description: String
}

struct Options {
    var audio: URL?
    var sessionID: String?
    var track: String?
    var modelsDirectory: URL?
    var output: URL?
    var splitHalf = false
    var ffmpegPath: String?
    var ffprobePath: String?
}

struct SpeakerOutput: Codable {
    let speakerId: String
    let totalSpeechSec: Double
    let embedding: [Float]
}

struct TimingsOutput: Codable {
    let modelCompilationSeconds: Double?
    let audioLoadingSeconds: Double?
    let segmentationSeconds: Double?
    let embeddingExtractionSeconds: Double?
    let speakerClusteringSeconds: Double?
    let postProcessingSeconds: Double?
}

struct FullOutput: Codable {
    let schemaVersion: Int
    let mode: String
    let generatedAt: String
    let sessionID: String
    let track: String
    let sourceFile: String
    let audioDurationSec: Double?
    let segmentCount: Int
    let speakers: [SpeakerOutput]
    let timings: TimingsOutput?
}

struct HalfOutput: Codable {
    let half: String
    let startSec: Double
    let endSec: Double
    let segmentCount: Int
    let speakers: [SpeakerOutput]
    let timings: TimingsOutput?
}

struct SplitOutput: Codable {
    let schemaVersion: Int
    let mode: String
    let generatedAt: String
    let sessionID: String
    let track: String
    let sourceFile: String
    let audioDurationSec: Double
    let halves: [HalfOutput]
}

@main
enum VoiceprintHarness {
    static func main() async {
        do {
            let options = try parse(Array(CommandLine.arguments.dropFirst()))
            guard let audio = options.audio else { throw HarnessError(description: "missing --audio") }
            guard let sessionID = options.sessionID else { throw HarnessError(description: "missing --session-id") }
            guard let track = options.track else { throw HarnessError(description: "missing --track") }
            guard FileManager.default.fileExists(atPath: audio.path) else {
                throw HarnessError(description: "audio file does not exist: \(audio.path)")
            }

            let modelsDirectory = options.modelsDirectory
                ?? OfflineDiarizerModels.defaultModelsDirectory()

            let output: Data
            if options.splitHalf {
                output = try await runSplitHalf(
                    audio: audio,
                    sessionID: sessionID,
                    track: track,
                    modelsDirectory: modelsDirectory,
                    ffmpegPath: options.ffmpegPath,
                    ffprobePath: options.ffprobePath
                )
            } else {
                output = try await runFull(
                    audio: audio,
                    sessionID: sessionID,
                    track: track,
                    modelsDirectory: modelsDirectory,
                    ffmpegPath: options.ffmpegPath,
                    ffprobePath: options.ffprobePath
                )
            }

            if let outputURL = options.output {
                try FileManager.default.createDirectory(
                    at: outputURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try output.write(to: outputURL, options: [.atomic])
            } else {
                FileHandle.standardOutput.write(output)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            FileHandle.standardError.write(Data("voiceprint-harness: \(error)\n".utf8))
            exit(1)
        }
    }

    static func parse(_ args: [String]) throws -> Options {
        if args.contains("--help") || args.contains("-h") {
            printHelp()
            exit(0)
        }

        var options = Options()
        var index = 0
        while index < args.count {
            let arg = args[index]
            switch arg {
            case "--audio":
                options.audio = URL(fileURLWithPath: try value(after: arg, args: args, index: &index))
            case "--session-id":
                options.sessionID = try value(after: arg, args: args, index: &index)
            case "--track":
                options.track = try value(after: arg, args: args, index: &index)
            case "--models-dir":
                options.modelsDirectory = URL(fileURLWithPath: try value(after: arg, args: args, index: &index))
            case "--output":
                options.output = URL(fileURLWithPath: try value(after: arg, args: args, index: &index))
            case "--split-half":
                options.splitHalf = true
            case "--ffmpeg":
                options.ffmpegPath = try value(after: arg, args: args, index: &index)
            case "--ffprobe":
                options.ffprobePath = try value(after: arg, args: args, index: &index)
            default:
                throw HarnessError(description: "unknown argument: \(arg)")
            }
            index += 1
        }
        return options
    }

    static func value(after flag: String, args: [String], index: inout Int) throws -> String {
        let next = index + 1
        guard next < args.count else { throw HarnessError(description: "missing value after \(flag)") }
        index = next
        return args[next]
    }

    static func printHelp() {
        print("""
        Usage:
          voiceprint-harness --audio PATH --session-id UUID --track microphone|system \\
            --models-dir "$HOME/Library/Application Support/FluidAudio/Models" \\
            --output out.json [--split-half]

        Output contains session ID, track, speaker IDs, total speech seconds, and 256-d embeddings only.
        Runs normalize source audio to temporary 16 kHz mono WAV files under /tmp and delete them before exit.
        """)
    }

    static func runFull(
        audio: URL,
        sessionID: String,
        track: String,
        modelsDirectory: URL,
        ffmpegPath: String?,
        ffprobePath: String?
    ) async throws -> Data {
        let duration = try? probeDuration(path: audio.path, ffprobePath: ffprobePath)
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprint-phase0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let wavURL = tempRoot.appendingPathComponent("full.wav", isDirectory: false)
        try makeNormalizedWav(input: audio.path, output: wavURL.path, ffmpegPath: ffmpegPath)

        let result = try await diarize(audio: wavURL, modelsDirectory: modelsDirectory)
        let output = FullOutput(
            schemaVersion: 1,
            mode: "full",
            generatedAt: isoNow(),
            sessionID: sessionID,
            track: track,
            sourceFile: audio.lastPathComponent,
            audioDurationSec: duration,
            segmentCount: result.segments.count,
            speakers: speakers(from: result),
            timings: timings(from: result)
        )
        return try encode(output)
    }

    static func runSplitHalf(
        audio: URL,
        sessionID: String,
        track: String,
        modelsDirectory: URL,
        ffmpegPath: String?,
        ffprobePath: String?
    ) async throws -> Data {
        let duration = try probeDuration(path: audio.path, ffprobePath: ffprobePath)
        guard duration >= 2 else {
            throw HarnessError(description: "audio too short for split-half mode: \(duration)s")
        }

        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("voiceprint-phase0-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let midpoint = duration / 2
        let firstURL = tempRoot.appendingPathComponent("first.wav", isDirectory: false)
        let secondURL = tempRoot.appendingPathComponent("second.wav", isDirectory: false)

        try makeWavClip(
            input: audio.path,
            output: firstURL.path,
            start: 0,
            duration: midpoint,
            ffmpegPath: ffmpegPath
        )
        try makeWavClip(
            input: audio.path,
            output: secondURL.path,
            start: midpoint,
            duration: duration - midpoint,
            ffmpegPath: ffmpegPath
        )

        let first = try await diarize(audio: firstURL, modelsDirectory: modelsDirectory)
        let second = try await diarize(audio: secondURL, modelsDirectory: modelsDirectory)

        let output = SplitOutput(
            schemaVersion: 1,
            mode: "splitHalf",
            generatedAt: isoNow(),
            sessionID: sessionID,
            track: track,
            sourceFile: audio.lastPathComponent,
            audioDurationSec: duration,
            halves: [
                HalfOutput(
                    half: "first",
                    startSec: 0,
                    endSec: midpoint,
                    segmentCount: first.segments.count,
                    speakers: speakers(from: first),
                    timings: timings(from: first)
                ),
                HalfOutput(
                    half: "second",
                    startSec: midpoint,
                    endSec: duration,
                    segmentCount: second.segments.count,
                    speakers: speakers(from: second),
                    timings: timings(from: second)
                ),
            ]
        )
        return try encode(output)
    }

    static func diarize(audio: URL, modelsDirectory: URL) async throws -> DiarizationResult {
        var config = OfflineDiarizerConfig.default
        config.exposeChunkEmbeddings = false

        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels(directory: modelsDirectory)

        do {
            return try await manager.process(audio) { processed, total in
                guard processed == total || processed == 1 || processed % 50 == 0 else { return }
                let message = "progress \(audio.lastPathComponent) \(processed)/\(total)\n"
                FileHandle.standardError.write(Data(message.utf8))
            }
        } catch let error as OfflineDiarizationError {
            if case .noSpeechDetected = error {
                return DiarizationResult(segments: [], speakerDatabase: [:])
            }
            throw error
        }
    }

    static func speakers(from result: DiarizationResult) -> [SpeakerOutput] {
        let totals = Dictionary(grouping: result.segments, by: { $0.speakerId })
            .mapValues { segments in
                segments.reduce(0.0) { total, segment in
                    total + max(0.0, Double(segment.endTimeSeconds - segment.startTimeSeconds))
                }
            }

        let database = result.speakerDatabase ?? fallbackSpeakerDatabase(from: result.segments)
        return database.keys.sorted().compactMap { speakerId in
            guard let embedding = database[speakerId], embedding.count == 256 else { return nil }
            return SpeakerOutput(
                speakerId: speakerId,
                totalSpeechSec: totals[speakerId] ?? 0,
                embedding: embedding
            )
        }
    }

    static func fallbackSpeakerDatabase(from segments: [TimedSpeakerSegment]) -> [String: [Float]] {
        var sums: [String: [Double]] = [:]
        var weights: [String: Double] = [:]

        for segment in segments where segment.embedding.count == 256 {
            let duration = max(0.0, Double(segment.endTimeSeconds - segment.startTimeSeconds))
            guard duration > 0 else { continue }
            var sum = sums[segment.speakerId] ?? Array(repeating: 0, count: 256)
            for index in 0..<256 {
                sum[index] += Double(segment.embedding[index]) * duration
            }
            sums[segment.speakerId] = sum
            weights[segment.speakerId, default: 0] += duration
        }

        var database: [String: [Float]] = [:]
        for (speakerId, sum) in sums {
            let weight = max(weights[speakerId] ?? 0, .leastNonzeroMagnitude)
            let averaged = sum.map { Float($0 / weight) }
            database[speakerId] = l2Normalized(averaged)
        }
        return database
    }

    static func l2Normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func timings(from result: DiarizationResult) -> TimingsOutput? {
        guard let timings = result.timings else { return nil }
        return TimingsOutput(
            modelCompilationSeconds: timings.modelCompilationSeconds,
            audioLoadingSeconds: timings.audioLoadingSeconds,
            segmentationSeconds: timings.segmentationSeconds,
            embeddingExtractionSeconds: timings.embeddingExtractionSeconds,
            speakerClusteringSeconds: timings.speakerClusteringSeconds,
            postProcessingSeconds: timings.postProcessingSeconds
        )
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    static func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    static func probeDuration(path: String, ffprobePath: String?) throws -> Double {
        let executable = try resolveExecutable(explicit: ffprobePath, name: "ffprobe")
        let output = try runProcess(
            executable,
            [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                path,
            ]
        )
        guard let duration = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw HarnessError(description: "ffprobe did not return a duration for \(path)")
        }
        return duration
    }

    static func makeWavClip(
        input: String,
        output: String,
        start: Double,
        duration: Double,
        ffmpegPath: String?
    ) throws {
        let executable = try resolveExecutable(explicit: ffmpegPath, name: "ffmpeg")
        _ = try runProcess(
            executable,
            [
                "-hide_banner",
                "-loglevel", "error",
                "-ss", String(format: "%.6f", start),
                "-t", String(format: "%.6f", duration),
                "-i", input,
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_f32le",
                "-y",
                output,
            ]
        )
    }

    static func makeNormalizedWav(
        input: String,
        output: String,
        ffmpegPath: String?
    ) throws {
        let executable = try resolveExecutable(explicit: ffmpegPath, name: "ffmpeg")
        _ = try runProcess(
            executable,
            [
                "-hide_banner",
                "-loglevel", "error",
                "-i", input,
                "-vn",
                "-ac", "1",
                "-ar", "16000",
                "-c:a", "pcm_f32le",
                "-y",
                output,
            ]
        )
    }

    static func resolveExecutable(explicit: String?, name: String) throws -> String {
        if let explicit {
            return explicit
        }
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        if let candidate = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return candidate
        }
        throw HarnessError(description: "\(name) not found; pass --\(name) PATH")
    }

    static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdout = Pipe()
        let stderrURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "voiceprint-harness-\(UUID().uuidString).stderr"
        )
        _ = FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stderrURL)
        }
        process.standardOutput = stdout
        process.standardError = stderrHandle

        try process.run()
        let outData = try stdout.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        try? stderrHandle.close()

        let errData = (try? Data(contentsOf: stderrURL)) ?? Data()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = err.isEmpty ? out : err
            throw HarnessError(description: "\(URL(fileURLWithPath: executable).lastPathComponent) failed: \(detail)")
        }
        return out
    }
}
