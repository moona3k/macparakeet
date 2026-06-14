---
title: World-Class Speaker Diarization and Identification Architecture
status: PROPOSED
date: 2026-06-14
authors: Codex/GPT, Daniel Moon
---

# World-Class Speaker Diarization and Identification Architecture

> Status: **PROPOSED** - architecture review and implementation sequence.
> Evidence date: 2026-06-14.
> Related research:
> `docs/research/speaker-diarization-frontier-2026-06.md`.
> Related current docs/specs:
> `spec/adr/010-speaker-diarization.md`,
> `spec/06-stt-engine.md`,
> `docs/research/meeting-dual-stream-transcription-pipeline.md`.

## Executive Thesis

MacParakeet is not missing a diarization module. It already has a strong
anonymous, local, final-pass diarization foundation:

- `DiarizationService` wraps FluidAudio offline diarization behind a small
  module interface.
- File/URL transcription runs ASR, runs diarization when requested, and merges
  word timestamps with speaker segments.
- Meeting recording preserves `microphone.m4a` and `system.m4a`, finalizes from
  those source files, and only uses system-side diarization additively.
- The UI supports per-transcript speaker label renaming.
- CLI, JSON, artifacts, exports, LLM context, and meeting records already carry
  at least some speaker metadata.

The gap to frontier, world-class capability is **speaker memory**, not ASR and
not a Python diarization stack.

The target architecture should be:

```text
source attribution
  -> anonymous diarization
  -> durable speaker assignments
  -> user correction
  -> opt-in local speaker profiles
  -> post-stop identity suggestions
  -> unified rendering/export
  -> benchmarked trust loop
```

World-class here means users can trust the app:

- it keeps source truth (`Me` vs system/Others) when that is stronger than
  acoustic clustering
- it labels speakers consistently inside a transcript
- it lets users fix wrong labels, merges, splits, and turn assignments
- it can remember confirmed speakers across meetings only after opt-in
- it suggests names with confidence instead of silently asserting identity
- it preserves corrections through reprocessing
- it exposes the same speaker truth to GUI, CLI, artifacts, exports, and LLM
  context
- it measures wrong-name risk, not just DER

## Current Architecture Review

### Strengths To Preserve

**1. Source-aware meeting finalization is the right base.**

Meeting recording already avoids the common failure mode of diarizing a mixed
meeting artifact. It transcribes microphone and system tracks separately, then
merges by persisted alignment. The final transcript can keep `microphone` as
`Me` and split only `system` into `system:S1`, `system:S2`, etc.

This is stronger than blind diarization because source attribution is a harder
signal than clustering. Do not regress this.

**2. Batch diarization is a deep enough module for v0.**

`DiarizationServiceProtocol` gives callers one meaningful interface:

- prepare speaker models
- report readiness/cache state
- diarize a WAV into anonymous speakers and segments

Callers do not need to know about FluidAudio model bundles, segmentation,
embeddings, VBx, or chronological ID normalization. That module earns its keep.

**3. Speaker labels are already display metadata, not word rewrites.**

`WordTimestamp.speakerId` stores stable IDs. `Transcription.speakers` maps
those IDs to labels. Rename updates the label mapping rather than rewriting
every word. That is the right shape for per-transcript display labels.

**4. Artifacts and CLI are already part of the speaker contract.**

Meeting artifacts include transcript JSON with speaker fields, and CLI
commands expose speaker detection/model readiness. This matters because
MacParakeet is already agent-facing, not just a GUI app.

### Architectural Friction

**1. `SpeakerInfo` is too shallow for identity.**

`SpeakerInfo` is currently `{id, label}`. That is enough for anonymous
per-transcript labels and not enough for:

- local speaker profiles
- identity confidence
- user confirmation state
- assignment provenance
- embedding model/version
- speaker deletion
- profile merge/split
- "remember this speaker"
- preserving labels after retranscription

Do not grow `SpeakerInfo` into a pseudo-profile. Keep it as a display adapter.

**2. Corrections are label-only.**

The current correction loop is "rename `S1` to Alice." It cannot:

- merge two diarized speakers
- split one speaker into two
- reassign a selected turn or range
- mark a label as uncertain
- preserve labels through retranscription
- convert a confirmed rename into an opt-in speaker profile

For world-class speaker support, correction is a first-class domain, not a text
field.

**3. Identity would sprawl if added inside `TranscriptionService`.**

`TranscriptionService` already owns audio conversion, ASR orchestration,
diarization, telemetry, URL/media handling, post-processing, meeting
finalization, and artifact refresh. Adding speaker profiles, embeddings,
thresholds, and correction persistence there would reduce locality.

Identity needs its own module after finalization, not more logic inside the
transcription orchestrator.

**4. Speaker rendering is duplicated.**

Speaker label formatting appears in export code, CLI text output, meeting
commands, LLM context formatting, SwiftUI transcript views, and meeting
artifacts. That duplication is tolerable for `{id,label}` but will fail once
labels can be confirmed, suggested, tentative, or unknown.

**5. Runtime/docs default posture is inconsistent.**

Current code defaults speaker detection off. ADR-010 and some spec text still
describe speaker detection as on by default or readiness-gated when default-on.
Before changing product posture, align the documents and code deliberately.

**6. There is no trust benchmark.**

Current tests cover pieces: mock diarization, merge-by-overlap, meeting
system-side diarization, export speaker labels, and rename persistence. They do
not measure the product risks that matter for speaker identity:

- wrong-name rate
- unknown-speaker handling
- correction persistence after retranscription
- identity threshold behavior
- overlap and source bleed
- CLI/artifact parity for identity fields

## Target Modules

The following modules are the deepening opportunities. The names are proposed
architecture names, not committed Swift protocols.

### 1. `SpeakerIdentity`

**Role:** Own local speaker profiles, voice embeddings, consent, deletion, and
profile lifecycle.

**Files likely involved:** `spec/01-data-model.md`, `DatabaseManager`, new
models/repositories under `Sources/MacParakeetCore/Database/` and
`Sources/MacParakeetCore/Models/`.

**Data it should own:**

- speaker profile display name
- profile aliases or previous display names
- profile creation/update/deletion
- consent/enrollment source
- embedding vectors and model identifiers
- profile merge/delete semantics

**Interface responsibility:** callers ask for profile-backed labels,
suggestions, and deletion/enrollment operations. Callers should not know vector
dimensions, threshold details, or how many embeddings a profile has.

**Leverage:** GUI, CLI, meeting artifacts, export, and LLM context can all
refer to the same speaker identity contract.

**Locality:** voiceprint privacy, consent, deletion, and false-name recovery
live in one place.

### 2. `SpeakerAssignmentPipeline`

**Role:** Convert finalized anonymous speaker data into durable assignments and
optional identity suggestions.

**Seam:** after file transcription diarization and after
`MeetingTranscriptFinalizer.finalize`, before artifact/export surfaces consume
the transcript.

**Inputs it should understand:**

- words with source-aware or diarized `speakerId`
- diarization segments
- source artifact information
- existing local speaker profiles
- user-configured speaker hints, if any

**Outputs it should own:**

- assignment source: `channel`, `diarization`, `userCorrection`,
  `profileSuggestion`, `profileConfirmed`
- confidence
- display label
- profile ID when confirmed or suggested
- uncertainty/tentative state

**Leverage:** identity logic becomes reusable across file, YouTube, saved
meeting retranscription, immediate meeting finalization, and future agents.

**Locality:** assignment bugs do not spread into STT, meeting recording, export,
or SwiftUI.

### 3. `SpeakerCorrection`

**Role:** Represent user corrections as operations, not just label mutations.

**Operations to support:**

- rename anonymous speaker in one transcript
- remember speaker as a local profile
- link anonymous speaker to existing profile
- reject a suggested profile
- merge diarized speakers
- split a diarized speaker
- reassign a turn or selected range
- clear profile assignment while keeping local label

**Important invariant:** corrections must survive retranscription when the
underlying audio artifact remains available. A new diarization pass can produce
new anonymous IDs; correction replay should map old intent onto the new result
where possible.

**Leverage:** a single correction model improves UI, CLI, artifact JSON, and
future agent workflows.

### 4. `SpeakerEmbeddingAdapter`

**Role:** Hide model-specific embedding extraction and enrollment.

**Initial adapter:** FluidAudio only.

FluidAudio now exposes relevant local capabilities:

- offline diarization `speakerDatabase` with per-speaker embeddings
- embedding export paths
- streaming diarizer enrollment APIs
- finalized/tentative diarizer timelines

Do not create a public multi-provider interface yet. One adapter is a
hypothetical seam; two adapters make it real. Keep model specifics internal to
the identity module until a benchmark harness or second local model requires a
broader seam.

### 5. `SpeakerRenderPlan`

**Role:** Build one canonical speaker-aware transcript representation for:

- SwiftUI transcript views
- CLI text/json output
- TXT/Markdown/SRT/VTT/PDF/DOCX export
- meeting artifact JSON/Markdown
- LLM rich transcript context
- agent-facing commands

**Problem it solves:** today each surface decides independently how to map
`speakerId` to label and when to emit speaker turns. That will break once
speaker state includes suggested/confirmed/tentative/unknown labels.

**Interface responsibility:** callers provide a transcript and desired output
mode; the module returns speaker-aware turns/cues with labels, colors or style
tokens, confidence/provenance metadata, and export-safe strings.

### 6. `SpeakerTrustBenchmark`

**Role:** Evaluate the system before changing defaults or shipping identity.

Metrics should include:

- DER or equivalent diarization error when ground truth exists
- speaker-count error
- word-speaker assignment accuracy
- wrong-name rate
- unknown-speaker rate
- correction replay success after retranscription
- overlap handling
- runtime and memory
- CLI/artifact/export parity

This is not just an ML benchmark. It is a product trust benchmark.

### 7. `LiveSpeakerPreview`

**Role:** Optional tentative live speaker turns.

This should come after the identity/correction substrate, not before it.

Recommended path:

- first experiment with FluidAudio `LSEENDDiarizer` for system-side live
  speaker turns
- use `SortformerDiarizer` only for known <=4-speaker scenarios
- mark all live speaker labels as tentative
- keep final post-stop batch diarization canonical
- never let live labels overwrite final assignments without reprocessing

## Proposed Data Shape

Exact migrations should be designed in an implementation pass, but the durable
shape should be table-backed:

```text
speaker_profiles
  id
  displayName
  aliases
  enrollmentState
  consentSource
  createdAt
  updatedAt
  deletedAt

speaker_embeddings
  id
  speakerProfileId
  modelIdentifier
  vector
  vectorDimension
  qualityScore
  sourceTranscriptionId
  sourceSpeakerId
  createdAt

speaker_assignments
  id
  transcriptionId
  diarizedSpeakerId
  speakerProfileId
  displayLabel
  confidence
  assignmentSource
  userConfirmedAt
  rejectedAt
  createdAt
  updatedAt

speaker_corrections
  id
  transcriptionId
  operation
  target
  payload
  createdAt
```

Keep `transcriptions.speakers` for backward-compatible display labels. Treat
it as a denormalized read model generated from assignments, not the source of
identity truth.

## Implementation Sequence

### Phase 0: Align The Contract

Scope: docs, tests, small contract fixes.

1. Decide and document whether speaker detection defaults on or off.
2. Align `ADR-010`, `spec/06-stt-engine.md`, `spec/02-features.md`, CLI help,
   and Settings copy with that decision.
3. Fix speaker export parity gaps:
   - `export --format txt --stdout` should use the same speaker-aware text path
     as file export.
   - `meetings transcript --format json` should include `speakerCount` and
     `diarizationSegments`.
   - `meetings export --format md` should preserve speaker turns when speaker
     data exists.
4. Add missing tests for file transcription with injected mock diarization,
   speaker metadata round trips, and CLI stdout parity.

Why first: it raises trust immediately and prevents the next phases from
building on an ambiguous contract.

### Phase 1: Add Speaker Identity Storage Without Auto-Identification

Scope: schema, repositories, display model, no voice matching yet.

1. Add `SpeakerProfile`, `SpeakerAssignment`, and correction storage.
2. Add "Remember this speaker" as an explicit action from the existing rename
   flow.
3. Persist profile links and confirmed labels.
4. Export `profileId`, `assignmentSource`, and confirmation state in JSON
   surfaces while preserving old `speakers` fields.
5. Add deletion controls for local speaker profiles and embeddings, even before
   embeddings exist.

Why second: it builds the privacy and correction contract before any model can
suggest names.

### Phase 2: Post-Stop Identity Suggestions

Scope: embeddings, conservative matching, pending suggestions.

1. Use FluidAudio embeddings from final diarization output or a narrow
   FluidAudio embedding adapter.
2. Aggregate clean spans per diarized speaker.
3. Compare against local speaker profiles.
4. Emit pending suggestions with confidence.
5. Require confirmation before a suggestion becomes a profile assignment.
6. Treat calendar/meeting metadata as hints only, never ground truth.

Failure rule: a model may suggest "Looks like Alice"; it must not silently
rewrite the transcript to "Alice" without confirmation.

### Phase 3: Correction Tools

Scope: world-class editing workflow.

1. Make speaker labels editable directly on speaker turns, not only in the
   overview panel.
2. Add merge speakers.
3. Add split speaker.
4. Add reassign selected turn/range.
5. Add reject suggestion / mark unknown.
6. Replay corrections after retranscription when the source audio is still
   present.

This is the phase that moves MacParakeet from "has diarization" to "users can
trust and repair diarization."

### Phase 4: Unified Rendering

Scope: reduce output drift.

Build `SpeakerRenderPlan` and migrate:

- `ExportService`
- `TranscribeCommand`
- `MeetingsCommand`
- `TranscriptAIContextFormatter`
- `TranscriptTimestampedContentView`
- `MeetingArtifactStore`

The render plan should encode label state consistently:

- source label (`Me`, `Others`)
- anonymous diarized label (`Speaker 1`, `Others 1`)
- confirmed profile label (`Alice`)
- suggested profile label (`Looks like Alice`)
- unknown/low-confidence label
- tentative live label

### Phase 5: Benchmark Harness

Scope: local fixtures and trust metrics.

Build before changing diarization defaults or enabling identity suggestions by
default. At minimum, include:

- clear two-speaker file
- noisy two-speaker file
- overlap sample
- meeting-like mic/system separated fixture
- system-side multi-speaker meeting fixture
- retranscription/correction replay fixture

The harness should run without touching the user's real database or audio
library.

### Phase 6: Tentative Live Speaker Preview

Scope: feature-flagged experiment.

1. Start with system-side `LSEENDDiarizer`.
2. Show tentative speaker turns during recording.
3. Flush/finalize the streaming session at stop only for preview continuity.
4. Run the existing canonical final pass after stop.
5. Compare live preview against final output in the benchmark harness.

Do not build this before correction/profile storage exists. Live diarization
without repair tools creates more apparent intelligence than real trust.

## Product Rules

- Source attribution beats acoustic clustering when source separation exists.
- `Me` from microphone source attribution should remain the default meeting
  truth.
- System-side diarization should refine `Others`, not replace the source model.
- A voiceprint can suggest identity only after explicit local enrollment.
- A suggestion is not a confirmed label.
- Wrong automatic names are worse than anonymous speakers.
- Voice profiles are local sensitive data and must be deletable.
- Final post-stop diarization remains canonical.
- Live diarization is tentative.
- Commercial/cloud diarization is a benchmark reference, not the default
  product architecture.

## What Not To Build

- Do not add Python WhisperX or pyannote runtime to the app core.
- Do not use cloud diarization as the main architecture.
- Do not diarize mixed `meeting.m4a` when source files are available.
- Do not add identity/profile fields directly into `SpeakerInfo` until it
  becomes a leaky pseudo-profile.
- Do not default to mic-side diarization for meetings; the microphone source is
  already the user's `Me` track.
- Do not make calendar attendees or meeting detection metadata authoritative
  speaker names.
- Do not expose a multi-provider embedding interface before there is a second
  real adapter.
- Do not ship speaker identity without deletion and opt-in consent controls.

## First PR Sequence

Recommended first implementation sequence:

1. Contract cleanup PR: docs/default decision, CLI/export speaker parity,
   missing tests around current diarization.
2. `SpeakerIdentity` storage PR: migrations, repositories, profile/assignment
   models, JSON export additions, no model matching.
3. UI correction PR: direct speaker-turn rename, remember-speaker action,
   visible persistence errors, profile deletion surface.
4. Embedding/suggestion PR: FluidAudio embedding adapter, conservative
   suggestions, confirmation/rejection flow.
5. Render plan PR: migrate duplicated speaker formatting into a shared module.
6. Benchmark PR: fixtures, trust metrics, comparison reports.
7. Live preview PR: LS-EEND tentative system-side speaker turns behind a flag.

## Open Questions

- Should speaker detection default remain off for speed/privacy clarity, or
  become on for files/meetings after readiness and correction UX improve?
- Should identity profiles be allowed for file transcriptions, meetings only,
  or both?
- What is the minimum UI for profile consent: "Remember this speaker" only, or
  a dedicated Speaker Profiles settings page from the first release?
- How should corrections replay when diarization changes speaker count after a
  retranscription?
- Should speaker profile data be included in JSON export by default, or only
  when the user requests identity metadata?

## Recommendation

The highest-leverage path is:

```text
Phase 0 contract cleanup
  -> Phase 1 speaker identity storage
  -> Phase 2 post-stop suggestions
  -> Phase 3 correction tools
  -> Phase 4 unified rendering
  -> Phase 5 benchmark harness
  -> Phase 6 tentative live preview
```

This keeps MacParakeet aligned with the frontier without losing its core
advantage: native, local-first, durable, user-correctable meeting memory.
