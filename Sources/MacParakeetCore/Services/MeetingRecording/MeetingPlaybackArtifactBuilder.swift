@preconcurrency import AVFoundation
import Foundation

/// Builds the canonical, decodable meeting playback artifact from finalized
/// source files. Source tracks remain the durable capture truth; this builder
/// only owns the derived playback file and its probed duration.
actor MeetingPlaybackArtifactBuilder {
    /// `FileManager` is documented for concurrent use when no delegate is
    /// installed. This wrapper preserves the callers' injected filesystem
    /// dependency while the builder serializes its own operations.
    struct SendableFileManager: @unchecked Sendable {
        fileprivate let value: FileManager

        init(_ value: FileManager = .default) {
            self.value = value
        }
    }

    struct Candidate: Sendable {
        let source: AudioSource
        let url: URL
        let track: MeetingSourceAlignment.Track
    }

    enum Method: String, Sendable {
        case mixed
        case singleSource = "single_source"
        case bestSourceFallback = "best_source_fallback"
    }

    struct Result: Sendable {
        let durationSeconds: TimeInterval
        let method: Method
        let source: AudioSource?
    }

    private struct ProbedCandidate: Sendable {
        let candidate: Candidate
        let durationSeconds: TimeInterval

        var playableEndSeconds: TimeInterval {
            max(0, Double(candidate.track.startOffsetMs) / 1_000) + durationSeconds
        }
    }

    private let audioConverter: any AudioFileConverting
    private let fileManager: FileManager

    init(
        audioConverter: any AudioFileConverting,
        fileManager: SendableFileManager = SendableFileManager()
    ) {
        self.audioConverter = audioConverter
        self.fileManager = fileManager.value
    }

    func build(
        candidates: [Candidate],
        outputURL: URL,
        sourceAlignment: MeetingSourceAlignment
    ) async throws -> Result {
        var playableCandidates: [ProbedCandidate] = []
        playableCandidates.reserveCapacity(candidates.count)
        for candidate in candidates {
            guard let duration = try? await probeDuration(at: candidate.url) else { continue }
            playableCandidates.append(
                ProbedCandidate(candidate: candidate, durationSeconds: duration)
            )
        }
        guard !playableCandidates.isEmpty else {
            throw MeetingAudioError.mixFailed("No decodable meeting source remained.")
        }

        if playableCandidates.count == 1 {
            let only = playableCandidates[0]
            let duration = try await materialize(only, at: outputURL)
            return Result(
                durationSeconds: duration,
                method: .singleSource,
                source: only.candidate.source
            )
        }

        let mixURL = temporaryURL(nextTo: outputURL, label: "mix")
        defer { try? fileManager.removeItem(at: mixURL) }
        do {
            try await audioConverter.mixToM4A(
                inputURLs: playableCandidates.map(\.candidate.url),
                outputURL: mixURL,
                sourceAlignment: sourceAlignment
            )
            let mixedDuration = try await probeDuration(at: mixURL)
            let expectedDuration = playableCandidates.map(\.playableEndSeconds).max() ?? 0
            guard mixedDuration + 0.1 >= expectedDuration else {
                throw MeetingAudioError.mixFailed(
                    "Mixed playback ended before the longest source timeline."
                )
            }
            try installArtifact(from: mixURL, at: outputURL)
            return Result(durationSeconds: mixedDuration, method: .mixed, source: nil)
        } catch {
            let fallback = bestFallback(from: playableCandidates)
            do {
                let duration = try await materialize(fallback, at: outputURL)
                return Result(
                    durationSeconds: duration,
                    method: .bestSourceFallback,
                    source: fallback.candidate.source
                )
            } catch let fallbackError {
                throw MeetingAudioError.mixFailed(
                    "Mix failed (\(error.localizedDescription)); playback fallback failed "
                        + "(\(fallbackError.localizedDescription))."
                )
            }
        }
    }

    private func bestFallback(from candidates: [ProbedCandidate]) -> ProbedCandidate {
        candidates.enumerated().max { lhs, rhs in
            if lhs.element.playableEndSeconds != rhs.element.playableEndSeconds {
                return lhs.element.playableEndSeconds < rhs.element.playableEndSeconds
            }
            // Preserve the caller's deterministic source ordering on ties.
            return lhs.offset > rhs.offset
        }!.element
    }

    private func materialize(
        _ candidate: ProbedCandidate,
        at outputURL: URL
    ) async throws -> TimeInterval {
        let offsetSeconds = max(0, Double(candidate.candidate.track.startOffsetMs) / 1_000)
        let temporaryURL = temporaryURL(nextTo: outputURL, label: "fallback")
        defer { try? fileManager.removeItem(at: temporaryURL) }

        if offsetSeconds == 0 {
            try fileManager.copyItem(at: candidate.candidate.url, to: temporaryURL)
        } else {
            try await renderWithLeadingSilence(
                sourceURL: candidate.candidate.url,
                leadingSilenceSeconds: offsetSeconds,
                outputURL: temporaryURL
            )
        }

        let duration = try await probeDuration(at: temporaryURL)
        guard duration + 0.1 >= candidate.playableEndSeconds else {
            throw MeetingAudioError.mixFailed(
                "Playback fallback did not preserve the source start offset."
            )
        }
        try installArtifact(from: temporaryURL, at: outputURL)
        return duration
    }

    private func renderWithLeadingSilence(
        sourceURL: URL,
        leadingSilenceSeconds: TimeInterval,
        outputURL: URL
    ) async throws {
        let renderTask = Task.detached(priority: .utility) {
            try Self.renderAlignedSource(
                sourceURL: sourceURL,
                leadingSilenceSeconds: leadingSilenceSeconds,
                outputURL: outputURL
            )
        }
        try await withTaskCancellationHandler {
            try await renderTask.value
        } onCancel: {
            renderTask.cancel()
        }
    }

    /// Render one continuous AAC stream instead of relying on composition edit
    /// ranges. macOS 14 can trim even a real silent segment when it is joined
    /// to an AAC asset, while PCM written into the same encoder stream remains
    /// durable. The transcode is a rare mix-failure fallback and stays bounded
    /// to one reusable PCM buffer.
    private nonisolated static func renderAlignedSource(
        sourceURL: URL,
        leadingSilenceSeconds: TimeInterval,
        outputURL: URL
    ) throws {
        let sourceFile = try AVAudioFile(
            forReading: sourceURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = sourceFile.processingFormat
        let sampleRate = format.sampleRate
        let channelCount = format.channelCount
        let requestedFrames = leadingSilenceSeconds * sampleRate
        guard leadingSilenceSeconds.isFinite,
            leadingSilenceSeconds > 0,
            sampleRate.isFinite,
            sampleRate > 0,
            channelCount > 0,
            requestedFrames.isFinite,
            requestedFrames < Double(Int64.max),
            sourceFile.length > 0
        else {
            throw MeetingAudioError.mixFailed("Playback fallback source format is invalid.")
        }

        let silenceFrameCount = max(1, Int64(requestedFrames.rounded(.up)))
        let bufferCapacity: AVAudioFrameCount = 32_768
        guard
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: bufferCapacity
            )
        else {
            throw MeetingAudioError.mixFailed("Unable to allocate playback fallback buffer.")
        }

        do {
            let outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channelCount,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            var remainingSilenceFrames = silenceFrameCount
            while remainingSilenceFrames > 0 {
                try Task.checkCancellation()
                buffer.frameLength = AVAudioFrameCount(
                    min(remainingSilenceFrames, Int64(bufferCapacity))
                )
                for audioBuffer in UnsafeMutableAudioBufferListPointer(
                    buffer.mutableAudioBufferList
                ) {
                    if let data = audioBuffer.mData {
                        memset(data, 0, Int(audioBuffer.mDataByteSize))
                    }
                }
                try outputFile.write(from: buffer)
                remainingSilenceFrames -= Int64(buffer.frameLength)
            }

            while sourceFile.framePosition < sourceFile.length {
                try Task.checkCancellation()
                let remainingSourceFrames = sourceFile.length - sourceFile.framePosition
                try sourceFile.read(
                    into: buffer,
                    frameCount: AVAudioFrameCount(
                        min(remainingSourceFrames, AVAudioFramePosition(bufferCapacity))
                    )
                )
                guard buffer.frameLength > 0 else { break }
                try outputFile.write(from: buffer)
            }
        }
    }

    private func probeDuration(at url: URL) async throws -> TimeInterval {
        guard fileManager.fileExists(atPath: url.path),
            let size = try fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber,
            size.int64Value > 0
        else {
            throw MeetingAudioError.mixFailed("Playback artifact is missing or empty.")
        }
        let audioFile = try AVAudioFile(forReading: url)
        guard audioFile.length > 0 else {
            throw MeetingAudioError.mixFailed("Playback artifact has no decodable frames.")
        }

        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw MeetingAudioError.mixFailed("Playback artifact has no audio track.")
        }
        let assetDuration = try await asset.load(.duration)
        let duration = assetDuration.seconds
        guard duration.isFinite, duration > 0 else {
            throw MeetingAudioError.mixFailed("Playback artifact has no finite duration.")
        }
        return duration
    }

    private func temporaryURL(nextTo outputURL: URL, label: String) -> URL {
        outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(outputURL.deletingPathExtension().lastPathComponent)-\(label)-\(UUID().uuidString).m4a"
        )
    }

    private func installArtifact(from temporaryURL: URL, at outputURL: URL) throws {
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: outputURL)
        }
    }
}
