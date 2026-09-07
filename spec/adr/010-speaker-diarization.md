# ADR-010: Speaker Diarization via FluidAudio Offline Pipeline

> Status: **Accepted**
> Date: 2026-03-04

## Context

MacParakeet v0.4 adds speaker diarization to file transcription (F13). Users who transcribe interviews, podcasts, and meetings need to know "who said what" — not just the raw text.

### What is diarization?

Speaker diarization answers "who spoke when" in an audio recording. It is a three-stage problem:

1. **Segmentation** — detect when speech starts/stops and where speaker changes occur
2. **Embedding extraction** — produce a voice fingerprint for each speech segment
3. **Clustering** — group segments by voice similarity to assign consistent speaker IDs

These are distinct subproblems. No single model solves all three.

### FluidAudio already ships diarization

FluidAudio (our existing STT dependency, ADR-007) bundles a complete diarization pipeline with no additional SwiftPM dependencies required. It offers three approaches:

| Approach | Pipeline | DER | Speed | Speaker Limit | Streaming |
|----------|----------|-----|-------|---------------|-----------|
| **Offline** | Pyannote community-1 segmentation + WeSpeaker v2 embeddings + VBx clustering | ~15% (VoxConverse), ~17.7% (AMI) | 64-122x RTF | Unlimited | No |
| **Streaming (Pyannote)** | Legacy pyannote 3.1 segmentation + WeSpeaker v2 embeddings, chunk-by-chunk with SpeakerManager | ~26-50% (config-dependent) | 51-392x RTF | Unlimited | Yes |
| **Sortformer** | NVIDIA's end-to-end neural diarizer | ~32% (AMI SDM) | ~127x RTF | **4 max (hard limit)** | Yes |

### Competitive landscape

Pyannote community-1 is widely considered the best open-source diarization pipeline as of early 2026:

- **PyannoteAI (commercial)**: ~8.5% DER (precision-2 on VoxConverse) — best overall, but requires a paid API
- **Pyannote community-1 (PyTorch reference)**: ~11.2% DER on VoxConverse — best open-source model. FluidAudio's CoreML port: ~15% DER due to fp16 quantization (significant improvement over legacy 3.1 in speaker counting and assignment)
- **DiariZen**: 13.3% DER — competitive open-source alternative, but no CoreML/ANE port exists
- **NVIDIA Sortformer**: Real-time capable, but 4-speaker hard limit and ~32% DER

FluidAudio's offline pipeline uses pyannote community-1 converted to CoreML, running on the ANE at 64-122x realtime. pyannote's commercial `precision-2` is a distinct model, not this pipeline with proprietary tuning (see the 2026-09-06 amendment).

## Decision

**Use FluidAudio's offline diarization pipeline (pyannote community-1 + WeSpeaker + VBx) for file transcription only. Do not use Sortformer. Do not add streaming diarization.**

### Scope

- **File transcription**: Run diarization after ASR on the same audio. Merge speaker segments with word-level timestamps.
- **Dictation**: No diarization. Single-speaker by definition.
- **YouTube transcription**: Diarization applies (same as file transcription).

### Integration approach

Run ASR and diarization on the same audio, then merge results by timestamp alignment:

```
Audio file
  ├─→ AsrManager.transcribe()          → word timestamps + text
  └─→ OfflineDiarizerManager.process() → speaker segments + IDs
                    ↓
         Merge by time overlap
                    ↓
         Speaker-attributed transcript
```

ASR and diarization can potentially run in parallel since they use different models (Parakeet TDT for ASR, pyannote/WeSpeaker for diarization), but sequential is simpler and correctness is more important than shaving seconds. Start sequential, optimize later if needed.

### Model details

| Component | Model | Size | License | Runs on |
|-----------|-------|------|---------|---------|
| Segmentation | Pyannote community-1 (powerset) | ~50 MB | CC-BY-4.0 | ANE |
| Embeddings | WeSpeaker v2 (256-dim) | ~40 MB | Apache 2.0 | ANE |
| Filter bank | Fbank feature extractor | ~1 MB | Apache 2.0 | CPU |
| PLDA scoring | PLDA rho model + psi parameters | ~10 MB | Apache 2.0 | CPU |
| Clustering | VBx + AHC warm start | N/A (algorithmic) | N/A | CPU |

**Total additional download**: ~130 MB (one-time, cached alongside ASR models)

### API usage

```swift
// DiarizationService.highAccuracyConfig (2026-09-06 amendment)
var config = OfflineDiarizerConfig.default
config.segmentation.stepRatio = 0.1
config.embedding.minSegmentDurationSeconds = 0
config.zeroVoteReembed = .init(enabled: true)

let models = try await OfflineDiarizerModels.load(from: modelsDirectory)
let manager = OfflineDiarizerManager(config: config.withSpeakers(min: 1, max: 4))
manager.initialize(models: models)

let result = try await manager.process(url)
for segment in result.segments {
    // segment.speakerId, segment.startTimeSeconds, segment.endTimeSeconds
}
```

### Data model impact

- `WordTimestamp` gains a `speakerId: String?` field storing **stable raw IDs** (`"S1"`, `"S2"`) from the diarization pipeline — not display labels
- `Transcription.speakers` stores a JSON mapping with stable IDs and display names: `[{"id":"S1","label":"Speaker 1"},{"id":"S2","label":"Speaker 2"}]`. Rename updates the mapping only, not every word.
- New `diarizationSegments` JSON column on `Transcription` stores the raw diarization output for accurate speaking time analytics and future features (timeline view, skip-to-speaker)
- `Transcription.speakerCount` populated from diarization result
- Existing transcriptions without diarization remain valid (all fields nullable)

### Diarization is non-fatal

If diarization fails (e.g. `noSpeechDetected`, model error, timeout), the ASR result **must still be persisted**. Diarization failure should:
- Log the error
- Leave `speakerCount`/`speakers`/`diarizationSegments` as nil
- Leave all `WordTimestamp.speakerId` as nil
- Show a non-blocking notice in the UI ("Speaker detection unavailable for this file")
- Never prevent the user from viewing, exporting, or using the transcript

### UI impact

- Speaker labels in transcript view with color differentiation
- Speaker rename (click label to assign real name)
- Per-speaker analytics (speaking time, word count)
- All export formats include speaker labels when available
- Progress: "Identifying speakers..." sublabel with time estimate during diarization phase
- Settings toggle to enable/disable diarization (on by default where supported; explicit off remains respected — see the 2026-07-03 amendment)

### Always-on vs opt-in

> **Amendment (2026-04-02):** The original decision was "always-on, no global toggle." This has been revised to **a Settings toggle (on by default)**. See rationale below.

~~For file transcription, always run it — users transcribing files almost always want to know who said what.~~ **Revised:** Diarization is controlled by a "Speaker detection" toggle in Settings (on by default). Users who don't need speaker attribution can disable it for faster transcriptions.

**Why the change:** The original decision was "always-on, no toggle." A Settings toggle gives users explicit control over the accuracy/speed tradeoff. The toggle detail text sets expectations without quoting an accuracy figure (the earlier "~85% accurate" copy was not derivable from any DER measurement and is retired; see the 2026-09-06 amendment).

**Progress UX:** When enabled, show "Transcribing..." during ASR, then "Identifying speakers..." during diarization. When disabled, the diarization step is skipped entirely (no progress indicator for it).

~~**No global toggle.**~~ **Settings toggles added.** Separate "Speaker detection" toggles in Settings → Transcription and Settings → Meeting Recording control whether diarization runs for file/URL transcription and meeting recordings. The original concern about "why don't I see speakers?" confusion is addressed by the toggles being clearly labeled and discoverable in the relevant capture workflow.

Skip diarization for: dictation (single speaker by design), or when the corresponding Settings toggle is off.

**CLI:** `macparakeet-cli transcribe` follows the saved file/URL speaker-detection preference; `macparakeet-cli retranscribe --kind meeting` follows the saved meeting speaker-detection preference when `--speaker-detection app-default` is used. When unset, both preferences default to on where supported. Use `--no-diarize` / `--speaker-detection off` to skip for one run, or a speaker-count constraint to force it on. Text output shows speaker labels at turn changes; JSON output includes all speaker data via Codable.

**Readiness contract:** Diarization remains a separate service from the STT scheduler, but when speaker detection is enabled (on by default where supported — see the 2026-07-03 amendment) the onboarding/ready-state path must account for diarization-model readiness before claiming file transcription is fully ready.

> **Amendment (2026-06-14):** Two corrections to keep this ADR faithful to the
> shipped code at that point. The default-off correction below was superseded
> by the 2026-07-03 amendment.
>
> **1. The shipped default was OFF, not on.** The "Speaker detection" toggle
> defaults to off across the app — Settings, runtime preferences
> (`AppRuntimePreferences.speakerDiarization`), and the CLI all resolve to off
> unless the user opts in. The default was deliberately flipped on→off in commit
> `4a1d25133` ("Polish AI settings defaults"); the Settings copy reflects it
> ("Optional. Adds speaker labels when audio is clear; leave off if labels are
> unreliable."). Consequences: (a) `macparakeet-cli transcribe` does **not**
> diarize by default — it diarizes only when the stored preference is on, when
> `--speaker-detection on` is passed, or when a speaker-count constraint
> (`--speaker-count` / `--speaker-min` / `--speaker-max`) is given; `--no-diarize`
> forces it off. (b) The readiness contract above applies only when the user has
> enabled speaker detection — default onboarding does not fetch the ~130 MB
> diarization assets.
>
> **Amendment (2026-07-03):** Meeting-corpus capture restored the default to
> **ON where supported**. The `speakerDiarization` preference remains
> UserDefaults-backed and user-controllable; an absent key resolves to on, while
> an explicit stored `false` continues to disable speaker detection. Meetings
> still only run diarization when a system-audio track exists, because the
> meeting pipeline diarizes the isolated system side after capture. This aligns
> with ADR-027's private speech-memory direction: speaker structure is only
> recoverable while raw meeting audio exists, so capture-time diarization is the
> last chance to preserve speaker labels in the corpus.
>
> **Amendment (2026-07-05):** The single saved value was split by workflow.
> File and URL transcription continue to use the `speakerDiarization`
> preference. Meeting recording now uses the independent
> `meetingSpeakerDiarization` preference, also UserDefaults-backed and default
> on where supported. Meetings still diarize only the isolated system-audio
> track after capture; microphone words remain source-labeled as `Me`.
>
> **2. The FluidAudio dependency surface has grown.** The core decision above
> still stands — MacParakeet ships only the offline batch pipeline and uses
> neither Sortformer nor streaming diarization. But the pinned FluidAudio now
> also exposes streaming diarizers (`LSEENDDiarizer`, `SortformerDiarizer`) and
> speaker-enrollment APIs. None are shipped. They are surveyed as a *future*
> tentative-live / speaker-memory option in
> `docs/research/speaker-diarization-frontier-2026-06.md` and
> `docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md`.

> **Amendment (2026-09-06, issue #972):** Four corrections after the
> speaker-attribution research in
> `docs/research/2026-09-06-speaker-diarization-claude/`.
>
> **1. The pinned 0.15.4 pipeline was not a faithful community-1 port.** Its
> clustering stage converted the AHC threshold with `sqrt(2 - 2t)` although the
> config documents a Euclidean distance (so the default 0.6 ran as a cut of
> 0.894 and raising the knob split more instead of merging more), compared
> speaker-count constraints against the AHC warm-start count instead of the
> clusters VBx kept, had no constrained assignment of local speakers that share
> a segmentation chunk, and seeded K-Means re-clustering from `UInt64.random`.
> FluidAudio fixed all four in 0.15.5 (PR #735) and 0.15.6 (PR #802). The
> app now pins `exact: "0.15.6"`. The claim above that this is "the same
> pipeline pyannote's commercial API uses" was unsupported and is withdrawn:
> `precision-2` is a distinct model, 4 to 10 DER points better on pyannote's
> own table. The `~17.7% AMI` figure in the table above was produced by
> FluidAudio under the inverted threshold semantics and is flagged upstream
> for re-benchmark; treat it as historical. The "~85% accurate" Settings copy
> is retired because no DER figure supports it.
>
> **2. Async runs use the high-accuracy configuration.** Diarization always
> runs after transcription, so `DiarizationService.highAccuracyConfig` takes
> FluidAudio's slower preset: `stepRatio 0.1` (1 s hop instead of 2 s),
> `minSegmentDurationSeconds 0` (short turns keep their own embedding and
> segment), and zero-vote re-embedding on. FluidAudio's own VoxConverse table
> (collar 0.25 s, overlap ignored), published for 0.15.4 and not yet re-run
> under 0.15.6's corrected clustering, put this preset at 13.89% versus 15.07%
> DER for about half the throughput; treat those as historical, not as a
> measurement of the pinned build. `clustering.threshold` stays at the library default
> (the app never tuned it, so the semantic change needs no remap),
> `constrainedAssignment` stays at its new default (on), and K-Means
> re-clustering is deterministic in 0.15.6 (`baseSeed 0`, `nInit 10`).
> The CLI `--speaker-count` / `--speaker-min` / `--speaker-max` flags map to
> `withSpeakers(exactly:)` / `withSpeakers(min:max:)` unchanged; under the
> corrected semantics a bound binds only when the auto-detected count falls
> outside it.
>
> **3. Meetings feed the calendar attendee count in as a prior that can only
> cap.** The finalizer derives `MeetingSpeakerPrior` from
> `calendarEventSnapshot`, whose attendee list already excludes the user;
> attendees captured as `declined` and participants captured as a `room`,
> `resource`, or `group` are excluded too (`MeetingCalendarPerson.status` and
> `.kind`, optional fields added 2026-09-06; older snapshots count every
> attendee). With `n` countable remote attendees the system-track diarizer
> receives bounds `min = 1`, `max = n + 1`, never an exact count and never a
> minimum above 1. Issue #972 asked for `min = max(1, n - 1)`; that was
> narrowed deliberately: declined, tentative, and resource attendees, no-shows,
> and uninvited joiners make the invite an unreliable count, and FluidAudio's
> `minSpeakers` binds only by forcing K-Means re-clustering upward, so a wrong
> minimum splits real speakers while a generous maximum only caps the
> over-splitting users actually report (#542). A 1:1 invite therefore still
> runs the diarizer with `max 2` instead of skipping clustering. No snapshot,
> no countable attendee, or more than eight attendees leaves clustering
> unconstrained. An explicit CLI speaker constraint wins over the calendar
> prior. The effective policy is recorded as `speaker_prior` on
> `diarization_completed` (`explicit_cli`, `bounds_1_<n+1>`,
> `unconstrained_no_attendee_count`, `unconstrained_large_attendee_count`) and
> in the local capture diagnostics; it carries no attendee identity.
>
> **4. Not changed here (follow-ups in the research synthesis):**
> embedding-based consolidation of over-split clusters, `SpeakerMerger`
> smoothing and nearest-turn fallback for sub-second words, stable speaker IDs
> across re-runs, in-person meeting detection, voiceprints, and Nemotron-3
> Diarization (evaluation-only license). FluidAudio issue #878 (a
> deterministic BNNS crash of the offline diarizer on macOS 14) predates the
> upgrade and is unchanged; `ANEInferenceGate` still serializes the
> diarizer's Neural Engine work on macOS 14.

**Model preparation (2026-09-07):** The service shares one model-loading task
across speaker constraints and initializes each configured manager from those
models. Downloads and loading run outside `ANEInferenceGate`; the service
does not call FluidAudio's combined download-and-prewarm `prepareModels` API.
Eager prewarming is skipped, so the first prediction happens inside the gated
`process` call. This prevents a slow speaker-model download from blocking
dictation on macOS 14. Cancelling one caller stops that caller's wait without
cancelling the shared load. A failed load can be retried by a later caller.
FluidAudio retains compiled-model recovery. An existing malformed PLDA metadata
file is replaced atomically only after a valid replacement is downloaded;
offline mode, cancellation, and failed downloads preserve the cached file and
model bundles.

## Rationale

### Why the offline pipeline, not Sortformer

| Factor | Offline (Pyannote community-1) | Sortformer |
|--------|-------------------------------|------------|
| DER | ~15% (VoxConverse) | ~32% (AMI SDM) |
| Speaker limit | Unlimited | 4 max (hard architectural limit) |
| Cross-recording recognition | Possible via SpeakerManager | Not supported |
| Noise robustness | Good | Better |
| Overlapping speech | Exclusive (overlaps trimmed by default) | Better (models overlap natively) |
| Quiet/distant speech | Good | Poor (trained to ignore background) |
| Maturity | Battle-tested (pyannote is the industry standard) | Newer, less proven |

Sortformer's 4-speaker cap is a non-starter. It's baked into the model architecture (static CoreML tensor shapes) — not a tuning parameter. A podcast with 5 guests, a panel discussion, or a meeting with 5+ people would silently miss or merge speakers. The offline pipeline has no such limit.

Sortformer's strengths (noise robustness, overlapping speech) matter most for real-time meeting recording — Oatmeal's domain, not MacParakeet's. For file transcription of pre-recorded audio, the offline pipeline's higher accuracy and unlimited speakers are strictly better.

### Why not streaming diarization

MacParakeet's file transcription is batch by nature — the entire audio file is available upfront. Streaming diarization trades 10-15% DER for latency benefits we don't need. The offline pipeline processes faster than realtime anyway (64-122x RTF), so there's no UX benefit to streaming.

Real-time meeting diarization is Oatmeal's territory.

### Why not a separate dependency

FluidAudio already includes the diarization pipeline. Adding a separate diarization library would mean:
- A new SwiftPM dependency to vet and maintain
- Potentially different audio preprocessing requirements
- No CoreML/ANE optimization (most alternatives are Python-only)
- Duplicating models that FluidAudio already provides

Using FluidAudio's built-in pipeline means zero new dependencies, shared model infrastructure, and a tested CoreML path.

### Accuracy tradeoffs

FluidAudio's CoreML port loses ~2-4% DER compared to the PyTorch reference (~11% DER for pyannote community-1). This is due to fp16 quantization required for ANE execution. The tradeoff is 60-120x speed improvement. For a desktop transcription app, 15% DER is more than sufficient — commercial APIs like AssemblyAI and Deepgram operate in a similar range.

The most common error types:
- **Miss**: Speech not detected (~9% of total DER)
- **Speaker error**: Speech attributed to wrong speaker (~3-5%)
- **False alarm**: Silence classified as speech (~1-4%)

Users can correct misattributions by renaming speakers. Missed speech is visible in the transcript (unlabeled segments).

## Consequences

### Positive

- Speaker-attributed transcripts for file transcription and YouTube
- No new dependencies — uses existing FluidAudio
- ~130 MB additional model download (one-time, small vs 6 GB ASR models)
- Unlimited speakers (no artificial cap)
- ~15% DER — competitive with commercial solutions
- 64-122x RTF — diarization adds negligible time to transcription

### Negative

- ~130 MB additional model download for default-on speaker detection where supported (see the 2026-07-03 amendment)
- ~2-4% DER loss vs PyTorch reference due to CoreML fp16 quantization
- Overlapping speech regions are trimmed (exclusive output) — words in overlap zones may get `speakerId = nil`
- No cross-file speaker identity (Speaker 1 in file A is not linked to Speaker 1 in file B)
- No real-time streaming diarization (by design — that's Oatmeal)
- Platform-specific quirk: iOS has audio conversion issues with stereo files (macOS-only is fine for us, per FluidAudio's investigation report)

### Future possibilities (not committed)

- Cross-file speaker recognition via SpeakerManager enrollment (persist voice embeddings)
- Speaker-aware search ("show me everything Sarah said")
- Diarization-informed audio player (skip to next speaker)
- Parallel ASR + diarization for faster processing

## Alternatives Considered

### NVIDIA Sortformer only

Rejected. 4-speaker hard limit and 32% DER. The architectural cap means 5+ speaker recordings silently fail. Not acceptable for a general-purpose transcription tool.

### Sortformer for streaming + offline for batch (hybrid)

Rejected. Unnecessary complexity. MacParakeet doesn't need streaming diarization — all audio is available upfront for file transcription. One pipeline is simpler.

### WhisperX (combined ASR + diarization)

Rejected. Python-based, no CoreML/ANE support. We already have Parakeet TDT for default ASR (better accuracy, faster). WhisperX bundles Whisper + pyannote in Python — we'd gain nothing and lose our native Swift architecture. ADR-021's later optional WhisperKit support uses a native local Swift path and does not change this diarization decision.

### pyannote Python directly

Rejected. Would require reintroducing the Python subprocess we eliminated in ADR-007. FluidAudio already provides the same models converted to CoreML.

### No diarization (defer indefinitely)

Rejected. Speaker attribution is a core expectation for file transcription. Every competitor (MacWhisper, Superwhisper, VoiceInk) either has it or is adding it. Without it, MacParakeet's file transcription is incomplete for multi-speaker recordings.

## References

- [FluidAudio GitHub](https://github.com/FluidInference/FluidAudio) — SDK with built-in diarization
- [FluidAudio Diarization Docs](https://github.com/FluidInference/FluidAudio/tree/main/Documentation/Diarization)
- [FluidAudio Benchmarks](https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md)
- [Pyannote community-1 announcement](https://www.pyannote.ai/blog/community-1)
- [Pyannote benchmark comparison](https://www.pyannote.ai/benchmark)
- [NVIDIA Sortformer paper](https://arxiv.org/abs/2409.06656)
- [NVIDIA Sortformer model card](https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2)
- [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)
- [Best Speaker Diarization Models Compared (2026)](https://brasstranscripts.com/blog/speaker-diarization-models-comparison)
- [ADR-007: FluidAudio CoreML Migration](./007-fluidaudio-coreml-migration.md)
- [F13: Speaker Diarization spec](../02-features.md)
