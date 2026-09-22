# Audio Speaker Timeline v1

> Status: **Planned; not implemented.** Accepted direction for [issue #836](https://github.com/moona3k/macparakeet/issues/836), 2026-09-14.
> Governing decision: [ADR-010](../adr/010-speaker-diarization.md#audio-speaker-timeline-decision-2026-09-14).
> Implementation: [speaker timeline plan](../../docs/plans/2026-09-14-2147-feat-audio-speaker-timeline-plan.md).

## Purpose and scope

Let users inspect when detected speakers spoke and seek to those intervals even when the speech engine returns no word timings.
Cohere is the motivating case, but availability depends on successful audio analysis, not the engine name.
The timeline describes anonymous audio clusters; it does not establish which words a person said.

This contract specifies the intended implementation, not an addition already available in the app, database, CLI, or meeting artifacts.
Existing text, word timing, speaker corrections, and export contracts remain current until the implementation lands with their focused tests.

## Producers and coverage

Keep the current sequential ASR-then-diarization order, FluidAudio offline service, model readiness, inference gate, speaker-count policies, and saved workflow preferences.
Remove the word-availability prerequisite for audio analysis in file/URL transcription; retain it for word-to-speaker merging.

| Input path | Timeline source | Coverage and clock |
|---|---|---|
| File/media URL | `fileAudio` | The selected audio track used for ASR; time zero is the playable source origin. |
| Meeting with archived aligned sources | `isolatedSystemAudio` | Only the isolated system track; shift intervals onto meeting playback time using its persisted offset exactly once. |
| Canonical-only saved/imported/split meeting | `canonicalMeetingAudio` | The existing single-file transcription path's canonical audio; not isolated system audio. |

The canonical-only row describes an existing fallback path, not permission to replace isolated-source analysis with mixed playback when archived sources exist.
An archived microphone-only meeting has no speaker timeline in this milestone.
Do not infer microphone speech from track duration, invent a `Me` turn, or treat a source/channel as a detected person.
Dictation, live preview, new voiceprint enrollment, and new diarization runtimes are outside this contract.

## Stable payload

Add an optional `audioSpeakerTimeline` object to a transcription, stored in a nullable JSON column of the same name.
It has an independent roster because effective text corrections may rename, merge, or remove entries in the existing transcript roster.

| Field | Meaning |
|---|---|
| `schemaVersion` | Integer `1`. |
| `analysisId` | Fresh UUID string for each successfully materialized analysis, including an empty result; retained unchanged on subsequent reads. Not a person identifier. |
| `pipelineRevision` | The producing `DiarizationService.pipelineRevision`; no unsupported quality claim. |
| `source` | One of the source values in the coverage table. |
| `coverageStartMs`, `coverageEndMs` | Half-open analyzed source envelope on the recording's playback clock, derived from inspected audio duration and persisted alignment, not from words. This is analyzed coverage, not a claim of uninterrupted speech or healthy capture. |
| `speakers` | Array of `{id, label}` for detected clusters referenced by valid turns, in first-occurrence order; automatic labels only in v1. |
| `segments` | Array of `{speakerId, startMs, endMs}` with half-open playback-relative integer millisecond intervals. Every ID resolves within this payload's roster. |

There is no independent speaker-count field: the count is the roster length.
Generated IDs and labels belong to one analysis; neither equality across recordings nor equality across retranscriptions implies identity.
Do not include embeddings, profile identifiers, attendee information, file paths, or audio bytes in this payload.

### Validation

- Validate finite source times before conversion to integer milliseconds; reject invalid numeric values without a trapping conversion.
- Require a nonnegative coverage start and a finite positive inspected source duration. Apply checked offset arithmetic once, then constrain coverage to the known playable recording envelope.
- Intersect turns with analyzed coverage, discard zero-length or wholly out-of-range turns, and sort deterministically by start, end, then speaker ID. Drop unused roster entries; reject dangling IDs or duplicate roster IDs as invalid analysis.
- If a nonempty producer result loses every interval during validation, treat it as an analysis failure, not as proof that no speakers were detected.
- Preserve overlaps the producer emits; do not create overlap that the producer omitted. The v1 UI shows intervals, not percentages, total speaking time, or per-speaker word counts.
- A successful empty/no-speech result has empty roster and segments. Missing, skipped, failed, unsupported, and legacy analysis have no payload; absence does not encode a specific reason.

## Persistence and lifecycle

Persist the timeline with its successful transcription snapshot through the GRDB repository completion transaction.
A new transcript remains usable when optional diarization fails; surface a non-blocking failure notice for the current operation, with no new timeline.
Cancellation still propagates through the existing job lifecycle and must not save a partially analyzed result as complete.

Retranscription builds a fresh candidate with no old timeline.
Failure or cancellation before replacement preserves the previous saved transcript and its timeline.
A successfully committed replacement uses only its new analysis, or no timeline when detection was disabled or failed; never attach a prior run's turns to replacement text/audio.
Preserve concurrent user metadata and the repository's refusal to recreate a deleted recording.

Do not backfill old rows from `diarizationSegments`: files, meetings, and corrected projections have different historical semantics for that field.
Old rows remain readable with no timeline; the existing explicit retranscription flow can create one when suitable audio remains.
Do not scan or reprocess the library automatically.

Speaker/text corrections and Undo/Redo must preserve this payload byte-for-byte in effective projections.
The audio timeline remains automatic evidence, labeled separately from corrected transcript speakers.
Do not reuse the text correction fingerprint, mutate its journal, or expand voiceprint eligibility to audio-only clusters.
Timeline renaming, merging, interval editing, and identity matching need a later correction design keyed to audio evidence.

Split children receive new analyses from their existing child transcription paths, using child-relative clocks and fresh analysis IDs.
Do not copy parent turns or assume parent cluster IDs transfer; preserve the source recording and its timeline.
Deleting audio under existing retention policy keeps the timeline as static metadata and removes playback availability.
The feature does not extend retention or recreate deleted audio.

## App experience

Add a collapsed `Speaker timeline` section beside the transcript, independent of timed-text mode and word availability.
On expansion, show a chronological, lazily rendered list of speaker label, start, and end time.
For archived-source meetings, label coverage `System audio only`; for canonical-only meetings, label it `Combined recording audio`.
Explain that these are detected audio turns and that the text is not aligned to them when text alignment is unavailable.

Selecting a turn seeks the existing player to its start and preserves whether playback is paused or playing.
Never highlight or scroll an untimed sentence as though it matched the selected turn.
Seek must use the same selected file audio track or canonical meeting playback clock used by the timeline.
When compatible playable audio is missing, keep rows readable with disabled seek and an `Audio unavailable` explanation.
An incompatible source/track must not seek a different recording silently.

Show `No speakers detected` only for an explicitly successful empty payload.
With no payload, show a neutral unavailable state on expansion, without guessing whether detection was disabled, failed, or never attempted.
Retain existing setup/retranscription entry points; do not add a new background analysis job or imply retry is possible after audio removal.
Keyboard focus and VoiceOver expose each turn's label, range, and playback availability without depending on color.
Keep the existing text speaker editor and statistics separate; timeline-only rows expose no rename/merge controls or fabricated `0 words` statistic.

## CLI, artifacts, and text consumers

Expose the same optional payload through existing JSON surfaces:

- File/URL `transcribe` and JSON `export` results that encode `Transcription`.
- `meetings show --json` and `meetings transcript --format json`, including envelope variants.
- The app-managed meeting transcript JSON artifact.

Explicit DTOs must project the saved payload rather than rebuild turns from effective words.
Preserve existing keys and envelope shape; absent payloads follow the surface's current optional-field convention.
Unknown future timeline schema versions must not prevent reading ordinary transcript text; omit the unsupported timeline from presentation and preserve the stored value on unrelated writes.
Malformed persisted timeline data likewise must not make an otherwise readable transcript disappear or be silently cleared by an unrelated metadata edit.
Implementation must provide a preservation strategy for unsupported/malformed optional JSON rather than relying on lossy decode-and-save.

`wordTimestamps`, `transcriptSegments`, `transcriptTextAlignment`, `hasWordTimestamps`, and `hasSpeakerLabeledWords` retain their existing meanings.
The legacy `speakers`, `speakerCount`, and `diarizationSegments` fields retain their existing text-attribution projections.
Do not populate those legacy fields for an untimed result merely to display the new timeline.
Plain text, SRT/VTT/DAPT, search speaker filters, citations, summaries, and AI context must not infer words or named quotations from audio turns.
Public text sharing remains governed by its existing allowlist; this milestone does not add timeline data to share bundles.

Existing diarization telemetry must not be described as evidence that words received speaker labels.
Do not add transcript text, labels, precise turns, or profile data to telemetry.
No new telemetry field is required for v1.

## Compatibility and verification

The implementation adds a nullable column without rewriting legacy timeline-like fields or correction fingerprints.
Missing columns in supported older read-only databases decode as unavailable timeline.
No schema number or CLI version is reserved by this planning document; allocate them from the implementation base.
Update [CLI JSON v1](cli-json-v1.md), [Meeting Artifacts v1](meeting-artifacts-v1.md), CLI discovery/version notes, and their focused tests when the payload actually lands.

Planned coverage includes `TranscriptionModelTests`, `TranscriptionRepositoryTests`, `TranscriptionServiceTests`, `SpeakerAttributionResolverTests`, `SpeakerAttributionReadServiceTests`, `MeetingArtifactStoreTests`, `MeetingSplitServiceTests`, `TranscribeCommandTests`, `ExportCommandTests`, and `MeetingsCommandTests`.
Add dedicated timeline validation and presentation tests; these are planned tests, not current enforcement of this contract.
The implementation plan specifies fixtures, failure cases, accessibility checks, and real-audio qualification.
Source inspection establishes architectural feasibility, not measured diarization accuracy, playback accuracy, latency, or stable-DMG availability.
