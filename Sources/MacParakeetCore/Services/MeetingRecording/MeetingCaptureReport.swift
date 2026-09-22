import Foundation

/// Durable, content-free truth about the quality of a meeting capture.
///
/// Live source health is intentionally ephemeral: silence, mute state, and
/// recent levels can change from second to second. This report is computed
/// once after capture stops and records only finalized coverage, terminal
/// failures, and diagnostic whole-track silence. Silence alone is valid capture.
public struct MeetingCaptureReport: Codable, Sendable, Equatable {
    public enum Quality: String, Codable, Sendable, Equatable {
        case healthy
        case partial
    }

    public struct Policy: Sendable, Equatable {
        public static let production = Policy(minimumCoverageRatio: 0.9)

        public let minimumCoverageRatio: Double

        public init(minimumCoverageRatio: Double) {
            self.minimumCoverageRatio = min(1, max(0, minimumCoverageRatio))
        }

        fileprivate func hasCoverageShortfall(
            writtenDurationMs: Int,
            elapsedDurationMs: Int
        ) -> Bool {
            guard elapsedDurationMs > 0 else { return false }
            let clampedWrittenDurationMs = max(0, writtenDurationMs)
            let coverageRatio = min(
                1,
                Double(clampedWrittenDurationMs) / Double(elapsedDurationMs)
            )
            return coverageRatio < minimumCoverageRatio
        }
    }

    public struct SourceReport: Codable, Sendable, Equatable {
        public enum Status: String, Codable, Sendable, Equatable {
            case complete
            case coverageShortfall = "coverage_shortfall"
            case silent
            case interrupted
            case unavailable
            case captureFailed = "capture_failed"
        }

        public let source: AudioSource
        public let writtenDurationMs: Int
        public let coverageRatio: Double
        public let status: Status

        public init(
            source: AudioSource,
            writtenDurationMs: Int,
            coverageRatio: Double,
            status: Status
        ) {
            self.source = source
            self.writtenDurationMs = max(0, writtenDurationMs)
            self.coverageRatio = min(1, max(0, coverageRatio))
            self.status = status
        }
    }

    public let quality: Quality
    public let sourceMode: MeetingAudioSourceMode
    /// Pause-adjusted time during which capture was expected to be active.
    public let elapsedDurationMs: Int
    /// End of the longest selected source timeline, including its start offset.
    public let capturedDurationMs: Int
    public let sources: [SourceReport]
    /// Terminal interruption events observed before finalization, in stable
    /// microphone/system order.
    public let interruptedSources: [AudioSource]
    /// Runtime capture failure remains separate from final quality. A severe
    /// frame shortfall can be partial while this remains false.
    public let captureFailed: Bool
    /// Source used alone for canonical playback when two decodable selected
    /// tracks could not be combined. The raw-source capture statuses remain
    /// independent; this durable playback degradation makes quality partial.
    public let playbackFallbackSource: AudioSource?

    public init(
        sourceMode: MeetingAudioSourceMode,
        sourceAlignment: MeetingSourceAlignment,
        elapsedDurationMs: Int,
        interruptedSources: Set<AudioSource> = [],
        silentSources: Set<AudioSource> = [],
        captureFailed: Bool = false,
        playbackFallbackSource: AudioSource? = nil,
        policy: Policy = .production
    ) {
        let clampedElapsedDurationMs = max(0, elapsedDurationMs)
        let selectedSources = Self.selectedSources(for: sourceMode)
        let selectedInterruptedSources = selectedSources.filter(interruptedSources.contains)
        let selectedPlaybackFallbackSource = playbackFallbackSource.flatMap { source in
            selectedSources.count > 1 && selectedSources.contains(source) ? source : nil
        }

        let sourceReports = selectedSources.map { source -> SourceReport in
            let track = sourceAlignment.track(for: source)
            let writtenDurationMs = Self.writtenDurationMs(for: track)
            let coverageRatio: Double =
                clampedElapsedDurationMs > 0
                ? min(1, Double(writtenDurationMs) / Double(clampedElapsedDurationMs))
                : 1

            let status: SourceReport.Status
            if interruptedSources.contains(source) {
                status = .interrupted
            } else if captureFailed {
                status = .captureFailed
            } else if track == nil {
                status = .unavailable
            } else if policy.hasCoverageShortfall(
                writtenDurationMs: writtenDurationMs,
                elapsedDurationMs: clampedElapsedDurationMs
            ) {
                status = .coverageShortfall
            } else if silentSources.contains(source) {
                status = .silent
            } else {
                status = .complete
            }

            return SourceReport(
                source: source,
                writtenDurationMs: writtenDurationMs,
                coverageRatio: coverageRatio,
                status: status
            )
        }

        let capturedDurationMs =
            selectedSources.compactMap { source -> Int? in
                guard let track = sourceAlignment.track(for: source) else { return nil }
                return max(0, track.startOffsetMs) + Self.timelineDurationMs(for: track)
            }.max() ?? 0

        self.quality =
            sourceReports.allSatisfy { $0.status == .complete || $0.status == .silent }
                && !captureFailed
                && selectedPlaybackFallbackSource == nil
            ? .healthy
            : .partial
        self.sourceMode = sourceMode
        self.elapsedDurationMs = clampedElapsedDurationMs
        self.capturedDurationMs = capturedDurationMs
        self.sources = sourceReports
        self.interruptedSources = selectedInterruptedSources
        self.captureFailed = captureFailed
        self.playbackFallbackSource = selectedPlaybackFallbackSource
    }

    private enum CodingKeys: String, CodingKey {
        case quality
        case sourceMode
        case elapsedDurationMs
        case capturedDurationMs
        case sources
        case interruptedSources
        case captureFailed
        case playbackFallbackSource
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedQuality = try container.decode(Quality.self, forKey: .quality)
        sourceMode = try container.decode(MeetingAudioSourceMode.self, forKey: .sourceMode)
        let elapsedDurationMs = try container.decode(Int.self, forKey: .elapsedDurationMs)
        self.elapsedDurationMs = elapsedDurationMs
        capturedDurationMs = try container.decode(Int.self, forKey: .capturedDurationMs)
        sources = try container.decode([SourceReport].self, forKey: .sources)
        interruptedSources = try container.decode([AudioSource].self, forKey: .interruptedSources)
        captureFailed = try container.decode(Bool.self, forKey: .captureFailed)
        playbackFallbackSource = try container.decodeIfPresent(AudioSource.self, forKey: .playbackFallbackSource)

        // Older reports marked complete silent tracks partial, and silence
        // could mask a coverage shortfall. Promote only that known legacy case;
        // retain every other stored verdict and the original source diagnostics.
        let selectedSources = Self.selectedSources(for: sourceMode)
        let isSilenceOnlyPartial =
            storedQuality == .partial
            && !captureFailed
            && interruptedSources.isEmpty
            && playbackFallbackSource == nil
            && sources.contains { $0.status == .silent }
            && sources.count == selectedSources.count
            && zip(sources, selectedSources).allSatisfy { report, source in
                report.source == source
                    && (report.status == .complete || report.status == .silent)
                    && !Policy.production.hasCoverageShortfall(
                        writtenDurationMs: report.writtenDurationMs,
                        elapsedDurationMs: elapsedDurationMs
                    )
            }
        quality = isSilenceOnlyPartial ? .healthy : storedQuality
    }

    public func source(for source: AudioSource) -> SourceReport? {
        sources.first { $0.source == source }
    }

    private static func selectedSources(for sourceMode: MeetingAudioSourceMode) -> [AudioSource] {
        var sources: [AudioSource] = []
        if sourceMode.capturesMicrophone {
            sources.append(.microphone)
        }
        if sourceMode.capturesSystemAudio {
            sources.append(.system)
        }
        return sources
    }

    private static func writtenDurationMs(for track: MeetingSourceAlignment.Track?) -> Int {
        guard let track,
            track.sampleRate.isFinite,
            track.sampleRate > 0
        else {
            return 0
        }
        return max(
            0,
            Int((Double(max(0, track.writtenFrameCount)) / track.sampleRate * 1_000).rounded())
        )
    }

    private static func timelineDurationMs(for track: MeetingSourceAlignment.Track) -> Int {
        guard track.sampleRate.isFinite, track.sampleRate > 0 else { return 0 }
        let frameCount = track.timelineFrameCount ?? track.writtenFrameCount
        return max(
            0,
            Int((Double(max(0, frameCount)) / track.sampleRate * 1_000).rounded())
        )
    }
}
