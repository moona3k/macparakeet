# VibeVoice Chunked Transcription — Design Spec

**Phase:** 2.4 of the VibeVoice integration (follows Phase 2.2 engine wiring and 2.2.1 UI polish).
**Status:** APPROVED — ready for implementation planning.
**Date:** 2026-05-26.

## Goal

Make VibeVoice a viable choice for **long-form audio** (≥ 7.5 min) by splitting the input into sequential ~5-minute chunks before running them through the engine. The single-shot path stays unchanged for short audio. Net effect: a 30-minute fitness video that took **41 min** of wall time under single-shot VibeVoice drops to roughly **15-20 min** wall time chunked — comparable in throughput to "fire and forget while you do something else" while preserving VibeVoice's diarization output within each chunk.

## Non-Goals

These are explicitly out of scope and are deferred to later phases. Don't expand the design to cover them:

- **Cross-chunk speaker continuity.** Speaker IDs reset per chunk. `Speaker 0` in chunk 1 is not guaranteed to be `Speaker 0` in chunk 5. Cross-chunk speaker matching is its own research project and is not attempted here. The single-speaker content type (lectures, podcasts, fitness videos) is what this feature is optimized for; multi-speaker conversations are still better served by Parakeet/Whisper.
- **Partial-result return on failure.** If any chunk's transcription throws, the whole job throws. No partial transcript is returned. Catches transient failures via process retry, not in-job retry.
- **Dynamic / adaptive chunk sizing.** Chunk length is a hardcoded 5 min (300 s). No runtime probe of RTF; no per-file customization.
- **User-configurable chunk length.** No Settings toggle, no CLI flag. YAGNI; revisit if real users ask.
- **Word-level timing.** VibeVoice doesn't emit word timestamps and we're not adding forced alignment here. `STTResult.words` stays `[]` for chunked results, same as single-shot.
- **FFmpeg-phase progress.** The ~30 s spent on silence detection + splitting before inference begins is bar-stays-at-0 % time. We don't allocate it a percentage.
- **Re-running chunking on cached chunks.** Every transcription re-splits. No on-disk chunk cache.

## Architecture Overview

```
┌─ STTRuntime.transcribeWithVibeVoice ───────────────────────────────┐
│  measure audioSec via AVAudioFile                                  │
│  ┌─ audioSec ≤ 450 s ─────────┐  ┌─ audioSec > 450 s ──────────┐ │
│  │ engine.transcribe(...)     │  │ chunkedTranscriber          │ │
│  │   ─ existing path          │  │   .transcribe(...)          │ │
│  └────────────────────────────┘  └──────────────┬──────────────┘ │
└───────────────────────────────────────────────────│───────────────┘
                                                   │
                                                   ▼
┌─ VibeVoiceChunkedTranscriber ─────────────────────────────────────┐
│  1. Silence-detect via FFmpeg                                     │
│  2. Refine target boundaries (snap to nearest silence ±15s)       │
│  3. Split source into N chunk WAVs via FFmpeg segment muxer       │
│  4. Loop: call engine.transcribe per chunk (sequential)           │
│     - wrap engine's onProgress to compute overall %               │
│     - offset segments by chunk start sec                          │
│  5. Merge all segments into one STTResult                         │
│  6. defer { cleanup temp chunk files }                            │
└───────────────────────┬───────────────────────────────────────────┘
                        │ engine.transcribe per chunk
                        ▼
┌─ VibeVoiceEngine (unchanged) ─────────────────────────────────────┐
│  Existing single-file actor. ensureWAV() is a no-op because       │
│  chunks come out of FFmpeg already at 24 kHz mono Int16.          │
└───────────────────────────────────────────────────────────────────┘
```

## File Layout

**New:**
- `Sources/MacParakeetCore/STT/VibeVoiceChunkedTranscriber.swift` — the orchestrator actor. Owns: chunk planning, silence detection, FFmpeg splitting, per-chunk dispatch, result merging, cleanup.

**Modified:**
- `Sources/MacParakeetCore/STT/STTRuntime.swift` — `transcribeWithVibeVoice` adds a single duration-based branch. Holds a `VibeVoiceChunkedTranscriber?` member alongside `vibevoiceEngine`.

**Unmodified:**
- `Sources/MacParakeetCore/STT/VibeVoiceEngine.swift` — kept as-is. Still operates on a single audio file at a time. The chunker calls into it once per chunk.
- `Sources/VibeVoiceCore/VibeVoiceASR.swift` — the C ABI wrapper. No changes.
- `Sources/MacParakeetCore/STT/STTScheduler.swift` — the single-flight VibeVoice guard already wraps the whole transcribe call. Whether that call internally does 1 chunk or 6, the scheduler sees one transcription job.

**Module boundary:** the chunker lives in `MacParakeetCore` (not `VibeVoiceCore`) because it depends on `BinaryBootstrap.requireRuntimeFFmpegPath()` and follows `AudioFileConverter` patterns. `VibeVoiceCore` stays a pure C-ABI wrapper.

## Chunk Splitting & Boundary Detection

### Pass 1 — Silence Scan

One FFmpeg invocation, no audio output:

```
ffmpeg -i <input> -af silencedetect=n=-30dB:d=0.3 -f null -
```

- **Threshold:** -30 dB. Looser than the default -50 dB; catches the kind of brief room-noise pauses in podcasts and workout videos.
- **Min duration:** 0.3 s. Long enough to be a real pause, short enough to find frequent candidates.
- **Output:** stderr lines of the form `[silencedetect @ 0x...] silence_start: 4.5` and `silence_end: 5.2 | silence_duration: 0.7`.

Parser produces `[ClosedRange<Double>]`.

### Pass 2 — Boundary Refinement

Target chunk boundaries are at `i × 300` seconds for `i = 1..(N-1)`.

For each target:
1. Define search window `[target - 15, target + 15]`.
2. Find all silence intervals that overlap the window.
3. If any overlap, snap the boundary to the **midpoint of the longest overlapping silence**.
4. If none overlap, fall back to the target itself (uniform split).

Refined boundaries are kept as `[Double]` in seconds and used both for FFmpeg splitting and for offset arithmetic during result merging.

### Pass 3 — Split

One FFmpeg invocation using the segment muxer:

```
ffmpeg -i <input> -ar 24000 -ac 1 -f segment \
       -segment_times "<boundary1>,<boundary2>,...,<boundaryN-1>" \
       -map 0:a $TMPDIR/vv-<uuid>-%03d.wav
```

- Outputs `vv-<uuid>-000.wav`, `vv-<uuid>-001.wav`, ..., one per chunk.
- All chunks are 24 kHz mono Int16 PCM WAV — VibeVoice's native format.
- Effect: `VibeVoiceEngine.ensureWAV()` returns the chunk path unchanged (no second FFmpeg pass per chunk).

### Edge Cases

| Case | Behavior |
|---|---|
| Audio ≤ 450 s (threshold) | Chunker never called. STTRuntime branches to single-shot path. |
| Final chunk would be < 30 s | Drop the last target boundary so the final chunk absorbs the tail. Avoids paying chunk-overhead for a <30 s clip. |
| No silences detected anywhere | Fall back to uniform 5-min splits. Boundary cuts may land mid-word — quality degrades gracefully but transcription still completes. |
| Silence-detect errors or times out | Same fallback. Log a warning. |
| Source file has no audio stream | FFmpeg returns non-zero; chunker throws `STTError.transcriptionFailed`. Caught by STTRuntime, surfaces as the same error a single-shot would. |

## Result Assembly & Timestamps

### Per-Chunk Result

Each `engine.transcribe(chunkPath)` returns an `STTResult` whose `segments` carry timestamps **local to the chunk** (e.g., a chunk that starts at source-audio offset 305 s has segments from 0 to ~295 s).

### Merging

For each chunk `i` with refined start offset `chunkStartSec[i]`:

```swift
let offsetMs = Int(chunkStartSec[i] * 1000)
let adjusted = chunkResult.segments.map { seg in
    STTSegment(
        startMs: seg.startMs + offsetMs,
        endMs:   seg.endMs   + offsetMs,
        text:    seg.text,
        speakerId: seg.speakerId  // passed through; caveat below
    )
}
allSegments.append(contentsOf: adjusted)
```

The chunker keeps a `[Double]` of refined start offsets parallel to the chunk file paths so timestamps remain frame-accurate even when silence detection shifted a boundary by ±15 s.

### Final STTResult

```swift
STTResult(
    text: allSegments.map(\.text).joined(separator: "\n"),
    words: [],
    segments: allSegments,
    language: nil,
    engine: .vibevoice,
    engineVariant: "vibevoice-asr-q4_k-chunked"
)
```

The `-chunked` suffix on `engineVariant` lets logs, telemetry, and the database distinguish chunked output from single-shot. Single-shot stays `vibevoice-asr-q4_k`.

### Speaker IDs

Pass-through, no merging. `Speaker 0` in chunk N is **not** guaranteed to be the same person as `Speaker 0` in chunk M. For single-speaker content (the optimization target), this is irrelevant. The UI does not need a special "chunked" mode — speakers are rendered as-is.

### Empty Chunks

If a chunk produces zero segments (e.g., pure silence), it contributes nothing to `allSegments` and the loop continues with the next chunk.

## Progress Reporting

The chunker wraps the engine's `onProgress` so per-chunk percentages map to a smooth overall bar.

```swift
for (chunkIndex, chunkPath) in chunks.enumerated() {
    let perChunkProgress: (@Sendable (Int, Int) -> Void)? = onProgress.map { outer in
        { localPct, _ in
            let overall = (chunkIndex * 100 + localPct) / totalChunks
            outer(overall, 100)
        }
    }
    let result = try await engine.transcribe(
        audioPath: chunkPath, job: job, onProgress: perChunkProgress
    )
    // merge result
}
// after loop
onProgress?(100, 100)
```

### Behavior

- During chunk 0 inference: outer bar moves from 0 % to `(0*100 + 99)/M = 16` % (for M=6).
- Chunk 0 completes, engine fires `(100, 100)` → outer bar at `(0*100 + 100)/6 = 16` %.
- Chunk 1 starts, fires `(0, 100)` → outer bar at `(1*100 + 0)/6 = 16` %. No reset, no visible jitter.
- All chunks complete → chunker fires `(100, 100)` explicitly.

### FFmpeg Phase

Bar stays at **0 %** during the ~30 s of silence detection + splitting before inference begins. No callback fires. For a 30-min file that's ~3 % of total wall time at 0 % — acceptable "starting up" feel.

### Cancellation

If the parent task is cancelled mid-chunk, the inner `engine.transcribe` propagates `CancellationError` from its next progress-timer tick or from the C ABI returning. The chunker's `defer` removes temp chunks. The error bubbles up.

## STTRuntime Integration

The branch lives in `transcribeWithVibeVoice`:

```swift
private func transcribeWithVibeVoice(
    audioPath: String,
    job: STTJobKind,
    onProgress: (@Sendable (Int, Int) -> Void)?
) async throws -> STTResult {
    let engine = vibevoiceEngine ?? VibeVoiceEngine()
    if vibevoiceEngine == nil { vibevoiceEngine = engine }

    let audioSec = (try? Self.audioDuration(at: URL(fileURLWithPath: audioPath))) ?? 0
    if audioSec > Self.vibevoiceChunkThresholdSec {
        let chunked = chunkedTranscriber ?? VibeVoiceChunkedTranscriber(engine: engine)
        if chunkedTranscriber == nil { chunkedTranscriber = chunked }
        return try await chunked.transcribe(audioPath: audioPath, job: job, onProgress: onProgress)
    } else {
        return try await engine.transcribe(audioPath: audioPath, job: job, onProgress: onProgress)
    }
}

private static let vibevoiceChunkThresholdSec: Double = 450.0  // 7.5 min
```

- One `VibeVoiceChunkedTranscriber` is held as a member alongside `vibevoiceEngine`. Lazily created on first long-form call.
- Threshold is a `private static` constant. Not exposed.
- `audioDuration(at:)` is promoted from a private static in `VibeVoiceEngine` to a shared utility (probably on `AudioFileConverter` or as a top-level function in `MacParakeetCore/Audio`). The existing usage in `VibeVoiceEngine` then references the shared helper.

## CLI / GUI Parity

Both surfaces use `STTRuntime.transcribe(...)` and thus get the chunking branch transparently. No CLI flag added. No GUI setting added. The `engineVariant` field in the resulting `STTResult` ("vibevoice-asr-q4_k" vs "vibevoice-asr-q4_k-chunked") is the only outward signal that chunking happened — visible in `transcribe --format json` output and in the database.

## Testing Strategy

### Pure-Function Unit Tests (No Model, No FFmpeg, No Temp Files)

| Function | Purpose | Tests |
|---|---|---|
| `parseSilenceIntervals(_ ffmpegStderr: String) -> [ClosedRange<Double>]` | Parses `silencedetect` stderr lines | Canned FFmpeg outputs, malformed lines ignored, empty input |
| `refineBoundaries(targets:silences:windowSec:) -> [Double]` | Snaps targets to mid-silence within window | No silences, silence outside window, multiple silences in window, exact-target edge |
| `computeChunkPlan(audioSec:chunkLengthSec:minTailSec:) -> [Double]` | Computes target boundaries with final-tail-merge | Audio just above threshold, audio with 31 s tail (kept), audio with 29 s tail (merged) |
| `mergeSegments(chunkOffsets:perChunkSegments:) -> [STTSegment]` | Offsets timestamps and concatenates | Empty chunks contribute nothing, speaker IDs pass through, boundary segments stay distinct |
| `overallProgress(chunkIndex:localPct:totalChunks:) -> Int` | Section 4 progress math | Monotonicity check across all chunk transitions, end at exactly 100 |

### Orchestration Tests with a Fake Engine

`STTTranscribing` is already a protocol in `Sources/MacParakeetCore/STT/STTClientProtocol.swift`. A test-only `FakeVibeVoiceTranscribing` returns pre-canned `[DiarizedSegment]` per chunk path.

Tests:
- Merged `STTResult` matches the expected concatenation of fake chunk results.
- `engineVariant` is exactly `"vibevoice-asr-q4_k-chunked"`.
- Progress callbacks are monotonic and end at `(100, 100)`.
- A throwing fake chunk causes the chunker to throw (fail-all policy).
- `defer` cleanup removes all temp chunks on success, on throw, and on cancellation.

### Integration Tests with Real FFmpeg (No Model)

Requires the bundled FFmpeg to be available at the path returned by `BinaryBootstrap`.

- Silence-detect against a synthetic WAV with known silences at known positions → assert detected intervals.
- Split a 10-min synthetic WAV at refined boundaries → assert N output files at expected durations.

### Manual End-to-End (Gated, Model Required)

- 5-min real audio with the model loaded, run through chunker with `chunkLengthSec=120` to force 3 chunks → verify merged transcript fuzzy-matches a known-good reference.
- 30-min Marc Penna fitness video through the GUI → wall time ≤ 25 min, bar moves smoothly, transcript complete.

### What We Explicitly Do Not Test Automatically

- Real-world RTF on the 30-min Marc Penna video (manual).
- Memory pressure / KV cache behavior across chunks (manual diagnostic via timing logs).
- GUI progress bar visual smoothness (manual; the math is unit-tested).

### Fixture Additions

- `Tests/MacParakeetCoreTests/STT/Fixtures/silence_at_known_positions.wav` — 60 s synthetic WAV with silence at 20-22 s and 40-42 s for silence-detect tests.
- `Tests/MacParakeetCoreTests/STT/Fixtures/two_chunk_reference.json` — expected merged result for the fuzzy-match e2e test.

## Open Questions for the Plan Phase

These are decisions that don't affect the architecture but need to be made before implementation:

1. **Threshold tuning.** 450 s (7.5 min) is the proposed cutoff. It's 1.5× chunk length, so we never produce a tiny final chunk. Could go higher (e.g., 600 s) if we want to keep more files on the single-shot path. **Recommended default: 450 s.**

2. **Silence-detect parameters.** -30 dB / 0.3 s are starting points. May need tuning if real-world workout videos with background music don't produce enough silence candidates. **Recommended default: -30 dB / 0.3 s; revisit after first real-world test.**

3. **Where to place `audioDuration(at:)`.** Currently private static in `VibeVoiceEngine`. Options: (a) duplicate in chunker, (b) promote to `AudioFileConverter`, (c) new `AudioDuration.swift` utility. **Recommended: (b) — `AudioFileConverter.audioDuration(at:)`.**

4. **OSLog category for chunker.** New category `VibeVoiceChunkedTranscriber` under existing subsystem `com.macparakeet.vibevoice`. **Recommended: yes.**

## Rollout

1. Implement behind the existing engine selection — no flag, no opt-in. Users who pick VibeVoice get chunked behavior automatically for long audio.
2. Telemetry: the existing `STTResult.engineVariant` distinguishes chunked vs single-shot in the database, so adoption is queryable without new fields.
3. Documentation update: README + `docs/architecture/stt/` add a one-paragraph note that VibeVoice long-form is chunked transparently above 7.5 min.

## Success Criteria

- 30-min Marc Penna video transcribes end-to-end via VibeVoice in ≤ 25 min wall time.
- Progress bar moves continuously and ends at 100 %.
- Output transcript is complete and timestamps are correct relative to the source audio.
- Single-shot path for short audio (≤ 7.5 min) is unchanged — no regressions on existing VibeVoice short-form behavior.
- All unit tests pass without the model installed.
