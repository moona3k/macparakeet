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

FluidAudio's offline pipeline uses pyannote community-1 converted to CoreML, running on the ANE at 64-122x realtime. This is the same pipeline that pyannote's own commercial API uses, minus proprietary tuning.

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
let config = OfflineDiarizerConfig()
let manager = OfflineDiarizerManager(config: config)
try await manager.prepareModels()

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

### Always-on vs opt-in

Diarization adds ~30-56 seconds of processing per hour of audio (at 64-122x RTF) on top of ASR's ~23 seconds per hour. Total file transcription time for 1 hour of audio: ~53-79 seconds (ASR + diarization). This is still very fast and the additional time is worth it for speaker attribution. Model download is ~130 MB (one-time).

For file transcription, always run it — users transcribing files almost always want to know who said what. If a file has only one speaker, diarization correctly returns a single speaker label with no user-visible overhead.

**Important:** Progress reporting and time estimates must account for both ASR and diarization phases. Show "Transcribing..." during ASR and "Identifying speakers..." during diarization as separate progress indicators.

Skip diarization only for dictation (single speaker by design).

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

- ~130 MB additional model download during onboarding
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

Rejected. Python-based, no CoreML/ANE support. We already have Parakeet TDT for ASR (better accuracy, faster). WhisperX bundles Whisper + pyannote in Python — we'd gain nothing and lose our native Swift architecture.

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
