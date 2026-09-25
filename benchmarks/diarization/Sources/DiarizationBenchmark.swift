import ArgumentParser
import CryptoKit
import Darwin
import Foundation
import MacParakeetCore

@main
struct DiarizationBenchmark: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Run one local diarization backend and preserve acoustic intervals.")

    enum Backend: String, ExpressibleByArgument, CaseIterable {
        case community1
        case nemotron
        case nemotronOffline = "nemotron-offline"
    }

    @Argument var audio: String
    @Option var backend: Backend
    @Option var output: String
    @Option var modelsDirectory: String?

    struct Segment: Codable {
        let speakerId: String
        let startMs: Int
        let endMs: Int
    }

    struct Result: Codable {
        let backend: String
        let config: [String: String]
        let audioSHA256: String
        let speakerCount: Int
        let segments: [Segment]
        let modelPreparationSeconds: Double
        let runtimeSeconds: Double
        let peakResidentBytes: Int64
    }

    func run() async throws {
        let source = URL(fileURLWithPath: audio)
        let directory = modelsDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
        let service: any DiarizationServiceProtocol
        switch backend {
        case .community1:
            service = DiarizationService(modelsDirectory: directory)
        case .nemotron:
            service = NemotronDiarizationService(preset: .fast128, modelsDirectory: directory)
        case .nemotronOffline:
            service = NemotronDiarizationService(preset: .offline, modelsDirectory: directory)
        }
        let loadingStart = Date()
        try await service.prepareModels()
        let loadingSeconds = Date().timeIntervalSince(loadingStart)
        let start = Date()
        let result = try await service.diarize(audioURL: source)
        let seconds = Date().timeIntervalSince(start)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let audioBytes = try Data(contentsOf: source, options: .mappedIfSafe)
        let digest = SHA256.hash(data: audioBytes).map { String(format: "%02x", $0) }.joined()
        #if DEBUG
        let buildConfiguration = "debug"
        #else
        let buildConfiguration = "release"
        #endif
        var configuration = [
            "fluidAudioVersion": "0.17.4",
            "fluidAudioRevision": "21493f8dac5a97e65742e6ff26f42f164c2fda0f",
            "speakerConstraint": "automatic",
            "minimumSegmentSeconds": "0",
            "buildConfiguration": buildConfiguration,
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "computeUnits": backend == .community1
                ? "all; FBank cpuOnly"
                : (backend == .nemotronOffline || ANEInferenceGate.serializationRequiredForCurrentOS
                    ? "cpuAndGPU" : "all"),
        ]
        if backend != .community1 {
            configuration["nemotronModelRevision"] = "1b0b133f6f8820292010afd776d8f9fbc9fca17e"
            configuration["threshold"] = "0.5"
            configuration["feedSamples"] = "16000"
        }
        let payload = Result(
            backend: backend.rawValue,
            config: configuration,
            audioSHA256: digest,
            speakerCount: result.speakerCount,
            segments: result.segments.map { Segment(speakerId: $0.speakerId, startMs: $0.startMs, endMs: $0.endMs) },
            modelPreparationSeconds: loadingSeconds,
            runtimeSeconds: seconds,
            peakResidentBytes: Int64(usage.ru_maxrss)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(payload).write(to: destination, options: .atomic)
        print("\(backend.rawValue): \(result.speakerCount) speakers, \(result.segments.count) intervals, \(seconds)s")
    }
}
