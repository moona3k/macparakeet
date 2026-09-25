import CryptoKit
import Darwin
import FluidAudio
import Foundation

/// Frozen acoustic baseline from MacParakeet commit
/// 7ad569afae560266b37a0003e9e2b9f17a2dfa47 DiarizationService.swift:
/// highAccuracyConfig, modelLoader, chronological ID mapping and millisecond
/// rounding. See README.md for provenance and deliberately excluded app work.
@main
struct DiarizationBaseline {
    struct Segment: Codable {
        let speakerId: String
        let startMs: Int
        let endMs: Int
    }

    struct Result: Codable {
        let backend: String
        let config: [String: String]
        let audioSHA256: String
        let modelFilesSHA256: [String: String]
        let speakerCount: Int
        let segments: [Segment]
        let modelPreparationSeconds: Double
        let runtimeSeconds: Double
        let peakResidentBytes: Int64
    }

    struct Arguments {
        let audio: URL
        let output: URL
        let modelsDirectory: URL

        init(_ arguments: [String]) throws {
            guard let audio = arguments.first, !audio.hasPrefix("-") else {
                throw Failure("The first argument must be a local audio path")
            }
            var options: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                let option = arguments[index]
                guard ["--output", "--models-directory"].contains(option),
                    index + 1 < arguments.count, options[option] == nil
                else { throw Failure("Unknown, duplicate, or incomplete option: \(option)") }
                options[option] = arguments[index + 1]
                index += 2
            }
            guard let output = options["--output"], let directory = options["--models-directory"] else {
                throw Failure("Both --output and --models-directory are required")
            }
            self.audio = URL(fileURLWithPath: audio).standardizedFileURL
            self.output = URL(fileURLWithPath: output).standardizedFileURL
            modelsDirectory = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func main() async throws {
        let command = Array(CommandLine.arguments.dropFirst())
        if command == ["--help"] || command == ["-h"] {
            print(
                """
                USAGE: diarization-baseline AUDIO --output JSON --models-directory MODELS_ROOT

                Runs the frozen MacParakeet automatic Community-1 configuration with
                FluidAudio 0.15.7. MODELS_ROOT contains speaker-diarization/, usually
                ~/Library/Application Support/FluidAudio/Models. Existing models are
                required; network downloads and cache repair are disabled. Outputs
                raw acoustic intervals, timing, peak RSS, audio and model-file hashes.
                """)
            return
        }
        let arguments = try Arguments(command)
        // Freeze cached model bytes and prevent a mutable upstream `main` from
        // silently changing the experimental baseline or repairing the cache.
        ModelHub.offlineMode = true
        let modelHashes = try modelHashes(in: arguments.modelsDirectory)
        let audioHash = try hashFile(arguments.audio)
        let config = highAccuracyConfig

        let preparationStart = Date()
        let models = try await OfflineDiarizerModels.load(from: arguments.modelsDirectory)
        let preparationSeconds = Date().timeIntervalSince(preparationStart)
        let manager = OfflineDiarizerManager(config: config)
        manager.initialize(models: models)
        let start = Date()
        var segments: [Segment] = []
        var idMapping: [String: String] = [:]
        do {
            let result = try await manager.process(arguments.audio)
            let chronological = result.segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
            for segment in chronological where idMapping[segment.speakerId] == nil {
                idMapping[segment.speakerId] = "S\(idMapping.count + 1)"
            }
            segments = chronological.map { segment in
                Segment(
                    speakerId: idMapping[segment.speakerId] ?? segment.speakerId,
                    startMs: max(0, Int((segment.startTimeSeconds * 1000).rounded())),
                    endMs: max(0, Int((segment.endTimeSeconds * 1000).rounded()))
                )
            }
        } catch OfflineDiarizationError.noSpeechDetected {
            // This is the production service's successful empty-result policy.
        }
        let seconds = Date().timeIntervalSince(start)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let result = Result(
            backend: "community1-0.15.7",
            config: [
                "fluidAudioVersion": "0.15.7",
                "fluidAudioRevision": "41540ea237350afe5117a082b5c28eda642d0612",
                "appConfigurationRevision": "7ad569afae560266b37a0003e9e2b9f17a2dfa47",
                "speakerConstraint": "automatic",
                "segmentationStepRatio": String(config.segmentation.stepRatio),
                "minimumSegmentSeconds": String(config.embedding.minSegmentDurationSeconds),
                "zeroVoteReembed": String(config.zeroVoteReembed.enabled),
                "clusteringThreshold": String(config.clustering.threshold),
                "computeUnits": "all (FBank cpuOnly)",
                "modelSource": "existing local cache; see modelFilesSHA256; upstream revision not inferred",
                "offlineConfig": String(describing: config),
            ],
            audioSHA256: audioHash,
            modelFilesSHA256: modelHashes,
            speakerCount: idMapping.count,
            segments: segments,
            modelPreparationSeconds: preparationSeconds,
            runtimeSeconds: seconds,
            peakResidentBytes: Int64(usage.ru_maxrss)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(
            at: arguments.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(result).write(to: arguments.output, options: .atomic)
        print("community1-0.15.7: \(idMapping.count) speakers, \(segments.count) intervals, \(seconds)s")
    }

    static var highAccuracyConfig: OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        config.segmentation.stepRatio = 0.1
        config.embedding.minSegmentDurationSeconds = 0
        config.zeroVoteReembed = OfflineDiarizerConfig.ZeroVoteReembed(enabled: true)
        return config
    }

    static func hashFile(_ path: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: path)
        defer { try? file.close() }
        var hash = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func modelHashes(in directory: URL) throws -> [String: String] {
        let repository = directory.appendingPathComponent(Repo.diarizer.folderName, isDirectory: true)
        var hashes: [String: String] = [:]
        for name in ModelNames.OfflineDiarizer.requiredModels.sorted() {
            let path = repository.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path.path, isDirectory: &isDirectory) else {
                throw Failure("Required cached model is missing: \(path.path)")
            }
            if isDirectory.boolValue {
                guard
                    let files = FileManager.default.enumerator(
                        at: path, includingPropertiesForKeys: [.isRegularFileKey])
                else {
                    throw Failure("Cannot enumerate cached model: \(path.path)")
                }
                for case let file as URL in files {
                    if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                        let relative = String(file.path.dropFirst(repository.path.count + 1))
                        hashes[relative] = try hashFile(file)
                    }
                }
            } else {
                hashes[name] = try hashFile(path)
            }
        }
        return hashes
    }
}
