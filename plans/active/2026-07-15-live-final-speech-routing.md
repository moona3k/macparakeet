# Live Speech and Final Transcription Routing

> **Status:** IMPLEMENTED IN BRANCH — verification and PR review in progress
> **Priority:** P1 product clarity / P1 meeting-transcript trust
> **Branch:** `codex/live-final-speech-routing` from live `origin/main`
> **Risk:** HIGH — meeting recovery metadata, engine lifecycle, Settings, and final transcript provenance
> **Governing decisions:** ADR-014, ADR-016; this plan proposes narrow amendments to both

## 1. Outcome

MacParakeet exposes two speech-recognition roles rather than two loosely grouped
workflows:

1. **Live speech** — dictation and best-effort meeting live preview. Latency and
   readiness matter most. Parakeet remains the default.
2. **Final transcription** — authoritative post-meeting transcription plus
   file, drag/drop, media URL, podcast, and retranscription jobs. Accuracy and
   language coverage may matter more than latency.

Most users keep one engine for both roles. A collapsed Advanced control lets a
user opt into a different final-transcription engine. This is not a third
user-selectable meeting-preview route: meeting preview deterministically follows
the live-speech role when that engine supports the phase.

## 2. Why the Current Split Is Not the Final Product Seam

PR #783 correctly introduced independent routing infrastructure, but grouped
work by feature:

- `speechRecognitionEngine` -> dictation;
- `transcriptionSpeechRecognitionEngine` -> meetings, files, media, URLs, and
  retranscription.

That makes a meeting's ephemeral preview and authoritative final transcript use
one captured engine. It also means selecting a batch-only final engine such as
Cohere removes meeting preview, even when the already-resident dictation engine
could provide it.

The final transcript does not consume the live-preview transcript. It rereads
the durable recorded sources. The two phases therefore have different quality,
latency, persistence, and failure contracts and do not need one engine merely
because they belong to one meeting.

## 3. Current Truth to Preserve

- One process-wide `STTScheduler` and one `STTRuntime` remain non-negotiable.
- Dictation owns the interactive slot. Meeting finalization, live chunks, and
  file transcription share the background slot with existing priority and
  backpressure rules.
- Dictation final text continues to come from recorded-audio finalization; live
  dictation partials remain display-only.
- Meeting live preview remains best-effort and disposable. The saved final
  transcript remains authoritative.
- File/media/URL jobs snapshot their final route at job entry, before download.
- A meeting snapshots its speech plan at start and persists enough provenance
  for finalization and crash recovery.
- Existing user data and schema-v1/v2 recovery behavior remain readable.
- Model downloads remain explicit. Selecting a role cannot silently trigger a
  large download.
- Engine/model lifecycle work stays owned by `STTRuntime`; feature modules do
  not construct engines.
- The current ANE gate, scheduler lanes, Cohere single-flight rule, and
  per-engine activity accounting remain unchanged unless a failing test proves
  a required adjustment.

## 4. Intended Routing Contract

| Workflow phase | Route |
|---|---|
| Dictation preview | Live-speech selection, when supported |
| Dictation final paste/history | Live-speech selection |
| Meeting live preview | Meeting's captured live-speech selection, when supported |
| Meeting final transcription | Meeting's captured final-transcription selection |
| Meeting crash recovery | Captured final-transcription selection |
| File / drag-drop / URL / podcast | Final-transcription selection snapshotted at job entry |
| Retranscription without explicit override | Current final-transcription selection |
| CLI `--engine` override | Explicit per-invocation selection, unchanged |

There is no hidden Parakeet fallback. If the chosen live-speech engine cannot
produce meeting preview, the UI says preview is unavailable. This avoids silent
language mismatch and misleading provenance.

## 5. Preference and Migration Semantics

Keep the existing persisted keys to avoid a preference migration:

- `speechRecognitionEngine` becomes explicitly documented as the live-speech
  engine.
- `transcriptionSpeechRecognitionEngine` becomes explicitly documented as the
  optional final-transcription override.

Add one preference interface that hides key-presence details:

- `liveSpeech(defaults:)`
- `finalTranscription(defaults:)` -> explicit override or live speech
- `hasFinalTranscriptionOverride(defaults:)`
- `saveFinalTranscriptionOverride(_:defaults:)` -> save a value or clear it

Fresh installs and users with no second key see **Same as live speech**. Existing
users with a different persisted transcription engine retain it as an enabled
Advanced override. Clearing the Advanced toggle removes the second key so later
live-engine changes continue to flow through automatically.

## 6. Proposed Core Interface

```swift
public struct MeetingSpeechPlan: Codable, Equatable, Sendable {
    public let preview: SpeechEngineSelection?
    public let final: SpeechEngineSelection
}
```

A small resolver is the single seam for product policy:

```swift
MeetingSpeechPlan.resolve(
    live: SpeechEngineSelection,
    final: SpeechEngineSelection,
    liveCapabilities: SpeechEngineCapabilities
)
```

The resolver returns `preview == live` only when the capability registry says
the engine supports meeting live preview; otherwise `preview == nil`. It never
selects an unrelated fallback.

Callers should not independently reimplement preview eligibility or fallback
rules. Tests use this public interface as the primary policy seam.

### Capability correction

Add an explicitly named computed capability,
`supportsMeetingLivePreview`, derived from `providesWordTimestamps` in this PR.
The existing preview renderer requires words with timings, so a separately
stored flag would duplicate an invariant without enforcing it. The named
property gives workflow code a semantic policy seam now and can become
independent registry data, with a totality test, when an engine actually makes
the two facts diverge. Initial behavior remains:

| Engine/build | Meeting preview |
|---|---|
| Parakeet v2/v3/Unified | Supported |
| Nemotron multilingual/English | Supported |
| Whisper | Supported through current chunked batch path |
| Cohere | Unsupported |

## 7. Meeting Capture, Finalization, and Recovery

At meeting start:

1. Resolve the live preference and acquire the existing scheduler session lease
   unconditionally, even if that engine cannot preview. The lease captures the
   actual live selection/capabilities and keeps engine and variant switching
   blocked for the session.
2. Resolve the final preference.
3. Resolve one immutable `MeetingSpeechPlan` from the lease-captured live
   selection/capabilities plus the final selection.
4. Warm only `plan.preview`, if present.
5. Route live chunks only through `plan.preview`.
6. Persist `plan.final` in the existing lock field and, after stop, persist
   `plan.preview` as optional archived provenance.

At stop:

- durable audio/lock behavior is unchanged;
- release the active meeting lease at the existing durable-stop boundary;
- enqueue authoritative final STT with `plan.final`;
- never reuse live-preview text as final output.

At recovery:

- new artifacts use the captured final selection;
- schema-v2 artifacts map their one captured engine to final transcription and
  retain legacy semantics;
- schema-v1 artifacts retain the current behavior of following the current
  final-transcription preference because their old `speechEngine` field was not
  independent-route provenance.

### Persistence decision

Keep `MeetingRecordingLockFile` at schema v2 with no new preview field. Its
existing `speechEngine` remains the captured engine for authoritative
finalization and crash recovery. This is required for downgrade safety:
`MeetingRecordingLockFileStore.read()` rejects schema versions newer than the
reader, so a v3 development lock would become invisible to the current stable
app's recovery, CLI active-session checks, and destructive-retention guards.

Add optional `previewSpeechEngine` provenance only to post-stop
`MeetingRecordingMetadata` using tolerant `decodeIfPresent` behavior. Preview
is never recovered, so a crashed meeting correctly retains final-only
provenance. Do not introduce nested `speechPlan` persistence.

## 8. Exact Variant Provenance

`SpeechEngineSelection` currently stores engine plus language, not the concrete
Parakeet/Nemotron/Whisper variant. The lease captures capabilities for the
current variant, while recovery can later run a different build of the same
engine.

This plan will not silently claim that an exact model build is pinned. Before
implementation, choose one:

- **Narrow:** continue pinning engine/language only; use precise “engine” copy
  and persist the actual result's `engineVariant` as today.
- **Expanded:** add a variant key to a new immutable routed configuration and
  teach the runtime to honor it per job.

The narrow option is chosen. The expanded option is substantially larger
because the runtime currently owns one mutable variant per engine. Fable
confirmed there is no provenance violation: `STTResult.engineVariant` records
the build that actually produced the result. Recovery-time build drift remains
a quality consideration, not falsely recorded provenance.

## 9. Loading and Readiness Policy

### Live speech

Selecting a new live engine keeps the current transactional switch:

- validate/download prerequisites first;
- prepare the target while the old engine remains usable;
- commit the preference only on success;
- expose progress and final Ready state;
- release the previous live engine after commit.

### Final transcription

Selecting an installed final engine is persist-only:

- do not eagerly load a second large runtime from the Settings click;
- show `Downloaded - loads when needed` rather than implying in-memory Ready;
- load/warm when a file reaches STT or when post-stop meeting finalization starts;
- keep an optional explicit `Prepare now` action out of this PR unless existing
  UI patterns make it nearly free.

With preview following live speech, meeting recording no longer starts a cold
final engine merely to obtain preview. A cold final model may extend post-stop
processing, which is the accepted accuracy-over-latency trade-off and must be
shown in finalization progress.

If the captured final model is deleted during a meeting, or cold loading fails
at finalization/recovery, the saved audio and meeting row remain durable. Mark
the transcription failed with the existing actionable error/retry surface;
retry or retranscription may use the captured route once restored or an
explicit current override. Never silently fall back to another engine.

## 10. Settings Information Architecture

Default Engine-tab order:

1. **Live Speech** card
   - four existing engine tiles;
   - subtitle: `Used for dictation and meeting live preview.`;
   - current loading/ready behavior remains visible.
2. Current live engine's relevant model/language configuration.
3. **Advanced** disclosure/card
   - toggle: `Use a different engine for final transcripts`;
   - collapsed by default;
   - when enabled, compact final-engine picker;
   - copy: `Used after meetings end and for files, media, URLs, and retranscription.`;
   - status: `Downloaded - loads when needed` or the existing not-downloaded
     requirement/error;
   - engine-specific limitation copy, especially Cohere's plain-text/no-timing
     result.
4. Local model management.

The default page must not show two equal-weight engine selectors. If live and
final differ, do not automatically stack every model-specific card at the top
level. The Advanced disclosure owns configuration that exists only because of
the override. Reuse existing cards/components; do not combine this product
change with the remaining Settings god-view decomposition plan.

During a meeting, the panel must show concise attribution when engine or
language routes differ:

- `Live preview: Parakeet`
- `Final transcript: Cohere after recording ends`

This is a trust requirement: the user must understand that preview wording can
change when authoritative post-stop transcription uses a different route.

## 11. Test Seams and Vertical Slices

The user approved the live-versus-final architecture. Tests will be written
through these agreed seams:

1. `SpeechEnginePreference` final-override interface.
2. `MeetingSpeechPlan.resolve(...)` policy interface.
3. `MeetingRecordingService` observable session/output interface.
4. Lock/metadata Codable round-trip and recovery interface.
5. `TranscriptionService` routed final-job interface.
6. `EngineSettingsViewModel` preference and validation interface.

Vertical red -> green slices:

### Slice A — preference override

- no override follows later live-engine changes;
- explicit override remains independent;
- disabling the override removes persisted state;
- existing persisted second key is recognized.
- an explicit override equal to the current live engine still counts as
  override-on because key presence, not value inequality, is the durable signal.

### Slice B — explicit meeting-preview capability and plan resolver

- Parakeet live + Cohere final -> Parakeet preview, Cohere final;
- Cohere live + Whisper final -> no preview, Whisper final;
- same engine -> both roles use that engine where preview is supported;
- registry totality covers every engine/build.

### Slice C — meeting capture routing

- service captures the plan once at start;
- live chunks route through preview selection;
- no preview chunks are submitted when preview is nil;
- stopped output carries the captured final selection;
- changing Settings after start does not alter either captured role.

### Slice D — persistence and recovery

- lock schema remains v2 and existing unknown-key forward compatibility holds;
- v2 maps its captured engine to final selection;
- v1 remains uncaptured and follows current final preference during recovery;
- metadata round-trip preserves optional preview provenance without breaking
  old data;
- a captured final model missing at recovery surfaces a durable, retryable
  failure without fallback or artifact loss.

### Slice E — final transcription routing

- meeting finalization uses captured final selection, not preview/live setting;
- file/URL/retranscription behavior remains on the final route;
- URL selection remains snapshotted before download.
- final-engine cold-load failure surfaces the existing failed/retry state while
  preserving the meeting artifact.

### Slice F — Settings UX

- default state is same-as-live with Advanced override off;
- enabling/disabling and selecting final engine persist correctly;
- unavailable models cannot become final overrides;
- search finds the Advanced final-transcription control;
- visible copy distinguishes loaded-now from loads-when-needed.

## 12. Documentation and Contract Updates

Update in the same PR:

- `Sources/MacParakeetCore/STT/README.md`
- `spec/02-features.md`
- `spec/03-architecture.md`
- `spec/04-ui-patterns.md`
- `spec/05-audio-pipeline.md`
- `spec/06-stt-engine.md`
- `spec/08-error-handling.md` if loading/fallback language changes
- `spec/adr/014-meeting-recording.md`
- `spec/adr/016-centralized-stt-runtime-scheduler.md`
- `spec/contracts/meeting-recovery-retention.md` — clarify that lock
  `speechEngine` is the captured final/recovery selection; schema remains v2
- `spec/contracts/meeting-artifacts-v1.md` — document optional archived preview
  provenance if the metadata field is added
- `docs/telemetry.md` — document `same_as_live` when the Advanced override is disabled

ADR-020 remains unchanged because `recording.lock` does not change.

Do not create new legacy REQ IDs.

## 13. Verification Gates

Focused iteration only:

- `SpeechEnginePreferenceTests`
- `SpeechEngineCapabilitiesTests`
- `EngineSettingsViewModelTests`
- `MeetingRecordingServiceTests`
- `MeetingRecordingLockFileStoreTests`
- `MeetingRecordingOutputTests` (the existing metadata round-trip home)
- `MeetingRecordingRecoveryServiceTests`
- `MeetingRecordingFlowCoordinatorTests`
- `TranscriptionServiceTests`
- `SettingsSearchIndexTests`
- relevant CLI/spec tests if public machine-readable output changes

Final gates:

1. `git diff --check`
2. `scripts/dev/format.sh` / `swift-format lint` per repository policy
3. one full `swift test`, once
4. `no-mistakes` with explicit intent if available
5. committed-diff code review, Greptile/reviewer follow-ups until findings
   converge
6. hosted CI on the exact PR head

Manual smoke before merge when the dev app is available:

- Parakeet live + Cohere final: meeting preview appears; final transcript runs
  through Cohere after stop and displays the expected plain-text limitation.
- Parakeet live + Whisper final: dictation stays ready while a file job uses
  Whisper.
- Same-as-live default: behavior matches the pre-split Parakeet experience.
- Change Advanced final selection during an active meeting: current meeting
  remains pinned; next meeting/job uses the new route.

## 14. Non-Goals

- No second scheduler/runtime.
- No third user-selectable meeting-preview engine.
- No hidden engine fallback.
- No cloud STT.
- No engine-adapter refactor.
- No change to dictation's recorded-audio final authority.
- No reuse of live meeting text as saved final text.
- No Settings god-view decomposition beyond the minimum needed for this UX.
- No broad exact-variant routing work.

## 15. Questions for Fable

1. Is live speech versus final transcription the correct durable product seam,
   or is there a stronger argument for keeping one engine throughout a meeting?
2. Should meeting preview always follow live speech, or should it prefer the
   final engine when that engine supports preview?
3. Is `MeetingSpeechPlan` a sufficiently deep module, and where should its
   interface live?
4. Should persistence remain additive (`speechEngine` final plus optional
   preview), or move to a nested versioned plan?
5. Is exact variant pinning required in this PR, or is engine/language pinning
   plus honest wording the right scope?
6. Is lazy loading for the final engine the right default given latency, memory,
   and user expectation?
7. Does the proposed Advanced Settings disclosure hide the right complexity
   without making the override undiscoverable?
8. What is the strongest failure mode or migration case this plan has missed?
