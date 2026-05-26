import XCTest
@testable import MacParakeetCore

final class VibeVoiceChunkPlanningParseSilenceTests: XCTestCase {

    func testParsesSingleSilenceInterval() {
        let stderr = """
        [silencedetect @ 0x7f8b3c4054c0] silence_start: 4.5
        [silencedetect @ 0x7f8b3c4054c0] silence_end: 5.2 | silence_duration: 0.7
        """
        let result = VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].lowerBound, 4.5, accuracy: 0.001)
        XCTAssertEqual(result[0].upperBound, 5.2, accuracy: 0.001)
    }

    func testParsesMultipleIntervals() {
        let stderr = """
        [silencedetect @ 0x1] silence_start: 10.0
        [silencedetect @ 0x1] silence_end: 11.0 | silence_duration: 1.0
        [silencedetect @ 0x1] silence_start: 25.5
        [silencedetect @ 0x1] silence_end: 27.0 | silence_duration: 1.5
        """
        let result = VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].lowerBound, 10.0, accuracy: 0.001)
        XCTAssertEqual(result[0].upperBound, 11.0, accuracy: 0.001)
        XCTAssertEqual(result[1].lowerBound, 25.5, accuracy: 0.001)
        XCTAssertEqual(result[1].upperBound, 27.0, accuracy: 0.001)
    }

    func testReturnsEmptyForNoMatches() {
        let stderr = "[ffmpeg @ 0x1] some other line\n[ffmpeg @ 0x1] another line\n"
        let result = VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
        XCTAssertTrue(result.isEmpty)
    }

    /// FFmpeg sometimes emits a trailing silence_start without a matching
    /// silence_end (audio ended during silence). The parser must skip
    /// orphan starts rather than synthesize a phantom interval.
    func testIgnoresOrphanSilenceStart() {
        let stderr = """
        [silencedetect @ 0x1] silence_start: 10.0
        [silencedetect @ 0x1] silence_end: 11.0 | silence_duration: 1.0
        [silencedetect @ 0x1] silence_start: 58.0
        """
        let result = VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].lowerBound, 10.0, accuracy: 0.001)
    }

    func testIgnoresMalformedLines() {
        let stderr = """
        [silencedetect @ 0x1] silence_start: not_a_number
        [silencedetect @ 0x1] silence_end: 11.0 | silence_duration: 1.0
        """
        let result = VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
        XCTAssertTrue(result.isEmpty)
    }

    /// Two consecutive `silence_start:` lines (no end between them) means
    /// FFmpeg's state desynced. The parser keeps the most recent start and
    /// pairs it with the next end. This locks the behavior so a future
    /// refactor can't silently change it.
    func testConsecutiveStartsKeepsLatest() {
        let stderr = """
        [silencedetect @ 0x1] silence_start: 5.0
        [silencedetect @ 0x1] silence_start: 10.0
        [silencedetect @ 0x1] silence_end: 12.0 | silence_duration: 2.0
        """
        let result = VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].lowerBound, 10.0, accuracy: 0.001)
        XCTAssertEqual(result[0].upperBound, 12.0, accuracy: 0.001)
    }

    /// Orphan `silence_end:` with no preceding start is silently skipped.
    func testIgnoresOrphanSilenceEnd() {
        let stderr = """
        [silencedetect @ 0x1] silence_end: 5.0 | silence_duration: 1.0
        [silencedetect @ 0x1] silence_start: 10.0
        [silencedetect @ 0x1] silence_end: 12.0 | silence_duration: 2.0
        """
        let result = VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].lowerBound, 10.0, accuracy: 0.001)
        XCTAssertEqual(result[0].upperBound, 12.0, accuracy: 0.001)
    }

    /// Hardening: CRLF line endings (rare on macOS but possible if FFmpeg
    /// stderr is piped through certain tools) must still parse correctly.
    func testParsesCRLFLineEndings() {
        let stderr = "[silencedetect @ 0x1] silence_start: 4.5\r\n[silencedetect @ 0x1] silence_end: 5.2 | silence_duration: 0.7\r\n"
        let result = VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].lowerBound, 4.5, accuracy: 0.001)
        XCTAssertEqual(result[0].upperBound, 5.2, accuracy: 0.001)
    }
}

final class VibeVoiceChunkPlanningComputeChunkPlanTests: XCTestCase {

    /// 30-min audio splits into 6 chunks at 5/10/15/20/25 min boundaries.
    func testEvenDivision() {
        let result = VibeVoiceChunkPlanning.computeChunkPlan(
            audioSec: 1800, chunkLengthSec: 300, minTailSec: 30
        )
        XCTAssertEqual(result, [300, 600, 900, 1200, 1500])
    }

    /// 18-min audio: 3 full chunks (15 min) + 3-min tail kept as own chunk.
    func testTailLargerThanMinTailKept() {
        let result = VibeVoiceChunkPlanning.computeChunkPlan(
            audioSec: 1080, chunkLengthSec: 300, minTailSec: 30
        )
        XCTAssertEqual(result, [300, 600, 900])  // 3 chunks: 0-300, 300-600, 600-900, 900-1080
    }

    /// 15:20 audio: 3 full chunks + 20-s tail < 30 s min → tail merged
    /// into prior chunk (drop last target boundary).
    func testTailSmallerThanMinTailMerged() {
        let result = VibeVoiceChunkPlanning.computeChunkPlan(
            audioSec: 920, chunkLengthSec: 300, minTailSec: 30
        )
        XCTAssertEqual(result, [300, 600])  // 3 chunks: 0-300, 300-600, 600-920
    }

    /// 7.5-min audio: 1 chunk + 2.5-min tail → 2 chunks at 300 s boundary.
    func testAudioJustOverThreshold() {
        let result = VibeVoiceChunkPlanning.computeChunkPlan(
            audioSec: 450, chunkLengthSec: 300, minTailSec: 30
        )
        XCTAssertEqual(result, [300])
    }

    /// Audio shorter than chunk length: empty (caller branches to single-shot).
    func testAudioShorterThanChunkLength() {
        let result = VibeVoiceChunkPlanning.computeChunkPlan(
            audioSec: 200, chunkLengthSec: 300, minTailSec: 30
        )
        XCTAssertEqual(result, [])
    }
}

final class VibeVoiceChunkPlanningRefineBoundariesTests: XCTestCase {

    /// No silences anywhere → boundaries stay at their targets (uniform fallback).
    func testNoSilencesReturnsOriginalTargets() {
        let targets = [300.0, 600.0, 900.0]
        let result = VibeVoiceChunkPlanning.refineBoundaries(
            targets: targets, silences: [], windowSec: 15
        )
        XCTAssertEqual(result, targets)
    }

    /// One silence inside the window → boundary snaps to midpoint.
    func testSnapsToSilenceMidpointWhenInsideWindow() {
        let targets = [300.0]
        let silences: [ClosedRange<Double>] = [298.0...302.0]  // midpoint 300
        let result = VibeVoiceChunkPlanning.refineBoundaries(
            targets: targets, silences: silences, windowSec: 15
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], 300.0, accuracy: 0.001)
    }

    /// Silence outside the ±15 s window → ignored, target stays.
    func testIgnoresSilenceOutsideWindow() {
        let targets = [300.0]
        let silences: [ClosedRange<Double>] = [270.0...272.0]  // 30 s before target, outside
        let result = VibeVoiceChunkPlanning.refineBoundaries(
            targets: targets, silences: silences, windowSec: 15
        )
        XCTAssertEqual(result[0], 300.0, accuracy: 0.001)
    }

    /// Multiple silences in window → pick the longest.
    func testPicksLongestSilenceInWindow() {
        let targets = [300.0]
        let silences: [ClosedRange<Double>] = [
            295.0...296.0,      // short, midpoint 295.5
            305.0...310.0,      // long (5 s), midpoint 307.5
        ]
        let result = VibeVoiceChunkPlanning.refineBoundaries(
            targets: targets, silences: silences, windowSec: 15
        )
        XCTAssertEqual(result[0], 307.5, accuracy: 0.001)
    }

    /// Silence partially overlapping window → still selected, but midpoint
    /// is mid of the silence itself, not mid of overlap.
    func testPartialOverlapStillSelectsSilence() {
        let targets = [300.0]
        // Silence 290..320 (30 s long). Window 285..315. Overlap is 290..315.
        // Midpoint of silence (the boundary value we snap to) is 305.
        let silences: [ClosedRange<Double>] = [290.0...320.0]
        let result = VibeVoiceChunkPlanning.refineBoundaries(
            targets: targets, silences: silences, windowSec: 15
        )
        XCTAssertEqual(result[0], 305.0, accuracy: 0.001)
    }

    func testMultipleTargetsProcessedIndependently() {
        let targets = [300.0, 600.0]
        let silences: [ClosedRange<Double>] = [
            298.0...302.0,      // matches target 300
            610.0...612.0,      // matches target 600 (within window)
        ]
        let result = VibeVoiceChunkPlanning.refineBoundaries(
            targets: targets, silences: silences, windowSec: 15
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], 300.0, accuracy: 0.001)
        XCTAssertEqual(result[1], 611.0, accuracy: 0.001)
    }
}

final class VibeVoiceChunkPlanningMergeSegmentsTests: XCTestCase {

    func testOffsetsTimestampsByChunkStartSec() {
        let chunkOffsets: [Double] = [0, 300]
        let chunk0: [STTSegment] = [
            STTSegment(startMs: 0, endMs: 5000, text: "hello", speakerId: 0)
        ]
        let chunk1: [STTSegment] = [
            STTSegment(startMs: 0, endMs: 4000, text: "world", speakerId: 0)
        ]
        let merged = VibeVoiceChunkPlanning.mergeSegments(
            chunkOffsetsSec: chunkOffsets,
            perChunkSegments: [chunk0, chunk1]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].startMs, 0)
        XCTAssertEqual(merged[0].endMs, 5000)
        XCTAssertEqual(merged[0].text, "hello")
        XCTAssertEqual(merged[1].startMs, 300_000)
        XCTAssertEqual(merged[1].endMs, 304_000)
        XCTAssertEqual(merged[1].text, "world")
    }

    func testEmptyChunkContributesNothing() {
        let chunkOffsets: [Double] = [0, 300, 600]
        let chunk0: [STTSegment] = [STTSegment(startMs: 0, endMs: 1000, text: "a", speakerId: 0)]
        let chunk1: [STTSegment] = []  // empty
        let chunk2: [STTSegment] = [STTSegment(startMs: 0, endMs: 1000, text: "c", speakerId: 0)]
        let merged = VibeVoiceChunkPlanning.mergeSegments(
            chunkOffsetsSec: chunkOffsets,
            perChunkSegments: [chunk0, chunk1, chunk2]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].text, "a")
        XCTAssertEqual(merged[1].text, "c")
        XCTAssertEqual(merged[1].startMs, 600_000)
    }

    func testSpeakerIdsPassThroughUnchanged() {
        let chunkOffsets: [Double] = [0, 300]
        let chunk0: [STTSegment] = [
            STTSegment(startMs: 0, endMs: 1000, text: "a", speakerId: nil),
            STTSegment(startMs: 1000, endMs: 2000, text: "b", speakerId: 1)
        ]
        let chunk1: [STTSegment] = [
            STTSegment(startMs: 0, endMs: 1000, text: "c", speakerId: 0)
        ]
        let merged = VibeVoiceChunkPlanning.mergeSegments(
            chunkOffsetsSec: chunkOffsets,
            perChunkSegments: [chunk0, chunk1]
        )
        XCTAssertEqual(merged.count, 3)
        XCTAssertNil(merged[0].speakerId)
        XCTAssertEqual(merged[1].speakerId, 1)
        XCTAssertEqual(merged[2].speakerId, 0)
    }

    func testFractionalOffsetMillisecondRounding() {
        // 305.5 s offset → 305_500 ms. Confirm we don't lose subsecond precision.
        let chunkOffsets: [Double] = [305.5]
        let chunk0: [STTSegment] = [STTSegment(startMs: 100, endMs: 200, text: "x", speakerId: 0)]
        let merged = VibeVoiceChunkPlanning.mergeSegments(
            chunkOffsetsSec: chunkOffsets,
            perChunkSegments: [chunk0]
        )
        XCTAssertEqual(merged[0].startMs, 305_600)
        XCTAssertEqual(merged[0].endMs, 305_700)
    }
}
