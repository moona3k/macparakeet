import AVFoundation
import Foundation
import CryptoKit

// Adjacent app metadata/error types are stubbed; both renderers and their DSP,
// codec adapter and scratch implementation below are actual repository source.
enum MeetingAudioError: Error { case storageFailed(String) }
enum HarnessError: Error { case unexpectedOutcome(String) }
enum MeetingArtifactAudioFileNames { static let cleanedMicrophone = "microphone-cleaned.m4a" }
struct MeetingSourceAlignment {
    struct Source { let startOffsetMs: Int }
    var microphone: Source? = nil
    var system: Source? = nil
}
final class UncheckedSendableAudioPCMBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
}
final class ProbeConditioner: MicConditioning, @unchecked Sendable {
    var diagnostics: MeetingEchoSuppressionDiagnostics { .passthrough(processorName: "synthetic", loaded: true) }
    func reset() {}
    func condition(microphone: [Float], speaker: [Float], hasSpeakerReference: Bool) -> [Float] {
        zip(microphone, speaker).map { $0 - $1 * 0.25 }
    }
}
@main struct Probe {
    static func main() async throws {
        let mode = CommandLine.arguments[1]
        let seconds = Int(CommandLine.arguments[2])!
        let noEcho = CommandLine.arguments.contains("no-echo")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let microphone = directory.appendingPathComponent("mic.caf")
        let system = directory.appendingPathComponent("system.caf")
        try makeSource(microphone, seconds: seconds, scale: 0.5)
        try makeSource(system, seconds: seconds, scale: noEcho ? 0 : 1)
        let start = ContinuousClock.now
        let observed: Observed
        if mode == "baseline" {
            let result = try await BaselineCleanedMicRenderer().render(
                microphoneURL: microphone, systemURL: system, sourceAlignment: .init(),
                outputURL: directory.appendingPathComponent("out.m4a"), conditioner: ProbeConditioner())
            switch result {
            case .rendered(let result):
                observed = Observed(
                    line: "rendered seconds=\(result.durationSeconds) ratio=\(result.outputToRawRmsRatio) probe=\(result.echoProbe)",
                    rendered: true, noEchoDetail: nil)
            case .skipped(let reason):
                var detail: String?
                if case .noEchoPath(let probe) = reason { detail = probe.detail }
                observed = Observed(line: "skipped \(reason)", rendered: false, noEchoDetail: detail)
            }
        } else {
            let result = try await MeetingCleanedMicRenderer().render(
                microphoneURL: microphone, systemURL: system, sourceAlignment: .init(),
                outputURL: directory.appendingPathComponent("out.m4a"), conditioner: ProbeConditioner())
            switch result {
            case .rendered(let result):
                observed = Observed(
                    line: "rendered seconds=\(result.durationSeconds) ratio=\(result.outputToRawRmsRatio) probe=\(result.echoProbe)",
                    rendered: true, noEchoDetail: nil)
            case .skipped(let reason):
                var detail: String?
                if case .noEchoPath(let probe) = reason { detail = probe.detail }
                observed = Observed(line: "skipped \(reason)", rendered: false, noEchoDetail: detail)
            }
        }
        print(observed.line)
        let elapsed = start.duration(to: .now)
        let output = directory.appendingPathComponent("out.m4a")
        if FileManager.default.fileExists(atPath: output.path) {
            try printDigest(output)
        }
        print("mode=\(mode) input_seconds=\(seconds) no_echo=\(noEcho) render_elapsed=\(elapsed)")
        try observed.requireExpected(noEcho: noEcho)
    }
    struct Observed {
        let line: String
        let rendered: Bool
        let noEchoDetail: String?
        func requireExpected(noEcho: Bool) throws {
            if noEcho {
                guard !rendered, noEchoDetail == "no_reference_energy" else {
                    throw HarnessError.unexpectedOutcome("no-echo fixture expected noEchoPath/no_reference_energy, got: \(line)")
                }
            } else {
                guard rendered else {
                    throw HarnessError.unexpectedOutcome("echo fixture expected a rendered output, got: \(line)")
                }
            }
        }
    }
    static func printDigest(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384)!
        var hash = SHA256()
        var frames: Int64 = 0
        while frames < file.length {
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(16_384, file.length - frames)))
            guard buffer.frameLength > 0 else { break }
            frames += Int64(buffer.frameLength)
            hash.update(data: Data(bytes: buffer.floatChannelData![0], count: Int(buffer.frameLength) * 4))
        }
        print("decoded_frames=\(frames) decoded_pcm_sha256=\(hash.finalize().map { String(format: "%02x", $0) }.joined())")
    }
    static func makeSource(_ url: URL, seconds: Int, scale: Float) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384)!
        let channel = buffer.floatChannelData![0]
        var state: UInt64 = 42
        for index in 0..<16_384 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            channel[index] = Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max) * 0.2 * scale
        }
        var remaining = seconds * 16_000
        while remaining > 0 {
            buffer.frameLength = AVAudioFrameCount(min(remaining, 16_384))
            try file.write(from: buffer)
            remaining -= Int(buffer.frameLength)
        }
    }
}
