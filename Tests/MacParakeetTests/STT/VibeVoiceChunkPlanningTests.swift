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
