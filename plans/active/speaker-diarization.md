# Speaker Diarization Implementation Plan

> Status: **ACTIVE**

## Overview

Add speaker diarization to file transcription and YouTube transcription using FluidAudio's offline diarization pipeline (pyannote community-1 + WeSpeaker v2 + VBx clustering). See ADR-010 for the full decision record.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pipeline | FluidAudio offline (OfflineDiarizerManager) | Best accuracy (~15% DER), unlimited speakers, already in our dependency |
| Scope | File + YouTube transcription only | Dictation is single-speaker |
| Speaker data storage | Stable IDs (`"S1"`) on `WordTimestamp.speakerId`, structured `speakers` mapping + `diarizationSegments` on `Transcription` | Stable IDs avoid O(n) rewrite on rename; segments enable accurate analytics |
| Diarization failure | Non-fatal — ASR result persisted even if diarization fails | Never lose transcription due to diarization error |
| Always-on | Yes for file transcription (Option-key alternate to skip) | Users transcribing files almost always want speaker attribution; power users get per-run escape hatch |
| Cross-file identity | Not supported | Per-transcription speaker IDs only |
| ASR + diarization ordering | Sequential (ASR first, then diarization) | Simpler, correctness over speed. Optimize to parallel later if needed. |

## Implementation Steps

### Phase 1: Core Pipeline

#### 1.1 Update data model

**File:** `Sources/MacParakeetCore/Models/Transcription.swift`

Add `speakerId: String?` to `WordTimestamp` storing **stable raw IDs** from the diarization pipeline (`"S1"`, `"S2"`), not display labels. This means rename only touches the `speakers` mapping, not every word.

```swift
public struct WordTimestamp: Codable, Sendable {
    public var word: String
    public var startMs: Int
    public var endMs: Int
    public var confidence: Double
    public var speakerId: String?  // v0.4 diarization — stable ID e.g. "S1" (not display label)
}
```

Change `speakers` from `[String]?` to a structured mapping:

```swift
public struct SpeakerInfo: Codable, Sendable {
    public var id: String       // Stable ID from diarization: "S1", "S2"
    public var label: String    // Display label: "Speaker 1" (default) or user-assigned name e.g. "Sarah"
}

// On Transcription:
var speakers: [SpeakerInfo]?          // replaces [String]?
var diarizationSegments: [DiarizationSegmentRecord]?  // NEW: raw segments for analytics
```

Add `diarizationSegments` to persist raw diarization output:

```swift
public struct DiarizationSegmentRecord: Codable, Sendable {
    public var speakerId: String   // "S1", "S2"
    public var startMs: Int
    public var endMs: Int
}
```

**Database migration:** `diarizationSegments` requires a new column (v0.4 migration in `spec/01-data-model.md`). `wordTimestamps` and `speakers` are existing JSON columns — new/changed fields are nullable and Codable handles backward compatibility automatically (missing key = nil).

**Backward compatibility for `speakers` field:** The column changes from `["Speaker 1","Speaker 2"]` to `[{"id":"S1","label":"Speaker 1"},...]`. Since no production transcriptions have diarization data yet (v0.4 feature), this is safe. Add a custom `Decodable` init that handles both formats defensively — try `[SpeakerInfo]` first, fall back to `[String]` and convert to `SpeakerInfo` with generated IDs.

#### 1.2 Create DiarizationService

**File:** `Sources/MacParakeetCore/Services/DiarizationService.swift`

New service that wraps FluidAudio's `OfflineDiarizerManager`:

```swift
protocol DiarizationServiceProtocol: Sendable {
    func diarize(audioURL: URL) async throws -> DiarizationResult
    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
}
```

**DiarizationResult** (our domain type, not FluidAudio's):

```swift
struct SpeakerSegment: Sendable {
    let speakerId: String       // Stable ID: "S1", "S2" (raw from pipeline)
    let startMs: Int
    let endMs: Int
}

struct DiarizationResult: Sendable {
    let segments: [SpeakerSegment]
    let speakerCount: Int
    let speakers: [SpeakerInfo]  // [SpeakerInfo(id: "S1", label: "Speaker 1"), ...]
}
```

Implementation:
- Lazy-init `OfflineDiarizerManager` on first call
- Map FluidAudio's `TimedSpeakerSegment` → our `SpeakerSegment`
- **Speaker ID normalization:** FluidAudio returns `"speaker_0"`, `"speaker_1"`, etc. Normalize to `"S1"`, `"S2"` via simple mapping: `"speaker_\(i)" → "S\(i+1)"`
- Build `SpeakerInfo` array with default display labels (`"Speaker 1"`, `"Speaker 2"`, ...) derived from normalized IDs
- Convert `startTimeSeconds`/`endTimeSeconds` (Float, seconds) to `startMs`/`endMs` (Int, milliseconds): `Int(seconds * 1000)`
- **Handle `noSpeechDetected` error** — catch and return empty result (not a fatal error)

#### 1.3 Create timestamp merger

**File:** `Sources/MacParakeetCore/Services/SpeakerMerger.swift`

Pure function that merges ASR word timestamps with diarization speaker segments:

```swift
func mergeWordTimestampsWithSpeakers(
    words: [WordTimestamp],
    segments: [SpeakerSegment]
) -> [WordTimestamp]
```

Algorithm (two-pointer linear merge, O(W+S)):
- Both `words` and `segments` are sorted by start time
- Advance a segment pointer as words progress through time
- For each word, find the diarization segment with the most time overlap
- Assign that segment's `speakerId` to the word
- Words with no overlapping segment get `speakerId = nil` (this happens in silence gaps and overlapping speech regions where the offline pipeline trims output)
- **Tie-breaking:** if a word overlaps two segments equally, assign the earlier segment (deterministic)

**Nil-word UI behavior:** Words with `speakerId = nil` are grouped with the preceding speaker turn for display. In exports, they appear under the last known speaker. This avoids visual fragmentation from short unlabeled gaps.

**Type conversion note:** ASR returns `TimestampedWord` (from `STTResult`), but our model uses `WordTimestamp`. The conversion happens in `TranscriptionService` when building the transcription record — this is existing code, not new.

This is a pure function — easy to test with fixture data.

#### 1.4 Integrate into TranscriptionService

**File:** `Sources/MacParakeetCore/Services/TranscriptionService.swift`

After ASR completes, run diarization and merge. **Diarization is non-fatal** — ASR result is always persisted.

```swift
// Existing: ASR
let sttResult = try await sttClient.transcribe(audioPath: path)

// Persist ASR result immediately (diarization must not block this)
transcription.wordTimestamps = sttResult.words.map { ... } // TimestampedWord → WordTimestamp
transcription.rawTranscript = sttResult.text

// New: Diarization (non-fatal)
do {
    let diarizationResult = try await diarizationService.diarize(audioURL: url)

    // Merge speaker IDs into word timestamps
    let mergedWords = SpeakerMerger.mergeWordTimestampsWithSpeakers(
        words: transcription.wordTimestamps!,
        segments: diarizationResult.segments
    )

    transcription.wordTimestamps = mergedWords
    transcription.speakerCount = diarizationResult.speakerCount
    transcription.speakers = diarizationResult.speakers
    transcription.diarizationSegments = diarizationResult.segments.map { ... } // → DiarizationSegmentRecord
} catch {
    // Diarization failed — log and continue with ASR-only result
    logger.warning("Diarization failed: \(error). Continuing with ASR-only transcript.")
    // speakerCount, speakers, diarizationSegments remain nil
}
```

**Critical:** Both ASR and diarization must run on the **same audio file path** to ensure timestamp alignment. Do not re-convert or trim audio between the two calls.

**Progress reporting:** Show "Transcribing..." during ASR, then "Identifying speakers..." during diarization. These are separate visible phases in the UI. During the diarization phase, show a sublabel: *"Adds ~30-60s per hour of audio"* to set expectations (indeterminate progress, no callback from FluidAudio).

### Phase 2: Onboarding

#### 2.1 Download diarization models during onboarding

**File:** `Sources/MacParakeetViewModels/OnboardingViewModel.swift`

Add diarization model download step after ASR model download:

```
Step 1: Permissions (mic, accessibility)
Step 2: Download ASR models (~6 GB)      ← existing
Step 3: Download diarization models (~130 MB)  ← new
Step 4: Verify / warm-up
```

Use `OfflineDiarizerManager.prepareModels()` which handles download + CoreML compilation.

### Phase 3: UI

#### 3.0 Progress UX and skip-diarization alternate

**Progress during file transcription:**

Two visible phases with clear labels:

```
Phase 1: "Transcribing..."              ← determinate progress (ASR)
Phase 2: "Identifying speakers..."      ← indeterminate spinner
          Adds ~30-60s per hour of audio   ← sublabel (secondary text, muted color)
```

The sublabel during phase 2 sets expectations without being alarming. No tooltip or info icon needed — the sublabel is sufficient.

**Option-key alternate (skip diarization):**

Power users who want maximum speed can hold Option (⌥) to get a "fast, no speakers" transcription. This is a per-run escape hatch, not a global setting.

| Surface | Default action | Option-key alternate |
|---------|---------------|---------------------|
| Drop zone | "Transcribe" | "Transcribe (No Speakers)" |
| Menu bar drop | Transcribe with diarization | Transcribe without diarization |
| Context menu | "Transcribe File..." | "Transcribe File (Fast, No Speakers)" |

Implementation:
- Check `NSEvent.modifierFlags.contains(.option)` at transcription start
- If Option held, skip the `diarizationService.diarize()` call entirely
- All speaker fields remain nil — transcript displays without speaker attribution
- No UI change needed for the result view (already handles nil speaker data gracefully)

**No global toggle in Settings.** This keeps the settings surface clean and avoids the "why don't I see speakers?" support burden.

**Future (F14 Batch):** Batch processing can expose a per-batch "Skip speaker detection" checkbox in the queue header, since batch is already an advanced context.

#### 3.1 Speaker labels in transcript view

**File:** `Sources/MacParakeet/Views/Transcription/TranscriptTextView.swift` (or equivalent)

Display speaker labels as colored headers before each speaker turn:

```
Speaker 1 (Sarah)
The advancement in cloud native technology has been remarkable...

Speaker 2 (Interviewer)
Can you tell us more about the scheduling changes?
```

- Group consecutive words by `speakerId` into speaker turns
- Assign colors from a fixed palette (DesignSystem tokens)
- Show speaker label at each turn change

#### 3.2 Speaker rename

Allow clicking a speaker label to rename (e.g., "Speaker 1" → "Sarah"):

- Update the `label` field in the matching `SpeakerInfo` entry in `Transcription.speakers`
- **No word rewrite needed** — `WordTimestamp.speakerId` stores stable IDs (`"S1"`), display labels come from the `speakers` mapping
- Persist via `TranscriptionRepository.update()` — single field update, O(1)

#### 3.3 Speaker summary panel

Show per-speaker analytics at the top of the transcript:

- Speaking time (seconds/percentage)
- Word count
- Color swatch

**Speaking time** computed from `diarizationSegments` — group by `speakerId`, sum segment durations. This is more accurate than summing word durations (word timestamps have gaps between words that aren't silence).

**Word count** computed from `wordTimestamps` — group by `speakerId`, count words.

**Display labels** resolved via the `speakers` mapping (stable ID → display label).

### Phase 4: Export

#### 4.1 Update all export formats

**File:** `Sources/MacParakeetCore/Services/ExportService.swift`

When `speakerCount > 0`, include speaker labels. Resolve display labels from `speakers` mapping.

**Critical:** SRT/VTT cues that span a speaker boundary must be **split at the speaker change**. Do not simply prefix a single speaker label onto a multi-speaker cue — that produces incorrect output.

**Implementation:** Add `speakerChanged` as a split condition in `buildSubtitleCues()` alongside existing conditions (punctuation, long gap, word count, duration):

```swift
let speakerChanged = (i > 0 && words[i].speakerId != words[i-1].speakerId)
if isLast || endsWithPunctuation || hasLongGap || tooManyWords || tooLong || speakerChanged {
    emitCue()
}
```

| Format | Speaker format |
|--------|---------------|
| TXT | `Sarah:\n` before each turn |
| Markdown | `**Sarah:**\n` before each turn |
| SRT | Split cues at speaker changes; `Sarah: subtitle text` on each cue |
| VTT | Split cues at speaker changes; `<v Sarah>subtitle text</v>` per WebVTT spec |
| DOCX | Bold speaker name before each turn |
| PDF | Bold speaker name before each turn |
| JSON | `speakerId` (stable ID) on each word; `speakers` mapping in metadata |

### Phase 5: Tests

#### 5.1 Unit tests

- `SpeakerMergerTests`: Test merge algorithm with various scenarios (exact overlap, partial overlap, no overlap, single speaker, many speakers, empty inputs)
- `DiarizationServiceTests`: Test protocol contract with mock (similar to STT tests)
- `ExportServiceTests`: Test speaker labels in each export format

#### 5.2 Integration tests

- `TranscriptionServiceTests`: Test full pipeline (ASR + diarization + merge) with mock services
- `TranscriptionServiceTests`: Test diarization failure is non-fatal (ASR result persisted, speaker fields nil)
- Verify `WordTimestamp` JSON encoding/decoding with and without `speakerId`
- Verify `speakers` backward compatibility: old `["Speaker 1"]` format decodes correctly alongside new `[{"id":"S1","label":"Speaker 1"}]` format
- Verify `ExportService` SRT/VTT cue splitting at speaker boundaries (speaker change mid-cue, at punctuation, at gap)

## Files Changed (Expected)

| Action | File | Notes |
|--------|------|-------|
| Edit | `Sources/MacParakeetCore/Models/Transcription.swift` | Add `speakerId` to `WordTimestamp`, `SpeakerInfo` struct, `DiarizationSegmentRecord`, update `speakers` type |
| Add | `Sources/MacParakeetCore/Services/DiarizationService.swift` | New service wrapping FluidAudio |
| Add | `Sources/MacParakeetCore/Services/SpeakerMerger.swift` | Pure merge function |
| Edit | `Sources/MacParakeetCore/Services/TranscriptionService.swift` | Integrate diarization after ASR |
| Edit | `Sources/MacParakeetCore/Services/ExportService.swift` | Speaker labels in all formats |
| Edit | `Sources/MacParakeetViewModels/OnboardingViewModel.swift` | Diarization model download step |
| Edit | `Sources/MacParakeetViewModels/TranscriptionViewModel.swift` | Speaker rename, analytics |
| Edit | `Sources/MacParakeet/Views/Transcription/` | Speaker UI (labels, colors, rename) |
| Add | `Tests/MacParakeetTests/Services/SpeakerMergerTests.swift` | Merge algorithm tests |
| Add | `Tests/MacParakeetTests/Services/DiarizationServiceTests.swift` | Service protocol tests |
| Edit | `Tests/MacParakeetTests/Services/ExportServiceTests.swift` | Speaker export tests |
| Edit | `Tests/MacParakeetTests/Models/TranscriptionModelTests.swift` | speakerId encoding tests |

## Dependencies

- FluidAudio 0.12.1 (already in Package.swift) — no changes needed
- `OfflineDiarizerManager`, `OfflineDiarizerConfig`, `OfflineDiarizerModels` — all in `FluidAudio` product

## Risks

| Risk | Mitigation |
|------|------------|
| Diarization failure (noSpeechDetected, model error) | Non-fatal: persist ASR result, show notice, leave speaker fields nil |
| Diarization accuracy on short clips (<30s) | Test with various lengths; document minimum recommended. Default `minSegmentDurationSeconds=1.0` drops short backchannels — accept this tradeoff. |
| Model download failure during onboarding | Retry logic + clear error message (same pattern as ASR models) |
| Large files (2+ hours) memory pressure | Use `manager.process(url)` (file-based, memory-mapped) not in-memory arrays |
| Large files — JSON blob size | `wordTimestamps` and `diarizationSegments` can be large for 2+ hour files. Monitor DB write time. |
| Speaker count mismatch expectations | Show "1 speaker detected" gracefully for single-speaker files |
| Overlapping speech → nil speakerId | Offline pipeline trims overlaps by default (`embeddingExcludeOverlap`). Words in overlap zones get nil. UI groups nil words with preceding speaker. |
| Timestamp misalignment ASR vs diarization | Both must run on the same audio file path — enforce in TranscriptionService |
| SRT/VTT cues spanning speaker changes | Must split cues at speaker boundaries, not just prefix labels |
| Progress reporting during diarization | `OfflineDiarizerManager.process()` doesn't provide progress callbacks. Use indeterminate progress with "Identifying speakers..." label. |
