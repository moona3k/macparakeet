// Research-only experiment. Creates synthetic tones in the supplied scratch directory.
// Does not import MacParakeet, open user recordings, or change the app database.
import Foundation
import AVFoundation
import CryptoKit

@main
struct AudioRangeSpike {
    static func export(_ source: URL, to destination: URL, preset: String,
                       startMs: Int, endMs: Int) async throws {
        let asset = AVURLAsset(url: source)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw NSError(domain: "SplitSpike", code: 1)
        }
        // Derive each boundary once on the same integer sample grid. Building
        // duration separately from floating-point seconds lost a frame here.
        session.timeRange = CMTimeRange(
            start: CMTime(value: Int64(startMs) * 48, timescale: 48_000),
            end: CMTime(value: Int64(endMs) * 48, timescale: 48_000))
        if #available(macOS 15, *) {
            try await session.export(to: destination, as: .m4a)
        } else {
            session.outputURL = destination
            session.outputFileType = .m4a
            await session.export()
            guard session.status == .completed else {
                throw session.error ?? NSError(domain: "SplitSpike", code: 2)
            }
        }
    }

    static func hash(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    static func main() async throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "Usage: audio-range-spike SCRATCH_DIRECTORY", code: 3)
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let pcmURL = folder.appendingPathComponent("synthetic.caf")
        let sourceURL = folder.appendingPathComponent("synthetic.m4a")
        let rate = 48_000.0
        let total = 8.0
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: pcmURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total * rate))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                // Distinct frequency per second makes the fixture reproducible.
                let frequency = 220.0 + 110.0 * floor(Double(i) / rate)
                buffer.floatChannelData![0][i] = Float(0.15 * sin(2 * .pi * frequency * Double(i) / rate))
            }
            try file.write(from: buffer)
        }
        try await export(pcmURL, to: sourceURL, preset: AVAssetExportPresetAppleM4A, startMs: 0, endMs: 8000)
        let before = try hash(sourceURL)
        let points = [0, 2137, 5419, 8000]
        var results: [[String: Any]] = []
        for (name, preset) in [("aac_reencode", AVAssetExportPresetAppleM4A),
                               ("passthrough", AVAssetExportPresetPassthrough)] {
            for i in 0..<points.count - 1 {
                let destination = folder.appendingPathComponent("\(name)-part-\(i + 1).m4a")
                let requested = Double(points[i + 1] - points[i]) / 1000
                let begin = Date()
                try await export(sourceURL, to: destination, preset: preset,
                                 startMs: points[i], endMs: points[i + 1])
                let exportSeconds = Date().timeIntervalSince(begin)
                let actual = try await AVURLAsset(url: destination).load(.duration).seconds
                let decoded = try AVAudioFile(forReading: destination)
                let buffer = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: 4096)!
                var frames: Int64 = 0
                var peak: Float = 0
                while decoded.framePosition < decoded.length {
                    try decoded.read(into: buffer)
                    guard buffer.frameLength > 0 else { break }
                    frames += Int64(buffer.frameLength)
                    for f in 0..<Int(buffer.frameLength) {
                        peak = max(peak, abs(buffer.floatChannelData![0][f]))
                    }
                }
                results.append([
                    "mode": name, "part": i + 1, "sourceStartSeconds": Double(points[i]) / 1000,
                    "requestedSeconds": requested, "assetSeconds": actual,
                    "durationErrorMs": (actual - requested) * 1000,
                    "decodedFrames": frames, "decodedSampleRate": decoded.processingFormat.sampleRate,
                    "decodedSeconds": Double(frames) / decoded.processingFormat.sampleRate,
                    "nonSilent": peak > 0.01, "exportSeconds": exportSeconds
                ])
            }
        }
        let report: [String: Any] = [
            "experiment": "Synthetic AAC range export; not production validation",
            "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
            "sourceSeconds": total, "sourceSHA256": before,
            "sourceUnchanged": before == (try hash(sourceURL)), "outputs": results,
            "limitations": "Eight-second mono synthetic fixture only. No dual-source alignment, waveform equivalence, long-file performance, crash recovery, or app integration validated."
        ]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    }
}
