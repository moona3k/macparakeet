import Foundation
import OSLog

/// Who-spoke-when from Nemotron (Sortformer), who-is-who from Community-1.
///
/// Voice profiles need Community-1's identity embeddings, so with them on the
/// app used Community-1 for everything and gave up Nemotron's turn timing,
/// which is built for fast handovers and overlapping speech. This service runs
/// both and keeps each where it is strong: the timing model's segments, with
/// each timing speaker carrying the embedding of the Community-1 cluster that
/// covers the same speech.
///
/// Fusion is conservative. When the timing model merges two distinct voices
/// into one speaker — or runs out of speaker channels — the Community-1 result
/// is returned unchanged, which is exactly the previous behavior. A timing
/// speaker without a clear Community-1 counterpart keeps its segments but no
/// embedding, so it is never matched to a saved voice on a guess.
public actor HybridDiarizationService: DiarizationServiceProtocol {
    private let timing: any DiarizationServiceProtocol
    private let identity: any DiarizationServiceProtocol
    private let policy: DiarizationFusion.Policy
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "HybridDiarization")

    public init(
        timing: any DiarizationServiceProtocol = NemotronDiarizationService(),
        identity: any DiarizationServiceProtocol = DiarizationService(),
        policy: DiarizationFusion.Policy = .v1
    ) {
        self.timing = timing
        self.identity = identity
        self.policy = policy
    }

    public func diarize(
        audioURL: URL,
        speakerConstraint: SpeakerDiarizationConstraint?
    ) async throws -> MacParakeetDiarizationResult {
        // Sequential on purpose: both models share the Neural Engine.
        let timingResult: MacParakeetDiarizationResult?
        do {
            timingResult = try await timing.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            logger.warning("hybrid_timing_failed falling_back=identity")
            timingResult = nil
        }
        try Task.checkCancellation()

        // A timing result that already carries embeddings came from the timing
        // service's own Community-1 fallback (a calendar speaker bound it could
        // not meet). It is already the identity answer.
        if let timingResult, !timingResult.speakerEmbeddings.isEmpty {
            return timingResult
        }

        let identityResult: MacParakeetDiarizationResult
        do {
            identityResult = try await identity.diarize(audioURL: audioURL, speakerConstraint: speakerConstraint)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // Without identity the timing still makes a better transcript than
            // nothing; it just cannot be matched to saved voices.
            guard let timingResult else { throw error }
            logger.warning("hybrid_identity_failed returning=timing_without_embeddings")
            return timingResult
        }
        try Task.checkCancellation()

        guard let timingResult else { return identityResult }
        switch DiarizationFusion.fuse(timing: timingResult, identity: identityResult, policy: policy) {
        case .fused(let fused, let assigned):
            logger.info(
                "hybrid_fused timing_speakers=\(timingResult.speakers.count, privacy: .public) identity_speakers=\(identityResult.speakers.count, privacy: .public) embeddings=\(assigned, privacy: .public)"
            )
            return fused
        case .identityOnly(let reason):
            logger.info("hybrid_identity_only reason=\(reason.rawValue, privacy: .public)")
            return identityResult
        }
    }

    public func prepareModels(onProgress: (@Sendable (String) -> Void)? = nil) async throws {
        try await timing.prepareModels(onProgress: onProgress)
        try await identity.prepareModels(onProgress: onProgress)
    }

    public func isReady() async -> Bool {
        guard await timing.isReady() else { return false }
        return await identity.isReady()
    }

    public func hasCachedModels() async -> Bool {
        guard await timing.hasCachedModels() else { return false }
        return await identity.hasCachedModels()
    }
}

/// Pure fusion of a timing diarization with an identity diarization.
public enum DiarizationFusion {
    public struct Policy: Sendable {
        /// Share of a timing speaker's speech that its Community-1 voice must
        /// cover before the speaker inherits that voice's embedding.
        public var minimumPurity: Double
        /// A second, distinct voice this large inside one timing speaker means
        /// the timing model merged two people.
        public var conflictShare: Double
        public var conflictSeconds: Double
        /// Community-1 clusters this close are one person split in two.
        public var sameVoiceDistance: Double
        /// Shortest stretch of identity-only speech worth filling a timing gap.
        public var minimumGapFillMs: Int

        public static let v1 = Policy(
            minimumPurity: 0.6,
            conflictShare: 0.2,
            conflictSeconds: SpeakerMatchPolicy.v1.minSpeechSecondsToEnroll,
            sameVoiceDistance: SpeakerMatchPolicy.v1.tau,
            minimumGapFillMs: 200
        )
    }

    public enum FallbackReason: String, Sendable {
        case noTimingSpeech
        case timingMergedDistinctVoices
    }

    public enum Outcome: Sendable {
        /// Timing segments with mapped embeddings; `assigned` counts them.
        case fused(MacParakeetDiarizationResult, assigned: Int)
        case identityOnly(FallbackReason)
    }

    public static func fuse(
        timing: MacParakeetDiarizationResult,
        identity: MacParakeetDiarizationResult,
        policy: Policy = .v1
    ) -> Outcome {
        let timingIDs = timing.speakers.map(\.id)
        guard !timing.segments.isEmpty, !timingIDs.isEmpty else { return .identityOnly(.noTimingSpeech) }
        let identityIDs = identity.speakers.map(\.id)
        let timingIntervals = intervals(timing.segments)
        let identityIntervals = intervals(identity.segments)

        func distance(_ a: String, _ b: String) -> Double? {
            guard let x = identity.speakerEmbeddings[a], let y = identity.speakerEmbeddings[b] else { return nil }
            return x.cosineDistance(to: y)
        }
        func sameVoice(_ a: String, _ b: String) -> Bool {
            a == b || (distance(a, b).map { $0 <= policy.sameVoiceDistance } ?? false)
        }

        struct Claim { let voice: String; let overlapMs: Int }
        var claims: [String: Claim] = [:]
        for t in timingIDs {
            let speechMs = timing.speechMsBySpeaker[t] ?? total(timingIntervals[t] ?? [])
            guard speechMs > 0 else { continue }
            let overlaps = identityIDs
                .map { ($0, overlap(timingIntervals[t] ?? [], identityIntervals[$0] ?? [])) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            guard let (dominant, dominantMs) = overlaps.first else { continue }

            // Merged people: a large share of this speaker is a different voice.
            for (other, ms) in overlaps.dropFirst() where !sameVoice(dominant, other) {
                if Double(ms) / 1000 >= policy.conflictSeconds,
                    Double(ms) / Double(speechMs) >= policy.conflictShare
                {
                    return .identityOnly(.timingMergedDistinctVoices)
                }
            }

            let sameVoiceMs = overlaps.filter { sameVoice(dominant, $0.0) }.reduce(0) { $0 + $1.1 }
            guard identity.speakerEmbeddings[dominant] != nil,
                Double(sameVoiceMs) / Double(speechMs) >= policy.minimumPurity
            else { continue }
            claims[t] = Claim(voice: dominant, overlapMs: dominantMs)
        }

        // One voice, one speaker: where the timing model split a person the
        // identity model kept whole, only the larger part carries the voice, so
        // two speakers are never offered the same saved name.
        var embeddings: [String: SpeakerEmbedding] = [:]
        for (t, claim) in claims {
            let rival = claims.contains { other in
                other.key != t && other.value.voice == claim.voice
                    && (other.value.overlapMs, other.key) > (claim.overlapMs, t)
            }
            if !rival, let embedding = identity.speakerEmbeddings[claim.voice] {
                embeddings[t] = embedding
            }
        }

        // Speech the timing model missed but the identity model heard keeps
        // its speaker, so a dropped stretch is not handed to whoever the
        // transcript defaults to. Only voices with a one-to-one timing speaker
        // fill gaps; anything ambiguous stays a gap, as before.
        var timingForVoice: [String: String] = [:]
        for (t, claim) in claims where embeddings[t] != nil {
            for voice in identityIDs where sameVoice(claim.voice, voice) {
                timingForVoice[voice] = timingForVoice[voice] == nil ? t : ""
            }
        }
        let covered = intervals(timing.segments.map { SpeakerSegment(speakerId: "", startMs: $0.startMs, endMs: $0.endMs) })[""] ?? []
        var segments = timing.segments
        var speechMs = timing.speechMsBySpeaker
        for (voice, t) in timingForVoice where !t.isEmpty {
            for gap in subtract(identityIntervals[voice] ?? [], covered) where gap.1 - gap.0 >= policy.minimumGapFillMs {
                segments.append(SpeakerSegment(speakerId: t, startMs: gap.0, endMs: gap.1))
                speechMs[t, default: 0] += gap.1 - gap.0
            }
        }
        segments.sort { ($0.startMs, $0.endMs) < ($1.startMs, $1.endMs) }

        let fused = MacParakeetDiarizationResult(
            segments: segments,
            speakerCount: timing.speakerCount,
            speakers: timing.speakers,
            speakerEmbeddings: embeddings,
            speechMsBySpeaker: speechMs
        )
        return .fused(fused, assigned: embeddings.count)
    }

    /// Parts of `a` not covered by `b`; both merged and sorted.
    static func subtract(_ a: [(Int, Int)], _ b: [(Int, Int)]) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        var j = 0
        for (start, end) in a {
            var cursor = start
            while j < b.count, b[j].1 <= cursor { j += 1 }
            var k = j
            while k < b.count, b[k].0 < end {
                if b[k].0 > cursor { result.append((cursor, b[k].0)) }
                cursor = max(cursor, b[k].1)
                k += 1
            }
            if cursor < end { result.append((cursor, end)) }
        }
        return result
    }

    /// Merged, sorted [start, end) intervals per speaker.
    static func intervals(_ segments: [SpeakerSegment]) -> [String: [(Int, Int)]] {
        var bySpeaker: [String: [(Int, Int)]] = [:]
        for segment in segments where segment.endMs > segment.startMs {
            bySpeaker[segment.speakerId, default: []].append((segment.startMs, segment.endMs))
        }
        return bySpeaker.mapValues { list in
            var merged: [(Int, Int)] = []
            for interval in list.sorted(by: { $0.0 < $1.0 }) {
                if let last = merged.last, interval.0 <= last.1 {
                    merged[merged.count - 1].1 = max(last.1, interval.1)
                } else {
                    merged.append(interval)
                }
            }
            return merged
        }
    }

    static func overlap(_ a: [(Int, Int)], _ b: [(Int, Int)]) -> Int {
        var i = 0, j = 0, sum = 0
        while i < a.count, j < b.count {
            let start = max(a[i].0, b[j].0), end = min(a[i].1, b[j].1)
            if end > start { sum += end - start }
            if a[i].1 < b[j].1 { i += 1 } else { j += 1 }
        }
        return sum
    }

    static func total(_ intervals: [(Int, Int)]) -> Int {
        intervals.reduce(0) { $0 + $1.1 - $1.0 }
    }
}
