# Persistent Speaker Profiles (Voiceprints) — Research Synthesis + Implementation Plan

- **Date:** 2026-07-03
- **Status:** PROPOSED — pending Daniel's calls on §Open Questions and the Phase 0
  GO/NO-GO gate
- **Trigger:** issue #662 (yakov0922) + a Reddit voiceprint post aimed at MacWhisper;
  related demand in #430, #106
- **Research:** 5 delegated reports in
  [`docs/research/2026-07-03-speaker-voiceprints/`](../../docs/research/2026-07-03-speaker-voiceprints/)
  (repo dive with file:line evidence · FluidAudio 0.15.4 API · matching best
  practices · competitor prior art · biometric privacy)
- **Builds on:** [`docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md`](../../docs/plans/2026-06-14-002-speaker-diarization-world-class-architecture.md)
  (names "speaker memory" as the gap; this plan is its identity layer, made concrete)
  and [`plans/active/2026-05-speaker-diarization-quality.md`](2026-05-speaker-diarization-quality.md)

## Verdict

Build it, phased, opt-in. The core is small because every layer below it already
exists or arrives free:

- FluidAudio 0.15.4's offline diarizer already returns a **256-d WeSpeaker embedding
  per detected speaker** (`DiarizationResult.speakerDatabase`, per-segment
  `TimedSpeakerSegment.embedding`). No new model, no new runtime, no added latency.
- The 2026-06-14 architecture plan already defines the guardrails (suggestions never
  silently rewrite; wrong automatic names are worse than anonymous speakers; profiles
  must be deletable; don't grow `SpeakerInfo` into a pseudo-profile).
- Of nine competitors surveyed, only Otter and Circleback ship persistent voice
  identity — both cloud-side. MacWhisper, superwhisper, Granola, Fathom, Krisp,
  Apple: none. **On-device voiceprints are open competitive whitespace** aligned
  with the private-speech-memory north star.

Two real risks, both handled: (a) embedding separation quality on compressed meeting
system audio → Phase 0 calibration spike before any product code; (b) biometric
privacy → strict enrollment-only scope + consent gate + deletion controls.

## What exists today (repo-dive report)

- Diarization is centralized: `DiarizationService.diarize(audioURL:)`
  (`Sources/MacParakeetCore/Services/Diarization/DiarizationService.swift:101-157`),
  actor, ANEInferenceGate-wrapped, normalizes to `S1/S2` + `SpeakerInfo(id:,label:)`.
- Meeting path: mic track is identity-known (`speakerId = "microphone"` = Me); only
  the **system track** is diarized → `Others 1/2` (`TranscriptionService.swift:1266-1324`).
  Voiceprints only need to identify the *other* participants.
- File/URL path: diarize → `SpeakerMerger.mergeWordTimestampsWithSpeakers`
  (`TranscriptionService.swift:1397-1458`).
- Labels are structured, not baked into text: `transcriptions.speakers` JSON via
  `TranscriptionRepository.updateSpeakers` (`TranscriptionRepository.swift:433-439`).
  Rename UI: `TranscriptResultView.swift:2872-2990` → `TranscriptionViewModel.renameSpeaker`.
- Insertion points (exact): file path after `diarResult` returns, before merge
  (`TranscriptionService.swift:1446-1458`); meeting path after
  `diarizeMeetingSystemIfNeeded`, before `MeetingTranscriptFinalizer.finalize`
  (`TranscriptionService.swift:1099-1109`).
- Audio retention (`deleteImmediately`, "Remove Audio Only") means **backfill of old
  recordings cannot be assumed** → embeddings must be captured at transcription time.
- Speaker detection is opt-in, default off (`speakerDiarizationKey`,
  `AppRuntimePreferences.swift:501`).

## What FluidAudio gives us vs what we build (fluidaudio-api report)

| Layer | FluidAudio 0.15.4 | We build |
|---|---|---|
| Embeddings | ✅ 256-d WeSpeaker, L2-normalized, in every offline diarization result | — |
| Ad-hoc extraction | ✅ `extractSpeakerEmbedding(from:)` (enrollment from arbitrary clips) | — |
| Profile struct | ✅ `Speaker` + `RawEmbedding` are `Codable` (raw cap 50, centroid recompute, EMA update) | — |
| Persistence | ❌ `SpeakerManager` is in-memory only, and **explicitly unsupported with `OfflineDiarizerManager`** | GRDB store |
| Pre-matched diarization | ❌ offline labels are always fresh `S{n}` clusters | post-hoc matcher |
| Matching policy | partial (cosine *distance* utils; defaults 0.65 assign / 0.45 update) | thresholds + margin + duration gates, calibrated |

Scale warning: FluidAudio uses cosine **distance** (0 = identical; docs: <0.3
very-high confidence same speaker, 0.5–0.7 medium, >0.9 different). The Reddit
post's 0.80–0.90 same-speaker *similarity* numbers were pyannote-scale — do NOT
transplant them onto WeSpeaker. Hence Phase 0.

## Design

### Product shape (v1)

Enrollment flywheel, correction-based (the Otter/Circleback pattern, minus cloud):

1. User renames "Others 1" → "Sarah" in an existing meeting transcript (existing UI).
2. If "Remember speakers" is enabled: prompt "Remember this voice as Sarah? Future
   meetings will suggest her name automatically." First-ever enrollment shows the
   consent gate ("I have the participants' permission…").
3. Profile stored locally (embeddings only, never audio).
4. Next diarized recording: matcher compares detected-speaker embeddings against
   profiles → high-confidence matches surface as **suggestions** ("Looks like Sarah
   — confirm?"), never silent rewrites (2026-06-14 plan hard rule).
5. Confirmation applies the label via the existing rename path. Adding that
   meeting's embedding as a new profile sample is part of the confirm action's
   *disclosed* semantics ("Confirm and improve Sarah's voice profile") — samples
   are only ever added to already-enrolled profiles via this explicit act, so v1
   never retains voiceprints from ambient recordings for anyone unenrolled.
6. Unknowns stay "Others N". Below-margin matches stay unknown ("wrong automatic
   names are worse than anonymous speakers").

Scope call (recommended): v1 stores embeddings **only for explicitly enrolled
speakers**. The issue's literal ask — "this voice appeared in 5 recordings, name
them?" — requires retaining voiceprints of people nobody enrolled (ambient biometric
accumulation). That's Phase 3, a separate opt-in, decided later.

### Matching policy (matching-best-practices report; numbers are pre-calibration placeholders)

- Open-set: suggest only if `top1 distance ≤ τ` AND `top2 − top1 ≥ margin` (start
  grid: τ ∈ {0.35, 0.45, 0.55}, margin ≥ 0.10 — Phase 0 picks real values).
- Duration gates: embed only clean non-overlapped speech; per-speaker aggregate ≥3s
  usable, profile needs ≥15s total across ≥3 turns before it may suggest; never
  learn from <2s backchannels (snap those to the surrounding turn's label instead).
- Profiles: K ≤ 10 raw reference embeddings + recomputed centroid; score = max over
  references (preserves per-channel modes); samples added only on user confirmation
  (no silent EMA — poisoning/drift). **At most one sample per profile per
  recording** (the speaker-level aggregate): offline segment embeddings are
  cluster-derived from the same centroid, so storing several from one meeting
  would inflate `sampleCount` and fake diversity — K references should mean K
  distinct recordings/channels.
- Channel tags on every sample (`system`, `microphone`, `file`) — prefer
  same-channel references when scoring; channel mismatch is the default failure
  mode, not an edge case.

### Architecture

- **New GRDB migration + 2 tables** (repo-per-table convention):
  - `speakerProfile`: id UUID PK, name, centroid BLOB(256×Float32), sampleCount,
    createdAt, updatedAt, lastMatchedAt.
  - `speakerProfileSample`: id, profileId FK, embedding BLOB, durationSec, channel,
    sourceTranscriptionId, createdAt.
- **`SpeakerProfileService` actor** (`Sources/MacParakeetCore/Services/Diarization/`):
  `matches(for:channel:)`, `enroll(...)`, `recordConfirmation(...)`, `deleteProfile(...)`,
  `deleteAll()`. Pure-Swift cosine math (embeddings already L2-normalized → dot
  product); O(profiles × detected speakers) — microseconds, no scheduler involvement.
  **Adapter prerequisite:** today `DiarizationService.diarize()` drops FluidAudio's
  `speakerDatabase`/segment embeddings when building `MacParakeetDiarizationResult`
  — Phase 1's first change is surfacing per-speaker embeddings through that
  adapter (behind the feature flag), otherwise the matcher has nothing to score.
- **Assignment provenance**: per the 2026-06-14 plan, do NOT extend `SpeakerInfo`.
  New `transcriptions.speakerAssignments` JSON column keyed by speakerId:
  `{source: channel|diarization|userCorrection|profileSuggestion|profileConfirmed,
  profileId?, confidence?}`. `profileId`/`confidence` are sensitive identity
  metadata: default exports, diagnostics, and support bundles carry display
  labels only and omit/redact assignment metadata. Matching `spec/contracts/`
  doc updated in the same PR.
- **Wiring**: the two insertion points above.
- **Settings**: "Remember speakers" toggle (default off, requires speaker detection
  on) + profile list with per-profile delete + "Delete all voice profiles".
- **Privacy invariants**: profiles excluded from exports, diagnostics, and support
  bundles; deleting a profile never touches transcripts; profile store lives in the
  user DB (covered by existing user-data deletion rules).

## Privacy stance (privacy-biometrics report)

Voice embeddings built to recognize people ARE biometric data (BIPA names
"voiceprint"; GDPR Art. 9 explicit-consent territory; a 2026 Microsoft Teams BIPA
class action over speaker-ID voice data is live). Local-first flips this into a
differentiator, but honestly:

- Vendor risk (us): low — we never receive audio/embeddings/telemetry about them.
- User risk: real in workplace contexts (GDPR household exemption likely does NOT
  cover work meetings; BIPA has no household carveout). Surface it, don't bury it.
- Must-dos: (1) off-by-default + per-speaker explicit enrollment + "I have
  permission" acknowledgment; (2) local-only storage, per-profile delete, global
  wipe, excluded from every export path; (3) plain-language docs for business
  users; never claim embeddings are "anonymous"/"irreversible" (x-vector inversion
  research disproves it) — the true claim is "no audio stored, nothing leaves your
  Mac, delete anytime".

## Phases

- **Phase 0 — calibration spike (no product code, ~1–2 days).** Harness (hidden CLI
  subcommand or script) over Daniel's retained meeting corpus: run diarization,
  dump `speakerDatabase` embeddings per meeting, compute intra-/inter-speaker
  distance distributions across meetings + channels. Output: research report with
  separation evidence, chosen τ + margin, and a GO/NO-GO. Kills the feature
  cheaply if WeSpeaker can't separate on compressed system audio.
- **Phase 1 — core loop (meetings).** Migration + repositories + SpeakerProfileService
  + meeting-path matching + rename-triggered enrollment + suggestion UI
  (confirm/dismiss) + consent gate + settings toggle + tests (matcher math on
  fixture embeddings; service; migration; suggestion flow). Feature-flagged.
- **Phase 2 — breadth.** File/URL-transcription path (the Reddit author's
  185-episode podcast case), profile management UI, confirmation-driven
  multi-sample updates, spec/02-features + contracts + new ADR (promote the
  2026-06-14 plan's speaker-memory section), user-facing privacy docs, CLI
  `speakers list|delete` parity.
- **Phase 3 — judged later, each its own decision.** Recurring-unknown detection
  (the issue's literal "appeared in 5 recordings" ask — needs ambient embedding
  retention, separate opt-in); backfill scan over retained audio; live-path
  identity once live diarization (#430) ships; calendar-attendee hints (hints
  only, never authoritative).

## Open questions (Daniel)

1. **Always-confirm vs graduated auto-apply.** The 2026-06-14 plan says suggestions
   always require confirmation. Recommend: v1 strict confirm; consider opt-in
   auto-apply (with provenance chip + undo) only after dogfooding proves precision.
2. **Ambient embeddings for unnamed speakers** (enables the issue's exact UX +
   retro-matching): recommend NO for v1 — strictest consent posture, smallest
   surface.
3. **BIPA posture**: docs-only vs regional gating. Recommend docs-only + consent
   gate (indie, local-only, user-controlled).
4. **Podcast/file scope in v1 or v2**: recommend v2 (Phase 2) to keep Phase 1
   reviewable, even though it's the Reddit author's own use case.
