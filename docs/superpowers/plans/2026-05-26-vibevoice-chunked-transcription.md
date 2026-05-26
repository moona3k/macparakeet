# VibeVoice Chunked Transcription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make VibeVoice viable for long-form audio by splitting inputs over 7.5 min into sequential 5-minute chunks, dropping a 30-minute video's wall time from 41 min single-shot to roughly 15-20 min, while leaving the existing short-form path unchanged.

**Architecture:** A new `VibeVoiceChunkedTranscriber` actor sits between `STTRuntime` and `VibeVoiceEngine`. `STTRuntime.transcribeWithVibeVoice` branches on measured audio duration: ≤ 450 s → existing single-shot path; > 450 s → chunker. The chunker silence-scans with FFmpeg, refines boundaries to snap to silence (±15 s window), splits via FFmpeg's segment muxer, loops the engine sequentially per chunk, and merges results with timestamp offsets. Pure functions (parsing / planning / merging / progress math) are extracted into a namespace enum for fast unit tests without FFmpeg or the model.

**Tech Stack:** Swift 6.0, SwiftPM, XCTest, OSLog. Reuses bundled FFmpeg via `BinaryBootstrap.requireRuntimeFFmpegPath()`. No new third-party dependencies.

**Branch:** `feat/vibevoice-engine-integration` (existing branch from prior phases — chunking is the next commit on top).

**Spec:** `docs/superpowers/specs/2026-05-26-vibevoice-chunked-transcription-design.md` (committed `11e88efc`).

**Key non-goals (per spec):**
- Cross-chunk speaker continuity. Speaker IDs reset per chunk.
- Partial-result return on chunk failure. Fail-all policy.
- Dynamic / adaptive chunk sizing. Hardcoded 300 s.
- User-configurable chunk length. No Settings toggle, no CLI flag.
- Word-level timing. `STTResult.words` stays `[]`.

---

## File Structure

**New files:**
- `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift` — namespace enum with 5 pure functions (parsing, planning, merging, progress math)
- `Sources/MacParakeetCore/STT/VibeVoiceChunkedTranscriber.swift` — the actor that orchestrates silence detection → split → loop → merge
- `Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift` — pure function tests
- `Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift` — orchestration tests with real FFmpeg + fake engine
- `Tests/MacParakeetTests/STT/Fixtures/synthetic_silence.wav` — 60 s WAV with known silences at 20-22 s and 40-42 s
- `Tests/MacParakeetTests/STT/Fixtures/README.md` — explains how to regenerate the fixture
- `scripts/dev/make_silence_fixture.sh` — deterministic fixture-generation script

**Modified files:**
- `Sources/MacParakeetCore/Audio/AudioFileConverter.swift` — add `public static func audioDuration(at:) throws -> TimeInterval`
- `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift` — call `AudioFileConverter.audioDuration(at:)` instead of private static; remove the private static helper
- `Sources/MacParakeetCore/STT/STTRuntime.swift` — branch in `transcribeWithVibeVoice` based on audio duration; add `vibevoiceChunkedTranscriber: VibeVoiceChunkedTranscriber?` member

**Unmodified (called out for clarity):**
- `Sources/VibeVoiceCore/VibeVoiceASR.swift` — the C ABI wrapper. Untouched.
- `Sources/MacParakeetCore/STT/STTScheduler.swift` — single-flight VibeVoice guard already wraps the whole call; chunker is invisible to it.
- `Sources/CLI/Commands/TranscribeCommand.swift` — CLI uses STTRuntime so chunking is transparent.

---

## Task 1: Promote `audioDuration(at:)` to `AudioFileConverter`

**Files:**
- Modify: `Sources/MacParakeetCore/Audio/AudioFileConverter.swift` — add helper
- Modify: `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift` — use shared helper, remove private static
- Test: `Tests/MacParakeetTests/Audio/AudioFileConverterTests.swift` (may or may not exist — task creates if missing)

- [ ] **Step 1: Write the failing test**

Append to (or create) `Tests/MacParakeetTests/Audio/AudioFileConverterTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

final class AudioFileConverterDurationTests: XCTestCase {

    /// Uses the existing tiny_ted.wav fixture from VibeVoiceCoreTests as a
    /// known-duration baseline (15 s at 24 kHz mono).
    func testAudioDurationReturnsExpectedSeconds() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Audio/
            .deletingLastPathComponent()  // MacParakeetTests/
            .deletingLastPathComponent()  // Tests/
            .appendingPathComponent("VibeVoiceCoreTests/Resources/tiny_ted.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "tiny_ted.wav fixture not present at \(url.path)")
        let seconds = try AudioFileConverter.audioDuration(at: url)
        XCTAssertEqual(seconds, 15.0, accuracy: 0.1)
    }

    func testAudioDurationThrowsForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).wav")
        XCTAssertThrowsError(try AudioFileConverter.audioDuration(at: url))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AudioFileConverterDurationTests`
Expected: compile error "type 'AudioFileConverter' has no member 'audioDuration'".

- [ ] **Step 3: Implement the helper**

Open `Sources/MacParakeetCore/Audio/AudioFileConverter.swift`. At the top, add `import AVFoundation` (it's likely already there — verify first). Inside the `AudioFileConverter` class, after the `supportedExtensions` static property block, add:

```swift
    /// Reads the duration in seconds of an audio file via `AVAudioFile`.
    /// Used by VibeVoice's chunker and progress estimator to size jobs.
    /// Throws if the file can't be opened (missing, unsupported codec).
    public static func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let frameCount = file.length
        let sampleRate = file.processingFormat.sampleRate
        return sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter AudioFileConverterDurationTests`
Expected: both tests pass.

- [ ] **Step 5: Remove the private duplicate in `VibeVoiceEngine`**

Open `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift`. Find the private static helper:

```swift
    private static func audioDuration(at url: URL) throws -> TimeInterval {
        let file = try AVAudioFile(forReading: url)
        let frameCount = file.length
        let sampleRate = file.processingFormat.sampleRate
        return sampleRate > 0 ? Double(frameCount) / sampleRate : 0
    }
```

Delete it.

Replace the two call sites `Self.audioDuration(at: ...)` with `AudioFileConverter.audioDuration(at: ...)`. There are two: one in the warm/convert timing block (computes `audioSec` for logging + progress estimator), one is the same expression.

Verify `import AVFoundation` can be removed if no longer used elsewhere in the file (it likely still is — leave it).

- [ ] **Step 6: Build and run full test suite**

Run: `swift build && swift test --filter "AudioFile\|VibeVoiceEngine\|MacParakeetTests"`
Expected: build succeeds, all tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/MacParakeetCore/Audio/AudioFileConverter.swift Sources/MacParakeetCore/STT/VibeVoiceEngine.swift Tests/MacParakeetTests/Audio/AudioFileConverterTests.swift
git commit -m "refactor(audio): promote audioDuration helper to AudioFileConverter

Removes the private static duplicate in VibeVoiceEngine. The upcoming
chunker needs the same helper; centralizing prevents drift.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 2: Pure function — `parseSilenceIntervals`

**Files:**
- Create: `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift`
- Create: `Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VibeVoiceChunkPlanningParseSilenceTests`
Expected: compile error "no such module 'VibeVoiceChunkPlanning'" or "cannot find 'VibeVoiceChunkPlanning' in scope".

- [ ] **Step 3: Create the namespace enum with parser**

Create `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift`:

```swift
import Foundation

/// Pure functions used by `VibeVoiceChunkedTranscriber`. No I/O, no FFmpeg,
/// no model dependencies — all are deterministic given their inputs so they
/// can be exhaustively unit-tested without fixtures or external processes.
internal enum VibeVoiceChunkPlanning {

    /// Parses FFmpeg's `silencedetect` filter stderr output into closed
    /// intervals of source-audio time (seconds).
    ///
    /// Expected line shapes:
    ///   `[silencedetect @ 0x...] silence_start: 4.5`
    ///   `[silencedetect @ 0x...] silence_end: 5.2 | silence_duration: 0.7`
    ///
    /// Orphan `silence_start` lines (no matching `silence_end`) are
    /// dropped — FFmpeg emits one if audio ends during silence. Malformed
    /// numeric values are also skipped.
    static func parseSilenceIntervals(_ stderr: String) -> [ClosedRange<Double>] {
        var pendingStart: Double? = nil
        var result: [ClosedRange<Double>] = []
        for line in stderr.split(separator: "\n") {
            if let startStr = line.split(separator: "silence_start:").last.map(String.init),
               line.contains("silence_start:") {
                let trimmed = startStr.trimmingCharacters(in: .whitespaces)
                if let value = Double(trimmed.split(separator: " ").first.map(String.init) ?? trimmed) {
                    pendingStart = value
                } else {
                    pendingStart = nil
                }
            } else if line.contains("silence_end:") {
                let afterTag = line.split(separator: "silence_end:").last.map(String.init) ?? ""
                let firstToken = afterTag.trimmingCharacters(in: .whitespaces)
                    .split(separator: " ").first.map(String.init) ?? ""
                if let endValue = Double(firstToken), let startValue = pendingStart, endValue >= startValue {
                    result.append(startValue...endValue)
                }
                pendingStart = nil
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VibeVoiceChunkPlanningParseSilenceTests`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift
git commit -m "feat(vibevoice): add parseSilenceIntervals pure function

First of five pure functions for the chunked transcription
orchestrator. Parses FFmpeg silencedetect stderr into closed
intervals, handles orphan starts and malformed lines.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 3: Pure function — `computeChunkPlan`

**Files:**
- Modify: `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift` — add function
- Modify: `Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift` — add tests

- [ ] **Step 1: Write the failing tests**

Append to `Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VibeVoiceChunkPlanningComputeChunkPlanTests`
Expected: compile error "no member 'computeChunkPlan'".

- [ ] **Step 3: Implement**

Add to `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift` inside the `enum`:

```swift
    /// Computes the intermediate chunk boundary times for an audio file.
    ///
    /// Returns a list of `Double` seconds where chunks split. The boundaries
    /// don't include 0 or `audioSec` — only the cuts between chunks. So for
    /// a 30-min file at 5-min chunks the return is `[300, 600, 900, 1200, 1500]`
    /// which produces 6 chunks.
    ///
    /// If the final chunk would be shorter than `minTailSec`, the last
    /// boundary is dropped so the tail is absorbed into the prior chunk.
    /// Avoids paying chunk-overhead for a tiny final chunk.
    static func computeChunkPlan(
        audioSec: Double,
        chunkLengthSec: Double,
        minTailSec: Double
    ) -> [Double] {
        guard audioSec > chunkLengthSec else { return [] }
        var boundaries: [Double] = []
        var t = chunkLengthSec
        while t < audioSec {
            boundaries.append(t)
            t += chunkLengthSec
        }
        // If the final chunk (from last boundary to audioSec) is too small,
        // drop the last boundary so the tail folds into the prior chunk.
        if let last = boundaries.last, audioSec - last < minTailSec {
            boundaries.removeLast()
        }
        return boundaries
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VibeVoiceChunkPlanningComputeChunkPlanTests`
Expected: all 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift
git commit -m "feat(vibevoice): add computeChunkPlan pure function

Computes intermediate chunk boundary times, with final-tail-merge
when the last chunk would be shorter than minTailSec.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 4: Pure function — `refineBoundaries`

**Files:**
- Modify: `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift`
- Modify: `Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to test file:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VibeVoiceChunkPlanningRefineBoundariesTests`
Expected: compile error "no member 'refineBoundaries'".

- [ ] **Step 3: Implement**

Add to `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift`:

```swift
    /// Refines target chunk boundaries by snapping each to the midpoint of
    /// the longest silence interval within `±windowSec` of the target.
    /// Falls back to the original target when no silence overlaps the window.
    static func refineBoundaries(
        targets: [Double],
        silences: [ClosedRange<Double>],
        windowSec: Double
    ) -> [Double] {
        targets.map { target in
            let lower = target - windowSec
            let upper = target + windowSec
            // Find silences that overlap [lower, upper]
            let inWindow = silences.filter { $0.upperBound >= lower && $0.lowerBound <= upper }
            guard let longest = inWindow.max(by: { ($0.upperBound - $0.lowerBound) < ($1.upperBound - $1.lowerBound) }) else {
                return target
            }
            return (longest.lowerBound + longest.upperBound) / 2.0
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VibeVoiceChunkPlanningRefineBoundariesTests`
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift
git commit -m "feat(vibevoice): add refineBoundaries pure function

Snaps each target boundary to the midpoint of the longest silence
within +/- windowSec. Falls back to the original target when no
silence overlaps the window.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 5: Pure function — `mergeSegments`

**Files:**
- Modify: `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift`
- Modify: `Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to test file:

```swift
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
        XCTAssertEqual(merged[2].speakerId, 0)  // chunk 1's speaker 0 (not necessarily the same person as chunk 0's would-be speaker 0)
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VibeVoiceChunkPlanningMergeSegmentsTests`
Expected: compile error "no member 'mergeSegments'".

- [ ] **Step 3: Implement**

Add to `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift`:

```swift
    /// Merges per-chunk segment arrays into a single chronological list by
    /// offsetting each chunk's segment timestamps by the chunk's start time
    /// in the source audio. Empty chunks contribute nothing.
    ///
    /// - Parameters:
    ///   - chunkOffsetsSec: Start time (seconds) of each chunk in source audio.
    ///                     Must be parallel to `perChunkSegments`.
    ///   - perChunkSegments: Segments returned by each chunk's transcription.
    ///                       Timestamps are local to the chunk (0..chunkLength).
    static func mergeSegments(
        chunkOffsetsSec: [Double],
        perChunkSegments: [[STTSegment]]
    ) -> [STTSegment] {
        precondition(chunkOffsetsSec.count == perChunkSegments.count,
                     "chunkOffsetsSec and perChunkSegments must be parallel arrays")
        var result: [STTSegment] = []
        for (offset, segments) in zip(chunkOffsetsSec, perChunkSegments) {
            let offsetMs = Int(offset * 1000)
            for seg in segments {
                result.append(STTSegment(
                    startMs: seg.startMs + offsetMs,
                    endMs:   seg.endMs   + offsetMs,
                    text:    seg.text,
                    speakerId: seg.speakerId
                ))
            }
        }
        return result
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VibeVoiceChunkPlanningMergeSegmentsTests`
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift
git commit -m "feat(vibevoice): add mergeSegments pure function

Offsets per-chunk timestamps by chunk start time and concatenates
into one chronological list. Empty chunks contribute nothing.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 6: Pure function — `overallProgress`

**Files:**
- Modify: `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift`
- Modify: `Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift`

- [ ] **Step 1: Write the failing tests**

Append to test file:

```swift
final class VibeVoiceChunkPlanningOverallProgressTests: XCTestCase {

    func testStartOfFirstChunk() {
        XCTAssertEqual(
            VibeVoiceChunkPlanning.overallProgress(chunkIndex: 0, localPct: 0, totalChunks: 6),
            0
        )
    }

    func testMidpointOfFirstChunk() {
        // 50% of chunk 0 in a 6-chunk job: (0*100 + 50)/6 = 8
        XCTAssertEqual(
            VibeVoiceChunkPlanning.overallProgress(chunkIndex: 0, localPct: 50, totalChunks: 6),
            8
        )
    }

    func testEndOfFirstChunkMatchesStartOfSecond() {
        let endChunk0 = VibeVoiceChunkPlanning.overallProgress(chunkIndex: 0, localPct: 100, totalChunks: 6)
        let startChunk1 = VibeVoiceChunkPlanning.overallProgress(chunkIndex: 1, localPct: 0, totalChunks: 6)
        XCTAssertEqual(endChunk0, startChunk1, "Chunk transitions must be continuous (monotonic without gaps)")
        XCTAssertEqual(endChunk0, 16)
    }

    func testFinalChunkEndsAt100() {
        XCTAssertEqual(
            VibeVoiceChunkPlanning.overallProgress(chunkIndex: 5, localPct: 100, totalChunks: 6),
            100
        )
    }

    /// Monotonicity sweep: walk through every (chunkIndex, localPct) pair
    /// in chronological order and assert each value is >= the previous.
    func testMonotonicityAcrossAllChunks() {
        let totalChunks = 6
        var prev = -1
        for c in 0..<totalChunks {
            for p in stride(from: 0, through: 100, by: 10) {
                let value = VibeVoiceChunkPlanning.overallProgress(
                    chunkIndex: c, localPct: p, totalChunks: totalChunks
                )
                XCTAssertGreaterThanOrEqual(value, prev,
                    "Progress went backwards at chunk \(c) pct \(p): \(prev) → \(value)")
                prev = value
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter VibeVoiceChunkPlanningOverallProgressTests`
Expected: compile error "no member 'overallProgress'".

- [ ] **Step 3: Implement**

Add to `Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift`:

```swift
    /// Maps a chunk-local percentage (0..100) to overall job percentage
    /// (0..100) across `totalChunks` chunks.
    ///
    /// Formula: `(chunkIndex * 100 + localPct) / totalChunks`.
    /// Chunk N's completion (localPct=100) equals chunk N+1's start
    /// (localPct=0), so the bar moves continuously across chunk transitions.
    static func overallProgress(chunkIndex: Int, localPct: Int, totalChunks: Int) -> Int {
        precondition(totalChunks > 0, "totalChunks must be positive")
        precondition(chunkIndex >= 0 && chunkIndex < totalChunks, "chunkIndex out of range")
        return (chunkIndex * 100 + localPct) / totalChunks
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter VibeVoiceChunkPlanningOverallProgressTests`
Expected: all 5 tests pass.

- [ ] **Step 5: Verify all pure-function tests pass together**

Run: `swift test --filter VibeVoiceChunkPlanning`
Expected: ~25 tests pass across all pure-function suites.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceChunkPlanning.swift Tests/MacParakeetTests/STT/VibeVoiceChunkPlanningTests.swift
git commit -m "feat(vibevoice): add overallProgress pure function

Maps chunk-local percentage to overall percentage across N chunks.
Verified monotonic across chunk transitions and continuous at
boundaries (chunk N end = chunk N+1 start).

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 7: Generate synthetic silence fixture

**Files:**
- Create: `scripts/dev/make_silence_fixture.sh`
- Create: `Tests/MacParakeetTests/STT/Fixtures/synthetic_silence.wav` (generated by script)
- Create: `Tests/MacParakeetTests/STT/Fixtures/README.md`

- [ ] **Step 1: Create the generator script**

Create `scripts/dev/make_silence_fixture.sh`:

```bash
#!/usr/bin/env bash
# Generates a deterministic 60-second 24 kHz mono WAV with silence at
# 20-22 s and 40-42 s. Used by VibeVoiceChunkedTranscriberTests for
# silence-detect integration tests without depending on real recordings.

set -euo pipefail

OUT="Tests/MacParakeetTests/STT/Fixtures/synthetic_silence.wav"
mkdir -p "$(dirname "$OUT")"

# A 1 kHz sine for "speech-like" energy, with two silent gaps interleaved.
# - 0..20 s: tone at -10 dB
# - 20..22 s: silence
# - 22..40 s: tone at -10 dB
# - 40..42 s: silence
# - 42..60 s: tone at -10 dB
ffmpeg -y \
  -f lavfi -i "sine=frequency=1000:duration=60:sample_rate=24000" \
  -af "volume=0.3,
       afade=t=out:st=20:d=0.05,
       afade=t=in:st=22:d=0.05,
       afade=t=out:st=40:d=0.05,
       afade=t=in:st=42:d=0.05" \
  -ac 1 -ar 24000 -c:a pcm_s16le \
  "$OUT" >/dev/null 2>&1

echo "Generated: $OUT"
ffprobe -v error -show_entries format=duration "$OUT"
```

- [ ] **Step 2: Make executable and run it**

Run:
```bash
chmod +x scripts/dev/make_silence_fixture.sh
./scripts/dev/make_silence_fixture.sh
```
Expected output: `Generated: Tests/MacParakeetTests/STT/Fixtures/synthetic_silence.wav` followed by `duration=60.000000`.

- [ ] **Step 3: Verify the fixture has the expected silences**

Run:
```bash
ffmpeg -i Tests/MacParakeetTests/STT/Fixtures/synthetic_silence.wav \
  -af silencedetect=n=-30dB:d=0.3 -f null - 2>&1 | grep silence_
```
Expected output: two `silence_start` / `silence_end` pairs near 20 / 22 / 40 / 42 seconds.

- [ ] **Step 4: Document the fixture**

Create `Tests/MacParakeetTests/STT/Fixtures/README.md`:

```markdown
# Test Fixtures

## synthetic_silence.wav

60-second 24 kHz mono Int16 WAV with:
- Tone (1 kHz, -10 dB) from 0..20 s, 22..40 s, 42..60 s
- Silence at 20-22 s and 40-42 s

Generated by `scripts/dev/make_silence_fixture.sh`. Regenerate any time
the silence test expectations change. The fixture is deterministic — FFmpeg
produces the same bytes given the same input.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/dev/make_silence_fixture.sh Tests/MacParakeetTests/STT/Fixtures/synthetic_silence.wav Tests/MacParakeetTests/STT/Fixtures/README.md
git commit -m "test(vibevoice): add synthetic silence fixture for chunker tests

A 60-s synthetic WAV with silences at known positions (20-22 s and
40-42 s). Deterministically reproducible via the included script.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 8: Create `VibeVoiceChunkedTranscriber` actor skeleton + fake engine

**Files:**
- Create: `Sources/MacParakeetCore/STT/VibeVoiceChunkedTranscriber.swift`
- Create: `Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift`

This task creates the actor's structure and the test double together, so the next task can write orchestration tests that compile.

- [ ] **Step 1: Create the actor skeleton**

Create `Sources/MacParakeetCore/STT/VibeVoiceChunkedTranscriber.swift`:

```swift
import AVFoundation
import Foundation
import OSLog

/// Orchestrates long-form VibeVoice transcription by splitting the source
/// audio into ~5-minute chunks, transcribing each via the inner engine, and
/// merging the per-chunk segments into a single `STTResult`.
///
/// Lives in `MacParakeetCore` (not `VibeVoiceCore`) because it depends on
/// `BinaryBootstrap.requireRuntimeFFmpegPath()` to invoke FFmpeg for the
/// silence-detect and segment-split passes.
///
/// Fail-all on chunk error: if any chunk's `engine.transcribe(...)` throws,
/// the whole job throws. No partial transcript is returned. See the spec
/// `docs/superpowers/specs/2026-05-26-vibevoice-chunked-transcription-design.md`
/// for the rationale.
public actor VibeVoiceChunkedTranscriber {
    private static let logger = Logger(
        subsystem: "com.macparakeet.vibevoice",
        category: "VibeVoiceChunkedTranscriber"
    )

    private let engine: any STTTranscribing
    private let chunkLengthSec: Double
    private let minTailSec: Double
    private let silenceWindowSec: Double
    private let silenceThresholdDb: Double
    private let silenceMinDurationSec: Double

    /// - Parameters:
    ///   - engine: An `STTTranscribing`-conforming engine. In production this
    ///             is a `VibeVoiceEngine`. Tests pass a fake.
    ///   - chunkLengthSec: Target seconds per chunk. Defaults to 300 (5 min).
    ///   - minTailSec: If the final chunk would be shorter than this, the
    ///                 last boundary is dropped so the tail folds into the
    ///                 prior chunk. Defaults to 30.
    ///   - silenceWindowSec: ± seconds around each target boundary to search
    ///                       for silence. Defaults to 15.
    ///   - silenceThresholdDb: FFmpeg silencedetect `n` parameter in dB.
    ///                         Defaults to -30.
    ///   - silenceMinDurationSec: FFmpeg silencedetect `d` parameter in s.
    ///                            Defaults to 0.3.
    public init(
        engine: any STTTranscribing,
        chunkLengthSec: Double = 300,
        minTailSec: Double = 30,
        silenceWindowSec: Double = 15,
        silenceThresholdDb: Double = -30,
        silenceMinDurationSec: Double = 0.3
    ) {
        self.engine = engine
        self.chunkLengthSec = chunkLengthSec
        self.minTailSec = minTailSec
        self.silenceWindowSec = silenceWindowSec
        self.silenceThresholdDb = silenceThresholdDb
        self.silenceMinDurationSec = silenceMinDurationSec
    }

    /// Transcribes a long-form audio file by chunking + sequential engine calls.
    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        // Implemented in Task 10 (after orchestration tests are written).
        throw STTError.transcriptionFailed("VibeVoiceChunkedTranscriber.transcribe not yet implemented")
    }
}
```

- [ ] **Step 2: Create the test file with the fake engine**

Create `Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift`:

```swift
import XCTest
@testable import MacParakeetCore

/// A test double for any `STTTranscribing` engine. Records calls, supports
/// per-path canned results and per-path errors. Fires (0, 100) and then
/// (100, 100) on the progress callback to mimic the real engine's contract.
final class FakeVibeVoiceTranscribing: STTTranscribing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "FakeVibeVoiceTranscribing.state")
    private var _resultsByPath: [String: [STTSegment]] = [:]
    private var _shouldThrowOnPath: String? = nil
    private var _callLog: [(path: String, job: STTJobKind)] = []

    func setResults(forPath path: String, segments: [STTSegment]) {
        queue.sync { _resultsByPath[path] = segments }
    }

    func setShouldThrow(onPath path: String) {
        queue.sync { _shouldThrowOnPath = path }
    }

    var callLog: [(path: String, job: STTJobKind)] {
        queue.sync { _callLog }
    }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        queue.sync { _callLog.append((path: audioPath, job: job)) }
        let shouldThrow: Bool = queue.sync { _shouldThrowOnPath == audioPath }
        if shouldThrow {
            throw STTError.transcriptionFailed("fake fail: \(audioPath)")
        }
        onProgress?(0, 100)
        let segments: [STTSegment] = queue.sync { _resultsByPath[audioPath] ?? [] }
        onProgress?(100, 100)
        return STTResult(
            text: segments.map(\.text).joined(separator: "\n"),
            words: [],
            segments: segments,
            language: nil,
            engine: .vibevoice,
            engineVariant: "fake"
        )
    }
}

final class VibeVoiceChunkedTranscriberConstructorTests: XCTestCase {
    func testInitializesWithDefaults() async {
        let fake = FakeVibeVoiceTranscribing()
        let chunker = VibeVoiceChunkedTranscriber(engine: fake)
        _ = chunker  // ensure init compiles and doesn't crash
    }
}
```

- [ ] **Step 3: Run the smoke test**

Run: `swift test --filter VibeVoiceChunkedTranscriberConstructorTests`
Expected: passes (constructor compiles and runs).

- [ ] **Step 4: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceChunkedTranscriber.swift Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift
git commit -m "feat(vibevoice): add VibeVoiceChunkedTranscriber actor skeleton

Scaffolds the orchestrator actor and the FakeVibeVoiceTranscribing
test double. transcribe(...) throws not-yet-implemented; the next
tasks write failing orchestration tests then fill the body in.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 9: Orchestration tests — happy path (real FFmpeg + fake engine)

**Files:**
- Modify: `Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift`

- [ ] **Step 1: Add the happy-path orchestration test**

Append to `Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift`:

```swift
final class VibeVoiceChunkedTranscriberOrchestrationTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // STT/
            .appendingPathComponent("Fixtures/synthetic_silence.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path),
                          "synthetic_silence.wav fixture missing — run scripts/dev/make_silence_fixture.sh")
        return url
    }

    /// 60-s fixture, chunkLengthSec=20 → 3 chunks. Silences at 20-22 s and
    /// 40-42 s mean boundaries should snap there. Fake engine returns one
    /// canned segment per chunk; the merger combines them with offsets.
    func testHappyPathThreeChunksMergedWithOffsets() async throws {
        let fixture = try fixtureURL()
        let fake = FakeVibeVoiceTranscribing()
        // Pre-canned segments — keyed by chunk path which we'll compute
        // after the chunker invokes ensureWAV/split. Use the call log to
        // map: chunk index = order of calls.
        // Since we don't know the chunk path in advance, set a default
        // result regardless of path by using a custom fake variant for
        // this test:
        let recorder = SegmentInjectingFake()
        recorder.injectedSegments = [
            [STTSegment(startMs: 0, endMs: 18_000, text: "chunk0", speakerId: 0)],
            [STTSegment(startMs: 0, endMs: 18_000, text: "chunk1", speakerId: 0)],
            [STTSegment(startMs: 0, endMs: 15_000, text: "chunk2", speakerId: 0)],
        ]
        let chunker = VibeVoiceChunkedTranscriber(
            engine: recorder,
            chunkLengthSec: 20,
            minTailSec: 5,
            silenceWindowSec: 5
        )
        let result = try await chunker.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            onProgress: nil
        )
        // Three chunks were processed
        XCTAssertEqual(recorder.callCount, 3)
        // Three merged segments, with offsets matching refined boundaries.
        // Boundaries: target 20 s snaps to ~21 (mid of silence 20-22),
        //             target 40 s snaps to ~41 (mid of silence 40-42).
        XCTAssertEqual(result.segments.count, 3)
        XCTAssertEqual(result.segments[0].startMs, 0)
        XCTAssertEqual(result.segments[0].text, "chunk0")
        // Chunk 1 starts at refined boundary (≈ 21 s = 21000 ms)
        XCTAssertEqual(Double(result.segments[1].startMs), 21000, accuracy: 200)
        XCTAssertEqual(result.segments[1].text, "chunk1")
        // Chunk 2 starts at refined boundary (≈ 41 s = 41000 ms)
        XCTAssertEqual(Double(result.segments[2].startMs), 41000, accuracy: 200)
        XCTAssertEqual(result.segments[2].text, "chunk2")
        // Engine variant tagged as chunked
        XCTAssertEqual(result.engineVariant, "vibevoice-asr-q4_k-chunked")
        XCTAssertEqual(result.engine, .vibevoice)
        XCTAssertTrue(result.words.isEmpty)
    }
}

/// A more controllable fake that returns a different segment per call,
/// in call order. Used when test setup doesn't know chunk paths in advance.
final class SegmentInjectingFake: STTTranscribing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "SegmentInjectingFake")
    private var _injectedSegments: [[STTSegment]] = []
    private var _callCount = 0

    var injectedSegments: [[STTSegment]] {
        get { queue.sync { _injectedSegments } }
        set { queue.sync { _injectedSegments = newValue } }
    }
    var callCount: Int { queue.sync { _callCount } }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let segments: [STTSegment] = queue.sync {
            defer { _callCount += 1 }
            return _callCount < _injectedSegments.count ? _injectedSegments[_callCount] : []
        }
        onProgress?(0, 100)
        onProgress?(100, 100)
        return STTResult(
            text: segments.map(\.text).joined(separator: "\n"),
            words: [],
            segments: segments,
            language: nil,
            engine: .vibevoice,
            engineVariant: "fake"
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter VibeVoiceChunkedTranscriberOrchestrationTests`
Expected: FAIL with `STTError.transcriptionFailed("VibeVoiceChunkedTranscriber.transcribe not yet implemented")`.

- [ ] **Step 3: Commit the failing test**

```bash
git add Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift
git commit -m "test(vibevoice): add happy-path orchestration test (failing)

Uses synthetic_silence.wav fixture + SegmentInjectingFake. Tests
the full silence-detect → split → loop → merge path. Test is
failing because transcribe() body is not yet implemented; the
next task implements it.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 10: Implement `transcribe(...)` orchestration

**Files:**
- Modify: `Sources/MacParakeetCore/STT/VibeVoiceChunkedTranscriber.swift`

- [ ] **Step 1: Implement the orchestration**

Replace the entire `transcribe(...)` method (currently just throws not-yet-implemented) with:

```swift
    public func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> STTResult {
        let overallStart = Date()
        let audioURL = URL(fileURLWithPath: audioPath)

        // 1. Measure audio duration
        let audioSec = try AudioFileConverter.audioDuration(at: audioURL)

        // 2. Plan: compute target boundaries
        let targets = VibeVoiceChunkPlanning.computeChunkPlan(
            audioSec: audioSec,
            chunkLengthSec: chunkLengthSec,
            minTailSec: minTailSec
        )

        // 3. Silence-detect via FFmpeg, parse, refine boundaries
        let silenceStart = Date()
        let silences = try await runSilenceDetect(audioPath: audioPath)
        let refinedBoundaries = VibeVoiceChunkPlanning.refineBoundaries(
            targets: targets,
            silences: silences,
            windowSec: silenceWindowSec
        )
        let silenceElapsed = Date().timeIntervalSince(silenceStart)

        // 4. Compute chunk start offsets (parallel to chunk files): [0, b1, b2, ..., bN-1]
        let chunkStartOffsets: [Double] = [0] + refinedBoundaries
        let totalChunks = chunkStartOffsets.count

        // 5. Split via FFmpeg segment muxer
        let splitStart = Date()
        let chunkURLs = try await splitAudio(audioPath: audioPath, boundaries: refinedBoundaries)
        let splitElapsed = Date().timeIntervalSince(splitStart)
        defer {
            for url in chunkURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // Defensive: chunk count from FFmpeg must match what we planned.
        guard chunkURLs.count == totalChunks else {
            throw STTError.transcriptionFailed(
                "FFmpeg produced \(chunkURLs.count) chunks but plan expected \(totalChunks)"
            )
        }

        Self.logger.notice("chunked transcribe starting: audio=\(audioSec, format: .fixed(precision: 1))s, totalChunks=\(totalChunks, privacy: .public), silenceDetect=\(silenceElapsed, format: .fixed(precision: 2))s, split=\(splitElapsed, format: .fixed(precision: 2))s")

        // 6. Loop: transcribe each chunk sequentially, merge segments
        var perChunkSegments: [[STTSegment]] = []
        let inferStart = Date()
        for (chunkIndex, chunkURL) in chunkURLs.enumerated() {
            let perChunkProgress: (@Sendable (Int, Int) -> Void)? = onProgress.map { outer in
                { localPct, _ in
                    let overall = VibeVoiceChunkPlanning.overallProgress(
                        chunkIndex: chunkIndex,
                        localPct: localPct,
                        totalChunks: totalChunks
                    )
                    outer(overall, 100)
                }
            }
            let chunkResult = try await engine.transcribe(
                audioPath: chunkURL.path,
                job: job,
                onProgress: perChunkProgress
            )
            perChunkSegments.append(chunkResult.segments)
        }
        let inferElapsed = Date().timeIntervalSince(inferStart)

        // 7. Merge segments with chunk offsets
        let mergedSegments = VibeVoiceChunkPlanning.mergeSegments(
            chunkOffsetsSec: chunkStartOffsets,
            perChunkSegments: perChunkSegments
        )

        // Final progress snap to 100
        onProgress?(100, 100)

        let overallElapsed = Date().timeIntervalSince(overallStart)
        let rtf = audioSec > 0 ? inferElapsed / audioSec : -1
        Self.logger.notice("chunked transcribe complete: chunks=\(totalChunks, privacy: .public), infer=\(inferElapsed, format: .fixed(precision: 2))s, overall=\(overallElapsed, format: .fixed(precision: 2))s, RTF=\(rtf, format: .fixed(precision: 3)), segments=\(mergedSegments.count, privacy: .public)")

        return STTResult(
            text: mergedSegments.map(\.text).joined(separator: "\n"),
            words: [],
            segments: mergedSegments,
            language: nil,
            engine: .vibevoice,
            engineVariant: "vibevoice-asr-q4_k-chunked"
        )
    }

    // MARK: - FFmpeg helpers

    private func runSilenceDetect(audioPath: String) async throws -> [ClosedRange<Double>] {
        let ffmpeg = try BinaryBootstrap.requireRuntimeFFmpegPath()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", audioPath,
            "-af", "silencedetect=n=\(silenceThresholdDb)dB:d=\(silenceMinDurationSec)",
            "-f", "null", "-"
        ]
        let stderrPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // FFmpeg silencedetect emits a non-zero exit only on real errors;
        // missing matches are not errors. We tolerate any exit code and
        // parse whatever was emitted — empty result → uniform-split fallback.
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return VibeVoiceChunkPlanning.parseSilenceIntervals(stderr)
    }

    private func splitAudio(audioPath: String, boundaries: [Double]) async throws -> [URL] {
        let ffmpeg = try BinaryBootstrap.requireRuntimeFFmpegPath()
        let uuid = UUID().uuidString
        let outputPattern = FileManager.default.temporaryDirectory
            .appendingPathComponent("vv-chunk-\(uuid)-%03d.wav").path

        var args = [
            "-i", audioPath,
            "-ar", "24000",
            "-ac", "1",
            "-c:a", "pcm_s16le",
            "-map", "0:a",
            "-f", "segment"
        ]
        if !boundaries.isEmpty {
            args.append(contentsOf: ["-segment_times", boundaries.map { String($0) }.joined(separator: ",")])
        }
        args.append("-y")
        args.append(outputPattern)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw STTError.transcriptionFailed(
                "FFmpeg segment split failed with status \(process.terminationStatus)"
            )
        }

        // Discover the produced files. FFmpeg writes vv-chunk-<uuid>-000.wav,
        // -001.wav, ... — discover by listing the temp dir.
        let tempDir = FileManager.default.temporaryDirectory
        let prefix = "vv-chunk-\(uuid)-"
        let allFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let chunks = allFiles
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".wav") }
            .sorted()  // lexical order matches numeric for zero-padded 3-digit indices
            .map { tempDir.appendingPathComponent($0) }
        return chunks
    }
```

- [ ] **Step 2: Run the happy-path test to verify it passes**

Run: `swift test --filter VibeVoiceChunkedTranscriberOrchestrationTests`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/MacParakeetCore/STT/VibeVoiceChunkedTranscriber.swift
git commit -m "feat(vibevoice): implement chunked transcribe orchestration

Wires the pure functions and FFmpeg helpers into the full
silence-detect → refine → split → loop → merge pipeline. Happy-path
test passes against the synthetic silence fixture.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 11: Orchestration test — fail-all on throwing chunk

**Files:**
- Modify: `Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift`

- [ ] **Step 1: Add the failure-policy test**

Append inside `VibeVoiceChunkedTranscriberOrchestrationTests`:

```swift
    /// If a single chunk's engine.transcribe throws, the whole transcribe
    /// call throws. No partial transcript is returned.
    func testThrowingChunkFailsWholeJob() async throws {
        let fixture = try fixtureURL()
        let thrower = ThrowingOnSecondCallFake()
        let chunker = VibeVoiceChunkedTranscriber(
            engine: thrower,
            chunkLengthSec: 20,
            minTailSec: 5,
            silenceWindowSec: 5
        )
        do {
            _ = try await chunker.transcribe(
                audioPath: fixture.path,
                job: .fileTranscription,
                onProgress: nil
            )
            XCTFail("Expected throw from chunked transcribe")
        } catch let error as STTError {
            // Expected — propagated from the inner engine's STTError.
            switch error {
            case .transcriptionFailed(let msg):
                XCTAssertTrue(msg.contains("fake chunk 2"), "Got: \(msg)")
            default:
                XCTFail("Unexpected STTError: \(error)")
            }
        }
        // The fake should have been called exactly twice (chunk 0 succeeded,
        // chunk 1 threw, chunk 2 was never invoked).
        XCTAssertEqual(thrower.callCount, 2)
    }

    /// Temp chunk files are removed even when the loop throws mid-way.
    func testCleanupRunsOnFailure() async throws {
        let fixture = try fixtureURL()
        let thrower = ThrowingOnSecondCallFake()
        let chunker = VibeVoiceChunkedTranscriber(
            engine: thrower,
            chunkLengthSec: 20,
            minTailSec: 5,
            silenceWindowSec: 5
        )
        let tempDirBefore = try countVvChunkFilesInTempDir()
        _ = try? await chunker.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            onProgress: nil
        )
        // Allow defer to run on the failing path
        let tempDirAfter = try countVvChunkFilesInTempDir()
        XCTAssertEqual(tempDirBefore, tempDirAfter,
                       "Temp vv-chunk-* files should have been cleaned up after failure")
    }

    private func countVvChunkFilesInTempDir() throws -> Int {
        let tempDir = FileManager.default.temporaryDirectory
        let all = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        return all.filter { $0.hasPrefix("vv-chunk-") && $0.hasSuffix(".wav") }.count
    }
}

/// A fake that succeeds on the first call and throws on the second.
final class ThrowingOnSecondCallFake: STTTranscribing, @unchecked Sendable {
    private let queue = DispatchQueue(label: "ThrowingOnSecondCallFake")
    private var _callCount = 0
    var callCount: Int { queue.sync { _callCount } }

    func transcribe(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let index: Int = queue.sync {
            let current = _callCount
            _callCount += 1
            return current
        }
        if index == 1 {
            throw STTError.transcriptionFailed("fake chunk 2")
        }
        onProgress?(0, 100)
        onProgress?(100, 100)
        return STTResult(
            text: "",
            words: [],
            segments: [],
            language: nil,
            engine: .vibevoice,
            engineVariant: "fake"
        )
    }
}
```

- [ ] **Step 2: Run the failure tests**

Run: `swift test --filter VibeVoiceChunkedTranscriberOrchestrationTests`
Expected: both new tests pass; previous happy-path still passes.

- [ ] **Step 3: Commit**

```bash
git add Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift
git commit -m "test(vibevoice): verify fail-all policy and cleanup on chunk error

Adds two orchestration tests: throwing mid-loop propagates and stops
further chunks; temp chunk files are still cleaned up via defer.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 12: Orchestration test — progress callbacks are monotonic

**Files:**
- Modify: `Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift`

- [ ] **Step 1: Add the progress test**

Append inside `VibeVoiceChunkedTranscriberOrchestrationTests`:

```swift
    func testProgressIsMonotonicAndEndsAt100() async throws {
        let fixture = try fixtureURL()
        let fake = SegmentInjectingFake()
        fake.injectedSegments = [
            [STTSegment(startMs: 0, endMs: 1000, text: "a", speakerId: 0)],
            [STTSegment(startMs: 0, endMs: 1000, text: "b", speakerId: 0)],
            [STTSegment(startMs: 0, endMs: 1000, text: "c", speakerId: 0)],
        ]
        // Capture every (current, total) callback into a thread-safe list.
        let progressLog = ProgressLog()
        let onProgress: @Sendable (Int, Int) -> Void = { current, total in
            progressLog.append((current, total))
        }
        let chunker = VibeVoiceChunkedTranscriber(
            engine: fake,
            chunkLengthSec: 20,
            minTailSec: 5,
            silenceWindowSec: 5
        )
        _ = try await chunker.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            onProgress: onProgress
        )
        let snapshot = progressLog.values
        XCTAssertFalse(snapshot.isEmpty, "Expected at least one progress callback")
        // All totals should be 100
        for (_, total) in snapshot {
            XCTAssertEqual(total, 100)
        }
        // Currents must be monotonically non-decreasing
        var prev = -1
        for (current, _) in snapshot {
            XCTAssertGreaterThanOrEqual(current, prev,
                "Progress went backward in sequence: \(snapshot)")
            prev = current
        }
        // Final value is 100
        XCTAssertEqual(snapshot.last?.0, 100)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let queue = DispatchQueue(label: "ProgressLog")
    private var _values: [(Int, Int)] = []
    func append(_ value: (Int, Int)) { queue.sync { _values.append(value) } }
    var values: [(Int, Int)] { queue.sync { _values } }
}
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter VibeVoiceChunkedTranscriberOrchestrationTests`
Expected: all orchestration tests (happy path + 2 failure tests + 1 progress test) pass.

- [ ] **Step 3: Commit**

```bash
git add Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift
git commit -m "test(vibevoice): verify chunked progress is monotonic and ends at 100

Captures all progress callbacks fired during a 3-chunk job and
asserts they're non-decreasing with the final callback at 100.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 13: Wire chunker into `STTRuntime`

**Files:**
- Modify: `Sources/MacParakeetCore/STT/STTRuntime.swift`
- Modify: `Tests/MacParakeetTests/STT/STTRuntimeVibeVoiceTests.swift`

- [ ] **Step 1: Add the failing branch test**

Append to `Tests/MacParakeetTests/STT/STTRuntimeVibeVoiceTests.swift`:

```swift
final class STTRuntimeVibeVoiceChunkingTests: XCTestCase {

    /// Audio shorter than the threshold goes through the single-shot engine
    /// path and tags engineVariant accordingly.
    func testShortAudioUsesSingleShotPath() async throws {
        // Skip if the real engine isn't available — this is an integration
        // check that runs end-to-end through STTRuntime, which lazily
        // constructs VibeVoiceEngine and would fail if the model is missing.
        try XCTSkipIf(
            !FileManager.default.fileExists(atPath:
                VibeVoiceEngine.defaultModelDirectory()
                    .appendingPathComponent("vibevoice-asr-q4_k.gguf").path),
            "VibeVoice model not installed"
        )

        let runtime = STTRuntime()
        try await runtime.warmUp(onProgress: nil)

        // tiny_ted.wav is 15 s — well under the 450 s threshold.
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VibeVoiceCoreTests/Resources/tiny_ted.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path),
                          "tiny_ted.wav not present")

        let selection = SpeechEngineSelection(engine: .vibevoice, language: nil)
        let result = try await runtime.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            speechEngine: selection
        )
        XCTAssertEqual(result.engineVariant, "vibevoice-asr-q4_k",
                       "15-s audio should NOT be routed through the chunker")
    }
}
```

- [ ] **Step 2: Run to confirm it fails or skips**

Run: `swift test --filter STTRuntimeVibeVoiceChunkingTests`
Expected: either passes (if engine routes single-shot already, which it currently does) or skips (model missing). This task isn't about making this test fail — it's a regression guard.

- [ ] **Step 3: Modify `STTRuntime.swift` to add the branch**

Open `Sources/MacParakeetCore/STT/STTRuntime.swift`.

Find the member declaration block where `vibevoiceEngine` is declared. Add alongside it:

```swift
    private var vibevoiceChunkedTranscriber: VibeVoiceChunkedTranscriber?

    /// Audio longer than this is routed through the chunker instead of
    /// the single-shot engine. 450 s = 7.5 min = 1.5 × chunk length, so
    /// we never produce a tiny final chunk. See spec
    /// 2026-05-26-vibevoice-chunked-transcription-design.md.
    private static let vibevoiceChunkThresholdSec: Double = 450.0
```

Find the existing `transcribeWithVibeVoice` method:

```swift
    private func transcribeWithVibeVoice(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let engine = vibevoiceEngine ?? VibeVoiceEngine()
        if vibevoiceEngine == nil { vibevoiceEngine = engine }
        return try await engine.transcribe(audioPath: audioPath, job: job, onProgress: onProgress)
    }
```

Replace its body with the branching version:

```swift
    private func transcribeWithVibeVoice(
        audioPath: String,
        job: STTJobKind,
        onProgress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> STTResult {
        let engine = vibevoiceEngine ?? VibeVoiceEngine()
        if vibevoiceEngine == nil { vibevoiceEngine = engine }

        let audioSec = (try? AudioFileConverter.audioDuration(
            at: URL(fileURLWithPath: audioPath))) ?? 0
        if audioSec > Self.vibevoiceChunkThresholdSec {
            let chunker = vibevoiceChunkedTranscriber
                ?? VibeVoiceChunkedTranscriber(engine: engine)
            if vibevoiceChunkedTranscriber == nil {
                vibevoiceChunkedTranscriber = chunker
            }
            return try await chunker.transcribe(
                audioPath: audioPath, job: job, onProgress: onProgress
            )
        } else {
            return try await engine.transcribe(
                audioPath: audioPath, job: job, onProgress: onProgress
            )
        }
    }
```

- [ ] **Step 4: Build the whole package**

Run: `swift build`
Expected: succeeds (no compile errors).

- [ ] **Step 5: Run the full STT test suite**

Run: `swift test --filter "STTRuntime\|VibeVoiceChunk"`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/MacParakeetCore/STT/STTRuntime.swift Tests/MacParakeetTests/STT/STTRuntimeVibeVoiceTests.swift
git commit -m "feat(vibevoice): route long audio through chunker in STTRuntime

Audio over 450 s (7.5 min) is now transcribed via
VibeVoiceChunkedTranscriber. Short audio continues to use the
single-shot engine path with no behavior change.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Task 14: Manual end-to-end with the real model (gated)

**Files:**
- Modify: `Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift`

- [ ] **Step 1: Add the gated e2e test**

Append:

```swift
final class VibeVoiceChunkedTranscriberRealModelTests: XCTestCase {

    /// End-to-end: real VibeVoiceEngine, real FFmpeg, real model. Uses the
    /// 15-s tiny_ted fixture but forces chunking by setting chunkLengthSec=5.
    /// Verifies the merged transcript contains content from both halves.
    func testRealEngineChunksAndMerges() async throws {
        let modelDir = VibeVoiceEngine.defaultModelDirectory()
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath:
                modelDir.appendingPathComponent("vibevoice-asr-q4_k.gguf").path),
            "VibeVoice model not installed"
        )

        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VibeVoiceCoreTests/Resources/tiny_ted.wav")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path),
                          "tiny_ted.wav not present")

        let engine = VibeVoiceEngine()
        try await engine.warmUp()
        let chunker = VibeVoiceChunkedTranscriber(
            engine: engine,
            chunkLengthSec: 5,
            minTailSec: 2,
            silenceWindowSec: 1
        )
        let result = try await chunker.transcribe(
            audioPath: fixture.path,
            job: .fileTranscription,
            onProgress: nil
        )
        XCTAssertEqual(result.engineVariant, "vibevoice-asr-q4_k-chunked")
        XCTAssertFalse(result.segments.isEmpty)
        XCTAssertFalse(result.text.isEmpty)
        // The merged transcript should reference the known TED content.
        XCTAssertTrue(result.text.lowercased().contains("college"),
                      "Expected 'college' in transcript; got: \(result.text)")
    }
}
```

- [ ] **Step 2: Run the gated test (skips without model)**

Run: `swift test --filter VibeVoiceChunkedTranscriberRealModelTests`
Expected: passes if the model is installed locally, skips otherwise.

- [ ] **Step 3: Commit**

```bash
git add Tests/MacParakeetTests/STT/VibeVoiceChunkedTranscriberTests.swift
git commit -m "test(vibevoice): add gated e2e chunked transcription test

Real engine + real FFmpeg + real model, with chunkLengthSec=5 to
force chunking on the 15-s tiny_ted fixture. Skipped when the
model isn't installed locally.

Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>"
```

---

## Final Verification

- [ ] **Run the full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: all tests pass (model-gated tests may skip).

- [ ] **Build and relaunch the app**

Run: `scripts/dev/run_app.sh`
Expected: app launches cleanly. Per project memory, the app is relaunched after every commit.

- [ ] **Manual smoke test (you, the reviewer):**

1. Open the GUI.
2. Drop the 30-min Marc Penna fitness video on the file-transcription view with VibeVoice selected.
3. Watch the progress bar: should leave 0 % within ~30 s (after silence-detect + split completes), then progress monotonically to ~100 % over ~15-20 min.
4. When complete, verify the transcript covers the entire 30 min (last segment's `endMs` should be near 1,797,000).
5. Verify `STTResult.engineVariant` is `vibevoice-asr-q4_k-chunked` (visible via CLI's `--format json` or in the database).

If wall time is significantly worse than 25 min, profile per-chunk RTF via the OSLog timing notices and adjust chunkLengthSec or thresholds in a follow-up. Don't change them in this PR.

---

## Spec → Plan Coverage Check

| Spec section | Implementing task(s) |
|---|---|
| Goal: chunked long-form | Tasks 1-13 |
| Non-goal: cross-chunk speakers | Not implemented (correct) |
| Non-goal: partial results | Task 11 verifies fail-all |
| Non-goal: user-configurable chunk length | No CLI/Settings additions (correct) |
| Architecture overview | Tasks 8, 10, 13 |
| File layout | Tasks 1, 2, 8, 13 |
| Pass 1 — Silence Scan | Task 10 (runSilenceDetect) |
| Pass 2 — Boundary Refinement | Task 4 (refineBoundaries) |
| Pass 3 — Split | Task 10 (splitAudio) |
| Edge: audio ≤ threshold | Task 13 (STTRuntime branch) |
| Edge: final chunk < 30 s | Task 3 (computeChunkPlan tests) |
| Edge: no silences detected | Tasks 2, 4 (parser + refiner handle empty silences) |
| Result assembly + timestamps | Task 5 (mergeSegments) |
| Progress reporting | Tasks 6, 12 |
| STTRuntime integration | Task 13 |
| CLI / GUI parity | Implicit (STTRuntime is the shared entry) |
| Pure function unit tests | Tasks 2-6 |
| Orchestration tests with fake | Tasks 8, 9, 11, 12 |
| FFmpeg integration tests | Embedded in orchestration tests (real FFmpeg + fake engine) |
| Manual e2e | Task 14 |
| Fixture additions | Task 7 |
