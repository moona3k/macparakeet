# Speaker Diarization Quality Plan

> Status: ACTIVE PLAN
> Date: 2026-05-27 (refreshed 2026-06-14 against FluidAudio 0.15.2)
> Review: revised after two ChatGPT Pro reviews and local fresh-eye review to
> reduce overengineering and avoid brittle heuristics. The 2026-06-14 refresh
> re-grounds "Verified Current State" against the now-pinned FluidAudio 0.15.2
> (was 0.14.5), promotes the evaluation harness to the first implemented slice
> (measure before changing behavior), and folds the newly-exposed per-segment
> `qualityScore` and speaker embeddings into Phases 2 and 5.
> Scope: speaker diarization accuracy, speaker-to-word attribution, local
> diagnostics, and minimal speaker-label provenance. This is separate from the
> meeting echo-suppression plan, which targets audio bleed into the microphone
> path.

## Problem

MacParakeet already has the right meeting foundation: microphone and system
audio are retained as separate sources, final meeting transcription is
source-aware, and speaker diarization only refines the isolated system track.
The remaining quality gap is narrower:

- remote speakers inside `Others` can be collapsed, over-split, swapped, or
  attached to the wrong words
- known speaker counts are not passed into FluidAudio even though the pinned
  offline pipeline supports them
- word-to-speaker reconciliation is strict-overlap only, so small ASR/diarizer
  timestamp drift can leave system words source-only
- the app has no content-free report for a fresh diarization run
- speaker rename is label-only; it does not record whether a label came from
  the model default or a user correction

The goal is not to replace the local diarizer by default. The goal is to make
MacParakeet use the best available local-first diarization path by adding
constraints, conservative reconciliation, and honest diagnostics around the
current FluidAudio offline pipeline.

## Verified Current State

- `Package.resolved` now pins FluidAudio `0.15.2`
  (`7f963cdc43ba89c5993654f1e138047d517a818d`), via
  `.upToNextMinor(from: "0.15.2")`. This plan was originally written against
  `0.14.5`; the bullets below are re-verified against the 0.15.2 source checked
  out under `.build/checkouts/FluidAudio`.
- `DiarizationService` exposes `diarize(audioURL:)` (no per-call options). It is
  constructed either with `config: .default` or, for the CLI file/URL path, with
  `init(speakerConstraint:)` — so speaker-count hints are wired only at
  construction time today, never per call, and never for the meeting path.
- FluidAudio `0.15.2` still exposes speaker-count constraints through
  `OfflineDiarizerConfig.Clustering` (`numSpeakers`, `minSpeakers`,
  `maxSpeakers`); the code surfaces these via `OfflineDiarizerConfig`
  `withSpeakers(exactly:)` / `withSpeakers(min:max:)`. FluidAudio resolves them
  inside the offline VBx clustering path and may clamp to the available
  embedding count. A requested hint is not proof the result is correct.
- NEW in 0.15.2 (not available when this plan was first written):
  `TimedSpeakerSegment` now carries a per-segment `embedding: [Float]` (256-dim,
  L2-normalized) and a `qualityScore: Float`; `DiarizationResult` adds
  `speakerDatabase: [String: [Float]]?` (per-file centroids) and, behind the
  `exposeChunkEmbeddings` config flag, `chunkEmbeddings: [ChunkEmbedding]?`
  (256-dim WeSpeaker + 128-dim PLDA `rho128`). `OfflineDiarizerManager.process`
  also gained a `progressCallback`. `DiarizationService.diarize` currently
  DISCARDS all of this — our `SpeakerSegment` carries only
  `{ speakerId, startMs, endMs }`.
- `TranscriptionService.transcribeMeetingAudio` diarizes only the system WAV
  and maps results into source-prefixed IDs such as `system:S1`.
- `MeetingTranscriptFinalizer` keeps microphone words as `microphone` / `Me`
  and only refines system words when system diarization exists.
- `SpeakerMerger.mergeWordTimestampsWithSpeakers` assigns speaker IDs by max
  direct overlap only. No overlap leaves the original word speaker/source
  unchanged.
- `SpeakerInfo` currently stores only `{ id, label }`. Renaming a speaker
  updates the `speakers` JSON but does not store whether the label came from
  the model default or the user.

## FluidAudio 0.15.2 Capability Delta (2026-06-14)

The version bump since this plan was drafted changes what is *possible*, and in
two places changes the recommended design:

1. Per-segment `qualityScore` is a principled confidence gate. Phase 2's
   conservative fallback was designed around hand-tuned millisecond tolerances
   because the model gave no confidence signal. It now does. Phase 2 should gate
   fallback assignment on `qualityScore` in addition to the gap/ambiguity
   heuristics, and surface `qualityScore` through `SpeakerSegment` so both the
   assigner and the eval report can see it. The 250 ms / 150 ms tolerances stay
   as a backstop, not the primary signal.

2. Speaker embeddings are now extractable (`speakerDatabase`, `chunkEmbeddings`,
   `TimedSpeakerSegment.embedding`) and FluidAudio ships a known-speaker
   enrollment API (`Speaker` + `initializeKnownSpeakers`). This makes
   cross-meeting speaker identity ("name Alice once, recognize her next week")
   technically feasible locally — which ADR-010 had ruled out partly because the
   API did not surface vectors. This stays OUT OF SCOPE for this plan: voice
   embeddings are biometric data and require a separate opt-in privacy ADR before
   any persistence. Captured here only so the door is known to be open.

3. Streaming diarizers (`LSEENDDiarizer`, `SortformerDiarizer`) are public, so
   live speaker labels in the meeting preview are now feasible. Also deferred —
   batch quality and the eval harness come first, and live labels need their own
   quality bar.

Net effect on this plan: (a) the evaluation harness moves to the first
implemented slice so every later change is measured, not asserted; (b) Phase 2
gains a real confidence input (`qualityScore`); (c) two larger, ADR-gated bets
are named but explicitly not built here.

## Non-Goals

- Do not change the default local-first behavior.
- Do not upload audio for diarization without a separate explicit privacy ADR
  and user opt-in.
- Do not treat calendar attendees as speaker identity truth.
- Do not solve microphone/system audio bleed here; that belongs to
  `2026-05-meeting-neural-echo-suppression.md`.
- Do not replace the current `Me` / `Others` source model. Improve it by
  splitting and labeling `Others` better.
- Do not make speaker identity biometric or cross-meeting by default.
- Do not add user-facing quality profiles until local evidence shows which
  FluidAudio knobs are worth exposing.
- Do not ship a stored-meeting `diarization-report` command until raw diarizer
  output and assignment summaries are persisted. Current stored
  `diarizationSegments` are word-derived display segments, not raw provider
  output.

## Design Principles

1. Preserve source attribution before diarization.
   Microphone remains the user's channel. System audio is the remote channel.
   Diarization refines the remote channel; it does not decide who is `Me`.

2. Treat diarization output as evidence, not final truth.
   Raw model speaker IDs, source IDs, user-facing labels, and assignment
   methods must not be collapsed into one ambiguous concept.

3. Prefer no speaker assignment over a confident wrong assignment.
   The reconciliation fallback must be conservative and ambiguity-aware.

4. Make fresh-run quality observable without pretending to know ground truth.
   Reports should expose requested hints, detected counts, assignment method
   counts, and coverage symptoms. They should not claim to diagnose clustering
   vs timestamp drift unless raw state proves that distinction.

5. Keep corrections reversible.
   User labels should not rewrite words or destroy raw diarizer IDs.

## Phase 0: Tighten Speaker Identity Helpers

Before adding options or reports, centralize the source-prefixed ID behavior so
future code does not rely on scattered string prefix checks.

Add a small Core helper:

```swift
enum SpeakerID {
    static func systemSpeaker(_ stableID: String) -> String
    static func source(for speakerID: String?) -> AudioSource?
    static func isSourceOnly(_ speakerID: String?) -> Bool
}
```

Rules:

- `"microphone"` maps to `.microphone`
- `"system"` maps to `.system`
- `"system:<stable-id>"` maps to `.system`
- plain `"S1"` is valid for non-meeting file/URL diarization but has no
  meeting source unless explicitly wrapped by the meeting path

This keeps the current storage shape but makes the source-vs-speaker convention
searchable and testable.

### Tests

- microphone source ID
- system source-only ID
- system diarized ID
- plain file speaker ID
- nil ID

## Phase 1: Speaker Count Hints

Wire speaker-count constraints into the local offline pipeline.

### Public Core API

Add only the option we need now:

```swift
public struct DiarizationOptions: Sendable, Equatable {
    public var speakerCountHint: SpeakerCountHint?

    public static let `default` = Self()

    public init(speakerCountHint: SpeakerCountHint? = nil) {
        self.speakerCountHint = speakerCountHint
    }
}

public struct SpeakerCountHint: Sendable, Codable, Equatable {
    public var exact: Int?
    public var minimum: Int?
    public var maximum: Int?
}
```

Do not add `qualityProfile` yet. That would create API surface before the
evaluation harness proves which profile knobs matter.

### Validation

- all values must be positive
- `exact` cannot be combined with `minimum` or `maximum`
- `minimum <= maximum` when both are provided
- meeting hints describe remote/system speakers only, not total attendees

Validation belongs in Core, not only in the CLI or future UI. Call the Core
validator from `DiarizationService.diarize(audioURL:options:)` before manager
creation so every caller gets the same guardrail.

Fail fast when user intent is invalid. Do not rely on FluidAudio's internal
clamping as user-facing validation.

### Protocol Shape

Extend the existing protocol so options cannot be silently ignored. Keep the
existing model lifecycle methods (`prepareModels`, `isReady`, `hasCachedModels`)
on the protocol; the important change is that the options-taking `diarize`
method is the required method.

```swift
public protocol DiarizationServiceProtocol: Sendable {
    func diarize(
        audioURL: URL,
        options: DiarizationOptions
    ) async throws -> MacParakeetDiarizationResult

    func prepareModels(onProgress: (@Sendable (String) -> Void)?) async throws
    func isReady() async -> Bool
    func hasCachedModels() async -> Bool
}

public extension DiarizationServiceProtocol {
    func diarize(audioURL: URL) async throws -> MacParakeetDiarizationResult {
        try await diarize(audioURL: audioURL, options: .default)
    }
}
```

Do not add a default implementation of the options-taking method that calls the
old method. That would allow mocks or alternate services to ignore hints while
tests still pass.

### Config Mapping

Preserve the injected base config. Do not rebuild from
`OfflineDiarizerConfig.Clustering.community`, because that would discard any
custom config passed to `DiarizationService.init(config:)`.

```swift
var config = baseConfig
if let hint = options.speakerCountHint {
    if let exact = hint.exact {
        config.clustering.numSpeakers = exact
        config.clustering.minSpeakers = nil
        config.clustering.maxSpeakers = nil
    } else {
        config.clustering.numSpeakers = nil
        config.clustering.minSpeakers = hint.minimum
        config.clustering.maxSpeakers = hint.maximum
    }
}
```

### Manager Ownership

The current service stores one immutable manager. Speaker-count hints require a
manager/config refactor, not only an extra argument.

Prefer this first-pass shape:

```swift
private let baseConfig: OfflineDiarizerConfig
private let makeManager: @Sendable (OfflineDiarizerConfig) -> any OfflineDiarizerManaging
```

For each run:

1. validate `DiarizationOptions`
2. copy `baseConfig`
3. apply speaker-count hints
4. create a manager from the resolved config
5. call `prepareModels(at:)` on that manager before processing

Do not rely on the actor's old `modelsReady` flag for newly-created managers.
Disk cache can make model loading cheap, but a fresh manager still needs to be
prepared. If profiling later shows per-run manager creation is too slow, add a
small cache keyed only by normalized speaker-count hints. Do not key a cache by
full `OfflineDiarizerConfig` unless the config is made intentionally `Hashable`.

Tests should use a spy factory to prove exact/min/max hints reach the resolved
FluidAudio config.

### CLI

Add file/URL transcription flags:

```text
--speaker-count <n>
--speaker-min <n>
--speaker-max <n>
```

Rules:

- these flags imply speaker detection for the run when speaker detection is
  `app-default`
- reject speaker-count flags combined with explicit `--speaker-detection off`
  or `--no-diarize`
- reject `--speaker-count` combined with `--speaker-min` or `--speaker-max`
- reject invalid bounds before any transcription starts
- include requested hints in the fresh-run report

### Transcription Integration Surface

Thread per-run diarization options through `TranscriptionService` explicitly;
do not read them from global state or stash them on the service instance.

Add a small result-bearing path for fresh runs that need diagnostics:

```swift
public struct TranscriptionRunOptions: Sendable, Equatable {
    public var diarizationOptions: DiarizationOptions
    public var includeDiarizationReport: Bool
}

public struct TranscriptionRunResult: Sendable {
    public var transcription: Transcription
    public var diarizationQualityReport: DiarizationQualityReport?
}
```

Existing UI/protocol methods can keep returning `Transcription` by calling the
options-taking path with defaults and discarding the report. The CLI should use
the result-bearing path when speaker-count hints or `--diarization-report` are
present. Do not persist the report on `Transcription` or in the database in the
first pass.

### Meeting UI

Defer meeting UI for speaker-count hints until the Core/CLI path has evidence.
Users may enter attendee count instead of active remote speaker count; the UI
needs careful wording and should not be part of the first implementation.

## Phase 2: Conservative Word-to-Speaker Assignment

Add a pure assigner that returns both words and assignment stats. Keep
`SpeakerMerger` as a temporary compatibility wrapper if needed, but route new
production code through `SpeakerWordAssigner`.

```swift
public struct SpeakerWordAssignmentResult: Sendable, Equatable {
    public var words: [WordTimestamp]
    public var summary: WordSpeakerAssignmentSummary
}

public struct WordSpeakerAssignmentSummary: Codable, Sendable, Equatable {
    public var totalWords: Int
    public var directOverlapWords: Int
    public var fallbackNearestWords: Int
    public var sourceOnlyWords: Int
    public var unassignedWords: Int
    public var fallbackToleranceMs: Int
    public var ambiguityMarginMs: Int
}
```

### Assignment Method

Track assignment method separately from final `speakerId`.

```swift
public enum WordSpeakerAssignmentMethod: String, Codable, Sendable {
    case directOverlap
    case fallbackNearest
    case sourceOnly
    case unassigned
}
```

Do not infer assignment quality from `speakerId != nil`. In meetings,
`speakerId = "system"` means source-only attribution, not a diarized speaker.

### Algorithm

1. Direct max-overlap segment wins only when the best speaker clears the
   ambiguity margin over the runner-up; near ties are ambiguous.
2. If there is no overlap, compute interval boundary gap to nearby diarization
   segments.
3. Fallback only if:
   - best gap is within tolerance
   - candidate is unambiguous
   - assignment does not cross source boundaries
4. Leave meeting words source-only when the nearest candidates are ambiguous or
   too far away.

Use interval boundary gap, not midpoint distance:

```swift
if word.endMs <= segment.startMs {
    gap = segment.startMs - word.endMs
} else if segment.endMs <= word.startMs {
    gap = word.startMs - segment.endMs
} else {
    gap = 0
}
```

Initial conservative defaults:

- fallback tolerance: 250 ms
- ambiguity margin: 150 ms
- minimum segment `qualityScore` for fallback assignment (0.15.2): injectable,
  default `0.60`; below it, prefer source-only/unassigned over a low-confidence
  fallback. This is a provisional gate over FluidAudio's normalized 0...1
  segment quality and must be revisited once private fixtures produce evidence.

These values must be injectable in tests and recorded in reports. Do not expose
them in the general UI. Surfacing `qualityScore` requires adding it to
`SpeakerSegment`; see the 0.15.2 capability delta above.

### Source Policy

Keep the first assigner source-scoped rather than asking it to reason over a
mixed microphone/system word list.

Meeting system-track call shape:

```swift
assign(
    words: systemWords,
    segments: systemSegments,
    sourceOnlySpeakerId: AudioSource.system.rawValue
)
```

File/URL call shape:

```swift
assign(
    words: words,
    segments: diarizationSegments,
    sourceOnlySpeakerId: nil
)
```

Behavior:

- meeting no assignment -> keep `speakerId = "system"` and count
  `.sourceOnly`
- file/URL no assignment -> keep `speakerId = nil` and count `.unassigned`
- microphone words are never passed to a system diarization assignment call

### Tie Handling

Direct-overlap ties and near ties inside the ambiguity margin are ambiguous.
If two different speakers have effectively the same maximum overlap for a word,
leave the word source-only/unassigned rather than using array order as a hidden
tie-breaker.

### Finalizer Safety

Before true unassigned/source-only handling lands, fix
`MeetingTranscriptFinalizer.buildDiarizationSegments` so a leading unassigned
word does not cause all later segments to be dropped. It should start from the
first word that has a displayable speaker/source ID.

### Tests

- exact overlap wins
- nearest-before fallback within tolerance
- nearest-after fallback within tolerance
- no fallback across large gaps
- no fallback when two different speakers are close
- no fallback across microphone/system boundaries
- direct-overlap tie leaves a word source-only/unassigned
- direct-overlap near tie inside the ambiguity margin leaves a word
  source-only/unassigned
- source-only meeting words are counted as source-only, not assigned
- output ordering is deterministic when word start times tie
- leading unassigned/source-only words do not drop later segments

## Phase 3: Fresh-Run Diarization Report

Add a content-free report for fresh transcriptions only. Do not add
`meetings diarization-report <id>` until raw diarization segments and assignment
summaries are persisted.

### Core Type

```swift
public struct DiarizationQualityReport: Codable, Sendable, Equatable {
    public var transcriptionSourceType: Transcription.SourceType
    public var diarizedAudioSource: AudioSource?
    public var requestedSpeakerHint: SpeakerCountHint?
    public var detectedSpeakerCount: Int
    public var rawDiarizationSegmentCount: Int
    public var segmentsPerSpeaker: [String: Int]
    public var speakingTimeMsPerSpeaker: [String: Int]
    public var assignmentSummary: WordSpeakerAssignmentSummary
    public var warnings: [DiarizationQualityWarning]
}
```

The report must not include transcript text, audio paths, URLs, speaker names,
or raw word content.

### Assignment Summary Flow

Do not recompute assignment counts from final `speakerId` values. That would
reintroduce the source-vs-speaker ambiguity this plan is removing.

Thread the `WordSpeakerAssignmentSummary` produced by `SpeakerWordAssigner`
through the fresh transcription path while raw diarizer output is still in
memory. For meetings, the internal finalized result can carry:

```swift
let wordSpeakerAssignmentSummary: WordSpeakerAssignmentSummary?
```

The stored transcript does not need to persist this in the first pass unless a
stored-meeting report is added later.

### Initial Warnings

Warnings should name observable symptoms, not root-cause claims:

- `speakerCountBelowHint`
- `speakerCountAboveHint`
- `lowSystemDiarizedCoverage`
- `highFallbackAssignmentRate`
- `highSourceOnlyWordRate`

Each warning should include the threshold used in the report payload. Avoid
warnings such as `excessiveSpeakerSwitchRate` until a local fixture set proves
that the metric is useful. Rapid speaker switching may be real conversation.

Use a structured warning payload, not an enum-only list:

```swift
public struct DiarizationQualityWarning: Codable, Sendable, Equatable {
    public var kind: DiarizationQualityWarningKind
    public var observed: Double
    public var threshold: Double
    public var denominator: String?
}
```

Define denominators explicitly:

- `highFallbackAssignmentRate = fallbackNearestWords / eligibleDiarizedWords`
- `highSourceOnlyWordRate = sourceOnlyWords / totalSystemWords`
- `lowSystemDiarizedCoverage = diarizedSystemWords / totalSystemWords`

### CLI Surface

Start with:

```text
macparakeet-cli transcribe ... --diarization-report <path>
```

This report is computed while the fresh raw diarizer output and assignment
summary are still in memory.

Defer:

```text
macparakeet-cli meetings diarization-report <id>
```

That command requires persistence changes first.

## Phase 4: Minimal Speaker Label Provenance

Keep current inline rename behavior, but record where labels came from.

Extend `SpeakerInfo` with optional fields only:

```swift
public enum SpeakerLabelSource: String, Codable, Sendable {
    case modelDefault
    case user
}

public struct SpeakerInfo: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var source: AudioSource?
    public var rawProviderSpeakerId: String?
    public var labelSource: SpeakerLabelSource?
}
```

Because `speakers` is JSON and new fields are optional, this can remain
backward-compatible with existing rows.

Keep the existing source-compatible initializer shape:

```swift
public init(
    id: String,
    label: String,
    source: AudioSource? = nil,
    rawProviderSpeakerId: String? = nil,
    labelSource: SpeakerLabelSource? = nil
)
```

Behavior:

- model-created speakers use `labelSource = .modelDefault`
- user rename sets `labelSource = .user`
- raw provider IDs remain stable even after labels change
- exports continue to use display labels
- JSON output can expose raw IDs and label provenance

`rawProviderSpeakerId` should preserve the actual upstream FluidAudio ID when
available, for example `speaker_0`, not merely MacParakeet's stable display ID
`S1`. `DiarizationService` already sees the raw-to-stable mapping, so this
metadata should be attached there before meeting code wraps IDs as `system:S1`.

Meeting wrapping should be an explicit adapter, not incidental string assembly:

```swift
static func systemDiarization(from result: MacParakeetDiarizationResult)
    -> MeetingTranscriptFinalizer.SystemDiarization
```

That adapter should transform speaker IDs and segments together:

- `S1` -> `system:S1`
- `SpeakerInfo.source = .system`
- `rawProviderSpeakerId` remains the original FluidAudio speaker ID when known

Defer participant assignment fields and UI. There is no shown participant model
to anchor them cleanly, names can become stale, and participant identity is a
separate layer from speaker label provenance.

## Phase 5: Private Evaluation Harness

Add a repeatable local evaluation path before tuning thresholds or exposing
quality profiles.

Support private, untracked fixtures:

```text
fixtures/private/diarization/
  two-remote-speakers/
    system.wav
    expected.json
    reference.rttm       # optional, only when real labels exist
```

`expected.json` can start coarse:

```json
{
  "expectedRemoteSpeakers": 2,
  "minimumRemoteSpeakers": 2,
  "maximumRemoteSpeakers": 3,
  "maxSourceOnlyWordRate": 0.15,
  "notes": "Two speakers, no overlap"
}
```

The harness should:

- run default config
- run exact/min/max speaker-count variants
- emit `DiarizationQualityReport` for each run
- make scoring policy explicit in output (`collarMs`, `skipOverlap`) and accept
  CLI knobs for benchmark comparisons
- compute DER only when an RTTM reference is present; JER remains deferred until
  the harness has fixture evidence that it adds useful signal beyond DER,
  coverage, and speaker-count delta

Do not treat expected speaker count as a benchmark. It is a coarse symptom
check, not ground truth.

## Deferred Work

These are intentionally not in the first implementation:

- user-facing quality profiles
- raw clustering threshold or VBx tuning UI
- meeting-level expected speaker count UI
- participant assignment menu
- `assignedParticipantName` or participant fields on `SpeakerInfo`
- stored-meeting `diarization-report` without persisted raw diarizer output
- cloud/provider diarization productization

## Implementation Order

Implement in small PR-sized slices. NOTE (2026-06-14 refresh): the private
evaluation harness, listed historically as step 5, is promoted to step 0 — a
minimal "measure what we can today" baseline lands before any behavior change.

0. Evaluation baseline (minimal):
   - add a `DiarizationMetrics` module (DER + speaker-count delta + coverage;
     JER deferred until fixtures show it adds signal)
     with unit tests over synthetic segment/reference inputs
   - add a dev CLI `diarization-eval <fixtures-dir>` that runs the existing
     diarizer over `fixtures/private/diarization/*/` and prints per-fixture
     metrics; route default vs hinted variants through `DiarizationOptions`
     so the harness exercises the same per-call path as production
   - gitignore `fixtures/private/`
   - if FluidAudio's DER helper fits the local data shape, reuse it; otherwise
     keep the local scorer explicit and tested, including optimal speaker
     mapping rather than greedy first-pair assignment

1. Speaker ID and hint plumbing:
   - add `SpeakerID` helper and tests for source-prefixed speaker IDs
   - add `DiarizationOptions` with `SpeakerCountHint` only
   - add Core-level hint validation
   - change `DiarizationServiceProtocol` so options cannot be silently ignored
   - refactor `DiarizationService` to use `baseConfig` plus manager factory
   - map hints onto a copy of the injected base config
   - add CLI `--speaker-count`, `--speaker-min`, and `--speaker-max`
2. Word assignment:
   - add `SpeakerWordAssigner`
   - keep `SpeakerMerger` as a compatibility wrapper if needed
   - use conservative, ambiguity-aware fallback assignment for system diarization
   - fix `buildDiarizationSegments` for leading source-only/unassigned words
   - thread assignment summaries through fresh-run internals
3. Fresh-run report:
   - add `--diarization-report <path>`
   - use structured warning payloads with explicit denominators
4. Minimal speaker provenance:
   - extend `SpeakerInfo` with source/raw-ID/label-source metadata
   - add explicit meeting system-diarization adapter
5. Private fixture harness:
   - keep this separate from the basic hint/assigner/report implementation
6. Reconsider stored-meeting reports and quality profiles only after raw state
   and fixtures exist.

## Acceptance Criteria

1. A known two-remote-speaker file can be transcribed with `--speaker-count 2`, and
   the fresh-run report records the requested hint and detected speaker count.
2. Invalid speaker hint combinations fail before transcription starts.
3. Existing no-hint behavior remains the default.
4. Word assignment reports direct, fallback, source-only, and unassigned counts.
5. Fallback assignment refuses ambiguous nearby speakers.
6. Meeting microphone words are never assigned from system diarization.
7. A leading source-only/unassigned word does not drop later diarization
   segments.
8. Direct-overlap ties between different speakers are treated as ambiguous.
9. `DiarizationService` validates hints in Core and tests prove resolved hints
   reach the FluidAudio config.
10. Meeting system diarization wraps segments and speakers through one adapter,
    preserving raw provider speaker IDs where available.
11. Speaker rename remains backward-compatible with existing transcripts and sets
    `labelSource = .user` for renamed speakers.
12. No transcript text, audio path, URL, or speaker label is added to telemetry
   or diagnostic logs.
13. The first report surface is fresh-run only; stored-meeting reports are not
    shipped until raw diarizer state is persisted.

## Verification Plan

Targeted first pass:

```bash
swift test --filter 'DiarizationServiceTests|SpeakerWordAssignerTests|SpeakerMergerTests|TranscriptionServiceTests|TranscriptSegmenterTests'
```

Before merging implementation:

```bash
swift test
```

Manual validation:

1. Transcribe a local multi-speaker file with no hints.
2. Transcribe the same file with `--speaker-count 2`.
3. Compare requested hint, detected speaker count, assignment coverage, and
   source-only rate.
4. Retranscribe a meeting with isolated `system.m4a` and confirm the hint
   applies only to remote/system speakers.
5. Rename a speaker and confirm exports show the display label while JSON still
   preserves the raw speaker ID and label source.
