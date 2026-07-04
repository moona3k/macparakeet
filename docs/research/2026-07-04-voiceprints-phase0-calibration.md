# Voiceprints Phase 0 Calibration Report

- **Date:** 2026-07-04
- **Scope:** FluidAudio 0.15.4 offline diarizer speaker embeddings for MacParakeet speaker-profile matching.
- **Privacy posture:** This report contains no transcript text, no personal names, and no audio content. It uses anonymized session labels (M1-M3; UUID mapping kept local only), month-level dates, durations, and aggregate distance statistics only.
- **User-data rule:** Meeting recordings under `~/Library/Application Support/MacParakeet/meeting-recordings/` were read in place only.
- **Status:** NO-GO for Phase 1 on the current corpus — attributed to corpus
  quality/availability (pre-AEC echo contamination, 3 usable sessions), not a
  proven embedding failure. Phase 0b (clean-corpus validation) decides whether
  the FluidAudio path is viable. See "Orchestrator Re-Analysis".
- **Gate:** Determine whether embeddings show measurable same-person / different-person separation across at least 2 recording sessions, and pick `tau` + margin for suggestions.

## Inputs

- Plan: `plans/active/2026-07-03-speaker-voiceprints.md`
- API note: `docs/research/2026-07-03-speaker-voiceprints/report-fluidaudio-api.md`
- Harness: `docs/research/2026-07-04-voiceprints-phase0/harness/`
- Per-session data: `docs/research/2026-07-04-voiceprints-phase0/data/`

## Corpus Inventory

Inventory artifact: `docs/research/2026-07-04-voiceprints-phase0/data/inventory.json`.

Read-only scan of `~/Library/Application Support/MacParakeet/meeting-recordings/`:

| Metric | Value |
|---|---:|
| Session folders | 465 |
| Created date range | 2026-04 to 2026-07 |
| `microphone.m4a` present | 463 |
| `system.m4a` present | 457 |
| Both `microphone.m4a` and `system.m4a` present | 457 |
| `meeting.m4a` present | 21 |
| `microphone-cleaned.m4a` present | 3 |

Readable media is much smaller than file presence:

| Track | Present | Nonzero bytes | Valid duration via `ffprobe` |
|---|---:|---:|---:|
| `microphone.m4a` | 463 | 328 | 22 |
| `system.m4a` | 457 | 258 | 14 |
| `meeting.m4a` | 21 | 21 | 18 |
| `microphone-cleaned.m4a` | 3 | 3 | 3 |

Paired readable `microphone.m4a` + `system.m4a` sessions: 12. Duration
distribution for those paired sessions, using max(microphone, system), seconds:

| p5 | p25 | p50 | p75 | p95 | min | max | mean |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.372 | 5.264 | 105.397 | 494.891 | 2005.988 | 0.149 | 2563.861 | 502.032 |

Paired readable sessions meeting the requested `duration >= 5 min` gate: **3**.

| Session ID | Created | Duration sec |
|---|---:|---:|
| `M1` | 2026-04 | ~21 min |
| `M2` | 2026-06 | ~26 min |
| `M3` | 2026-06 | ~43 min |

Sampling implication: the requested `~40 sessions spread across the date range,
duration >= 5 min, both tracks present` sample cannot be constructed from the
currently readable retained corpus. Continuing through model check and harness
validation, but the >=30-session definition of done is blocked at Step 5 unless
additional finalized paired recordings exist outside this folder.

## Model Check

Model-check artifact: `docs/research/2026-07-04-voiceprints-phase0/data/model-check.json`.

Result: **PASS**. No download required.

- FluidAudio checkout used for API confirmation: `../../../.build/checkouts/FluidAudio`
  at `v0.15.4` (`b9d4372`).
- `OfflineDiarizerModels.defaultModelsDirectory()` resolves to the base model
  directory `~/Library/Application Support/FluidAudio/Models`.
- FluidAudio's default diarizer repo leaf is
  `~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml`.
- Required offline files present in that leaf:
  - `Segmentation.mlmodelc`
  - `FBank.mlmodelc`
  - `Embedding.mlmodelc`
  - `PldaRho.mlmodelc`
  - `plda-parameters.json`
- Additional diarization files also present: `config.json`,
  `xvector-transform.json`, `pyannote_segmentation.mlmodelc`,
  `wespeaker_v2.mlmodelc`.

Harness calls `OfflineDiarizerManager.prepareModels(directory:)` with the base
directory explicitly: `~/Library/Application Support/FluidAudio/Models`.

## Harness

Harness path: `docs/research/2026-07-04-voiceprints-phase0/harness/`.

Contents:

- `Package.swift`: standalone SwiftPM executable, FluidAudio pinned to
  `.exact("0.15.4")`.
- `Sources/VoiceprintHarness/main.swift`: runs
  `OfflineDiarizerManager.prepareModels(directory:)` with
  `~/Library/Application Support/FluidAudio/Models`, normalizes source audio to
  temporary 16 kHz mono WAV under `/tmp`, runs offline diarization, and writes
  JSON with `{sessionID, track, speakers: [{speakerId, totalSpeechSec,
  embedding[256]}]}` plus duration/timing metadata.
- `analyze_voiceprints.py`: computes FluidAudio cosine distance populations,
  overlap, and tau sweeps from the harness JSON only.

Build command used:

```bash
CLANG_MODULE_CACHE_PATH="$PWD/.build/module-cache" \
swift build --disable-sandbox \
  --config-path "$PWD/.build/config" \
  --security-path "$PWD/.build/security" \
  --scratch-path "$PWD/.build" \
  --cache-path "$PWD/.build/swiftpm-cache"
```

Build result: **PASS**. SwiftPM used a package-local mirror to the existing
local FluidAudio `v0.15.4` checkout because network is unavailable. Runtime
note: CoreML logs non-fatal cache warnings for
`~/Library/Caches/voiceprint-harness` in this sandbox; extraction still
completed and wrote JSON.

## Extraction Sample

Sample-selection artifact:
`docs/research/2026-07-04-voiceprints-phase0/data/sample-sessions.json`.

Requested sample: ~40 sessions, spread across date range, `duration >= 5 min`,
both `microphone.m4a` and `system.m4a` present. Actual selectable corpus from
readable finalized media: **3 sessions**. This blocks the requested >=30-session
definition of done at Step 5.

Extracted anyway for the full eligible corpus:

| Mode | Sessions | Tracks | JSON files | Speaker embeddings |
|---|---:|---:|---:|---:|
| Full-track | 3 | 6 | 6 | 21 |
| Split-half | 3 | 6 | 6 | 31 |

Full-track speaker counts:

| Session ID | Mic speakers | System speakers |
|---|---:|---:|
| `M1` | 3 | 3 |
| `M2` | 4 | 7 |
| `M3` | 2 | 2 |

Important observation: the microphone track is the known app-user channel, but
offline diarization still over-clustered it into 2-4 speakers per recording.
For same-person analysis, all microphone clusters are treated as the same known
speaker because that is the only available cross-recording ground truth.

## Distance Populations

Analysis artifact:
`docs/research/2026-07-04-voiceprints-phase0/data/analysis-summary.json`.

Distance = FluidAudio cosine distance (`0 = identical`, larger = less similar).

| Population | Count | p5 | p25 | p50 | p75 | p95 |
|---|---:|---:|---:|---:|---:|---:|
| (a) SAME user, mic cross-recording | 26 | 0.152 | 0.758 | 0.814 | 0.866 | 1.031 |
| (b) SAME split-half, microphone | 24 | 0.025 | 0.261 | 0.766 | 0.884 | 0.929 |
| (b) SAME split-half, system nearest-pair proxy | 6 | 0.032 | 0.057 | 0.148 | 0.693 | 0.950 |
| (c) DIFFERENT system speakers, same meeting | 25 | 0.684 | 0.869 | 0.927 | 0.964 | 1.053 |
| (d) Random system speakers, cross-meeting | 41 | 0.255 | 0.841 | 0.943 | 1.006 | 1.080 |

Headline separation:

- Same-user mic cross-recording median: **0.814**.
- Different system speakers, same-meeting median: **0.927**.
- Median gap: **0.113**, but distributions overlap heavily.
- Same-user p95 (**1.031**) is above different-system p5 (**0.684** for same
  meeting, **0.255** for cross-meeting).
- 88.5% of same-user mic pairs are at or above the same-meeting different-speaker
  p5; 88.0% of same-meeting different-speaker pairs are at or below same-user p95.

This is not enough separation to power user-visible profile matching.

## Threshold Sweep

Pairwise sweep, treating (a) as positives and (c)/(d) as negatives. Margin is
listed as the intended product margin (`0.10`), but pairwise distances do not
contain enough ranked-candidate information to apply it directly.

| Tau | TPR same mic | FPR system same meeting | FPR system cross meeting |
|---:|---:|---:|---:|
| 0.30 | 11.5% | 0.0% | 7.3% |
| 0.55 | 11.5% | 0.0% | 7.3% |
| 0.70 | 11.5% | 12.0% | 7.3% |
| 0.80 | 42.3% | 12.0% | 22.0% |
| 0.85 | 69.2% | 16.0% | 29.3% |
| 0.90 | 76.9% | 32.0% | 41.5% |
| 0.95 | 88.5% | 52.0% | 53.7% |

Margin-aware proxy sweep (`margin = 0.10`) using the mic channel as a stand-in
known profile:

| Tau | Positive trials | Negative trials | Proxy TPR | Proxy FPR |
|---:|---:|---:|---:|---:|
| 0.30 | 9 | 12 | 33.3% | 41.7% |
| 0.55 | 9 | 12 | 33.3% | 58.3% |
| 0.80 | 9 | 12 | 33.3% | 66.7% |
| 0.95 | 9 | 12 | 33.3% | 66.7% |

No tau in this sweep gives both useful recall and acceptable false positives.

## Recommendation

**Phase 0 result: NO-GO.**

Recommended product threshold: **none**. Do not ship auto-suggest/profile
matching from these FluidAudio 0.15.4 offline-diarizer embeddings on the current
evidence.

If a diagnostic-only dogfood switch is needed for more data collection, keep it
off by default and use `tau <= 0.30`, `margin >= 0.10`, confirmation required,
and no user-visible confidence promise. Even that setting catches only 11.5% of
same-user cross-recording pairs in the pairwise sweep and still shows nonzero
cross-meeting system false positives.

Confidence tiers for product UX: **do not define user-visible tiers yet**. The
observed distributions do not justify "high confidence". For future calibration,
start with:

- Exploratory only: distance `<= 0.30` and margin `>= 0.10`.
- Reject/unknown: distance `> 0.30` or margin `< 0.10`.

This fails the plan gate: no reliable same-person / different-person separation
for profile matching was demonstrated, and the requested >=30-session corpus
could not be constructed from readable finalized paired recordings.

## Orchestrator Re-Analysis (dominant-cluster ground truth)

The primary analysis treated *all* microphone clusters as the app user; since the
mic track over-clusters (2–4 speakers) and this corpus predates AEC, that ground
truth is contaminated by bleed. Re-analysis using only the **dominant mic
cluster** (by speech duration: 45–71% of mic speech) per session:

| Pair population | Distances |
|---|---|
| Same user, dominant cluster, cross-recording (3 pairs) | all three pairs within 0.73–0.85 |
| Same speaker, split-half, within recording | p5 ≈ 0.03 (tight) |
| Different system speakers, same meeting | median ≈ 0.92 |
| User (dominant mic) vs system speakers, same meeting | includes values in the **0.19–0.38** band in one of the three sessions |

Two conclusions sharpen:

1. **The correction does not rescue the gate.** Even clean-as-available same-user
   pairs sit at 0.73–0.85 — inside the different-speaker band. Cross-recording
   matching fails on this corpus regardless of clustering hygiene.
2. **The corpus itself is the prime suspect, not the embedding stack.** Split-half
   matches within a recording are tight (≈0.03), so embeddings are internally
   consistent; and the 0.19–0.38-band user↔system matches show the user's own voice
   present in the system track (pre-AEC echo), meaning recording conditions are
   heavily contaminated. WeSpeaker-class models report ~1–3% EER cross-session on
   public benchmarks; 0.8 same-person distance is so far off that channel/echo
   conditions — not model capability — are the more likely cause.

**Refined verdict: NO-GO for Phase 1 now, attributed to corpus quality and
availability rather than a proven embedding failure.** Decision tree:

- **Phase 0b (clean-corpus validation):** run the same harness over public
  multi-episode audio with naturally labeled recurring speakers (solo-host
  podcasts/monologue channels; cross-episode same-host = positives, cross-host =
  negatives). If separation is good → the FluidAudio path is viable and meetings
  need post-AEC audio + a real calibration corpus (revisit after the #605 AEC
  work ships in 0.6.25-era recordings). If separation is poor → the offline
  `speakerDatabase` embedding path is insufficient; park the feature or evaluate
  `extractSpeakerEmbedding` over clean segments before abandoning.
- Either way, Phase 1 product code stays blocked until a calibration corpus
  passes the gate.

## Product Finding (out of scope for this gate, worth triage)

Of 463 present `microphone.m4a` files, only 22 have a valid container: verified
manually (outside the sandbox) that multi-MB files are missing their moov atom —
the writer was never finalized — alongside hundreds of 557-byte stubs. Likely
dominated by dev-kill iterations of the app, but if any fraction comes from real
crashes, those users' meeting audio is unplayable and unrecoverable. Relates to
the meeting finalize/recovery hardening work (#605-adjacent). Deserves a look:
does `MeetingRecordingRecoveryService` (or a repair pass) handle moov-less m4a?

## Caveats

- Biggest caveat: only 3 readable paired sessions met `duration >= 5 min`, so the
  requested >=30-session calibration is blocked by retained-media availability.
- Microphone over-clustering is severe: the known single-user channel appears as
  2-4 diarized speakers per full recording. This inflates same-user distance and
  may reflect diarizer instability, speaker bleed, channel changes, or all three.
- System split-half "same speaker" pairs are a nearest-neighbor proxy, not true
  labels; no participant ground truth exists in this corpus.
- Cross-meeting random system-speaker pairs can include recurring participants,
  which makes that negative population conservative.
- Source m4a files were never modified. Temporary normalized WAVs were written
  under `/tmp` and deleted by the harness.
