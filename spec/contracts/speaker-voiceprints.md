# Speaker Voiceprints

> Status: EXPERIMENTAL — meeting voice profiles with consent, enrollment,
> suggestions, manual assignment and administration, disabled by default.

## Purpose

Keep optional speaker identity memory local, explicitly enabled and separate from
transcript labels. Protect its availability, persistence and deletion boundaries
while real-meeting matching quality is evaluated. The
[implementation plan](../../plans/active/2026-07-03-speaker-voiceprints.md#integration-and-release-gates-2026-09-10)
defines separate integration and official-release gates; passing fixture tests or
merging into `main` does not establish meeting accuracy or authorize release.

## Producers And Consumers

- `DiarizationService` normalizes and remaps offline speaker centroids into
  `SpeakerEmbedding` values, preserving the detected speaker IDs and durations.
- `TranscriptionService` passes eligible meeting observations to
  `SpeakerVoiceprintService` after the transcription is persisted. With the
  effective gate on, it also diarizes the microphone track and
  `MeetingMicrophoneSpeakerResolver` classifies each microphone voice (see
  [Owner Voice And The Microphone Track](#owner-voice-and-the-microphone-track)). The service
  uses the pure `SpeakerVoiceprintMatcher` and GRDB repositories for profiles,
  exemplars, links, enrollment candidates and the match journal.
- `AppEnvironment` supplies feature/preference gating and starts
  `SpeakerVoiceprintRetention` maintenance.
  Enrollment, suggestion and manual-assignment UI must call the gated service;
  ordinary speaker renames continue through the speaker-correction layer. Naming
  a speaker from the list of enrolled voices is one of those calls: it records a
  profile link after the requested transcript label correction succeeds.
- Export, CLI JSON, diagnostics, feedback/support bundles and external AI context
  are not consumers of the voiceprint tables. They may use transcript labels
  explicitly applied through the existing correction path.

The default Nemotron 3 service emits anonymous activity and no reusable speaker
embeddings. When experimental voice profiles are available, the shared factory
wraps a diarizer in `TitaNetVoiceprintDiarizationService`. Without an explicit
speaker-count constraint that diarizer is `HybridDiarizationService`; with one,
it is Community-1 (`DiarizationService`).

The hybrid's own embeddings are internal. Nemotron supplies the segments (turn
timing and overlap). A Nemotron speaker with a clear Community-1 counterpart
(the cluster covering at least 60% of its speech, one voice per speaker)
carries that Community-1/WeSpeaker embedding; an unmatched or split speaker
carries none and is never matched. Stretches only Community-1 heard keep their
mapped speaker. When Nemotron merges two distinct voices (a second voice of
≥ 15 s and ≥ 20% of a speaker), or Nemotron fails, the Community-1 result is
used unchanged. When Community-1 fails, the Nemotron result is returned without
embeddings. Nemotron's own constraint fallback (which already carries
embeddings) is returned as is.

Saved and matched voiceprints are TitaNet-Large, not Community-1. The wrapper
replaces each speaker's embedding with a TitaNet vector (model id
`nvidia-titanet-large-192`, aggregation `titanet-concat10s-v1`). Only speakers
the inner diarizer gave an embedding are eligible, so the hybrid's "no clear
voice" decision survives. Each vector is built from at least 3 s of that
speaker's speech with nobody else talking, and that speech, not total
activity, is the duration the match and enrollment gates see. If the TitaNet
model is unavailable, the result carries no embeddings, so nothing is scored
or retained; speaker detection is unaffected. Profiles enrolled under the
earlier Community-1 embeddings (`fluidaudio-wespeaker-256`) are not comparable:
they surface as using a retired model and need a new sample. No profile data
is deleted.

## Availability And Consent

`AppFeatures.voiceProfilesEnabled` is `false`. The availability helper
`AppFeatures.isVoiceProfilesAvailable(arguments:)` accepts
`--enable-voice-profiles` only in DEBUG builds. A release build ignores the
argument while the compiled gate remains disabled.

Availability is necessary but does not grant consent. The effective
`rememberSpeakersEnabled` preference also requires the separately saved
`rememberSpeakers` opt-in, an acknowledged consent date and meeting speaker
detection. The preference defaults off. Neither an existing preference nor a
previously retained candidate bypasses a disabled availability gate.

Matching, candidate access and enrollment/confirmation/dismissal mutations honor
the effective gate at the service boundary. Turning the feature off prevents
further feature use; it does not itself erase enrolled profiles. Retention cleanup
continues while disabled, and explicit deletion remains available to the owner.
The opt-in UI discloses candidate retention before the first write. Transcript
recognition reads and identity actions use the effective consent gate; administration
reads and deletion remain available after recognition is disabled.

## Identity And Matching Semantics

- Embeddings contain 256 finite Float32 components, are normalized once on entry
  and reject invalid or near-zero vectors. Dropping an invalid embedding must not
  remove the diarizer's speaker, segments, ID mapping or duration information.
- Suggestions require mutual best matches, a distance threshold and margins on
  both sides. Unknown or ambiguous voices may remain unnamed. Suggestions never
  rename a transcript automatically; confirmation uses the existing correction
  path, and profile links carry identity provenance separately.
- A manual assignment is a human decision, not a measurement: the user picks an
  enrolled voice for a speaker the matcher did not propose one for. It takes the
  same correction path as a confirmation, and it cannot give one profile to two
  speakers of the same transcript — the reservation applied to suggestions holds
  for it too. Capture-channel rows (`Me` / `Others`) are not assignment targets.
  Manual assignment learns on different terms: the sample is stored as a manual
  enrollment and needs no anchors, because choosing a name from the enrolled
  voices is the same claim as typing that name into the enrollment field. How far
  the chosen voice sits from the profile's existing samples is deliberately not a
  gate — that distance is why no suggestion was made.
- Current policy is experimental (`SpeakerMatchPolicy.titanetV1`): cosine
  distance `tau = 0.40`, pollution guard `0.55`, margin `0.10`,
  minimum cluster speech of 3 seconds to match and 15 seconds to enroll, learn
  from a confirmation or retain a candidate. A shorter match can still be
  confirmed without storing an exemplar. The gates read the non-overlapped speech behind the voiceprint.
  A cluster can still contain diarization errors; naming it does not repair its
  attribution.
- An embedding-model mismatch prevents comparison. An aggregation-profile
  mismatch tightens the experimental threshold. Neither change deletes profiles.
- Profile-name lookup and uniqueness share the persisted `normalizedName`: trim
  surrounding whitespace and fold Unicode case and width while preserving
  accents. `displayName` remains display text; SQLite `COLLATE NOCASE` does not
  define identity. Name collisions still require the enrollment pollution guard.

## Owner Voice And The Microphone Track

The microphone hears more than its owner: far-end audio played on speakers
returns as echo that cancellation can miss, and colleagues in a room share the
microphone. With the effective gate on, meeting finalization diarizes the
microphone track as well and `MeetingMicrophoneSpeakerResolver` gives every
microphone cluster one role:

- **Echo** — within `tau` of a diarized system cluster with at least the match
  gate of speech. Its words are attributed to that system cluster. Echo is
  decided first, so a far-end voice can never be chosen as the owner.
- **Owner** — the cluster recognised as the owner's saved voice (within the
  effective `tau`), otherwise the remaining cluster with the most speech. Its
  words keep the `microphone` id and the "Your name" label.
- **Room voice** — any other cluster with at least the enrollment gate of
  speech that is not within `tau` of the owner cluster. It becomes a diarized
  `microphone:Sn` speaker labelled "Room N" and takes the ordinary identity
  flows (suggestion, rename-and-remember, manual assignment) like a system
  cluster, with capture domain `microphone`.

Shorter clusters and an over-split owner fold into `microphone`, and an
unclaimed microphone word stays `microphone`, so a single-voice headset meeting
keeps the transcript it had before. Microphone diarization is best-effort: a
failure other than cancellation leaves the track as one `microphone` speaker.
With the gate off, voice-profile diarization and identity handling leave the
microphone track unchanged (its label still follows "Your name", below).

The owner's cluster is retained as a candidate under speaker id `microphone`
and is never offered a suggestion. `enrollOwnerVoice` is the single identity
write a capture track accepts: it enrolls that candidate under the user's name
(the "Your name" preference, or the label the user gave the `microphone` row —
never the "Me" placeholder) with the same duration, cap, model and pollution
rules as any enrollment, and records the profile as the owner through the
`ownerVoiceProfileID` preference. That pointer is not biometric data; a pointer
to a forgotten profile reads as unset, and forgetting that voice or all voices
clears it. The owner's profile is excluded from suggestions for every other
speaker. When a later owner cluster passes the match-duration gate and has a
comparable voiceprint, the evaluation updates the profile's
`lastEvaluatedDistance`, and `lastMatchedAt` only within the effective `tau`,
so the voices screen shows whether the owner is being recognised. No journal row or link is written for the owner.

"Your name" (`meetingOwnerName`) is a display label for the `microphone` track
of new meetings, independent of voice profiles and consent. It is local free
text: never telemetry, never a profile. Saved transcripts keep their labels.

## Local Storage And Lifecycle

Migrations `v0.39-speaker-voiceprints`, `v0.40-speaker-match-journal` and
`v0.41-speaker-embedding-candidates` create these tables in the user database:

| Table | Ownership and lifecycle |
|-------|-------------------------|
| `speaker_profiles` | Explicitly enrolled identities; retained until deletion. |
| `speaker_profile_exemplars` | Profile-owned 1024-byte vectors with model/aggregation identity, duration, capture domain and enrollment origin. At most one exemplar per profile per source recording; at most 10 under current policy. |
| `speaker_profile_links` | Suggested, confirmed or dismissed identities scoped to transcription ID, speaker ID and transcript fingerprint. Re-evaluation must not overwrite a terminal decision; only an explicit user action may replace one. A link recording a manual assignment carries a documented sentinel distance outside the cosine range, so calibration can exclude a choice that was never scored. |
| `speaker_embedding_candidates` | Consent-gated temporary voices for later enrollment, scoped to the same transcript/speaker/fingerprint. Never compared against each other or read as references by the matcher. |
| `speaker_match_journal` | Local decision distances, outcomes and references; no vectors or independent identity labels. Supports calibration, not automatic ground truth. |

Candidate retention is seven days, stored as `expiresAt` per row. Changing the
default retention does not extend existing stored rows; a new evaluation may
replace a same-key candidate with a newly calculated expiry. Journal retention
is 90 days. Repositories prune on reads and writes and never return expired rows.
`SpeakerVoiceprintRetention` also prunes at startup and hourly while the app runs,
including with the feature disabled, and attempts both stores independently when
one cleanup fails. No background process runs after app shutdown: cleanup resumes
at the next launch. These are logical expiry and database cleanup guarantees,
not a claim of immediate physical removal from every disk page or user backup.

UI enrollment resolves a live, unexpired stored candidate at acceptance; an old
banner cannot recreate a deleted or expired candidate from its cached observation.
Offers are bound to the effective speaker name and correction state as well as
transcript ID and fingerprint. Identity actions are serialized in the view model,
validated before the label write, and checked again at the service mutation.
Profile reservation applies to both manual assignments and confirmations.
Undo and redo of transcript labels are refused while an identity write is in
flight. After a completed identity write, undo reverts labels only; confirmed
profile links remain, and a held link still blocks that voice for other speakers
in the same transcript fingerprint. Re-applying the name records the identity
again without adding a second sample from the same recording. Identity writes
apply only to diarized clusters, never to the meeting `microphone` or `system`
capture tracks, with one exception: the owner enrollment described below. Correcting an assignment to a different profile unlearns this
recording's sample from the previous profile so a misclick cannot keep teaching
the wrong name.

New-profile creation and its first exemplar insertion are atomic. Subsequent
capped exemplar insertion is transactional; candidate consumption is a separate
operation that runs only after insertion succeeds. A failed candidate deletion
can leave a redundant, expiring copy; it must never discard a candidate before
its exemplar is persisted. A rejected insertion, including a profile filled with
manual enrollments, preserves the candidate for its remaining retention window. A
confirmed label does not imply a sample was learned: confirmation-driven learning
requires two manual enrollment anchors and must respect the duration, cap and
model rules. Assignment-driven learning requires no anchors and stores a manual
enrollment, under those same duration, cap, one-sample-per-recording and model
rules. An assignment to an older-model profile records the explicit identity without
learning an incompatible sample. Evaluation and recognition metadata updates do
not overwrite profile names changed by administration. Re-evaluation replaces pending suggestions for that transcript
fingerprint while preserving confirmed and dismissed choices.
Journal outcomes describe scoring, not proof that an offer was displayed: a
concurrent terminal choice may suppress publication after the score was computed.

Voiceprint repositories preserve the actual SQLite representation of each parent
transcription identifier when writing or querying references. Both historical
TEXT UUIDs and current BLOB UUIDs are supported without rewriting existing rows.

Deleting a profile atomically removes its exemplars, links and referenced journal
rows; transcript labels and speaker corrections survive. Deleting a transcription
removes its links, candidates and journal rows while retaining explicitly enrolled
exemplars with their source-transcription reference cleared. Deleting all voice
profiles clears all five tables, including unowned candidates and journal entries,
in one transaction. None of these operations deletes source audio or transcripts.

## Export Exclusion

Voiceprint vectors, profile identifiers, candidate data and journal metadata must
not enter JSON/TXT/MD/SRT/VTT/PDF/DOCX exports, CLI `projectedJSON()`, diagnostics,
feedback/support bundles, telemetry or external AI requests. `Transcription` and
`SpeakerInfo` gain no profile fields; applied names remain ordinary transcript
labels. Any future database-export surface must explicitly exclude these tables.

## Non-stable Details

Generated IDs, timestamps, display ordering, UI copy and experimental matching
thresholds are not frozen by this contract. Threshold changes require a documented
evaluation; they cannot silently be treated as release-qualified values. Retention,
consent, deletion and export semantics require deliberate contract changes.

## Versioning And Compatibility

This is an internal experimental boundary, not a new public CLI schema. Additive
schema changes follow GRDB migrations; do not repurpose an applied migration or
delete enrolled data on a model/configuration change. Public UI or agent access
requires its own reviewed consent, deletion and compatibility design.

## Tests And Required Evidence

Focused fixture coverage lives in `SpeakerEmbeddingTests`,
`SpeakerOwnerVoiceTests`, `MeetingMicrophoneSpeakerTests`,
`SpeakerVoiceprintMatcherTests`, `SpeakerProfileRepositoryTests`,
`SpeakerEmbeddingCandidateRepositoryTests`, `SpeakerVoiceprintServiceTests` and
`SpeakerVoiceprintWiringTests`. `VoiceProfileFeatureGateTests` and
`SpeakerVoiceprintRetentionTests` cover availability and scheduled cleanup.
`TitaNetSpeakerEmbedderTests` enforce the voiceprint backend: hybrid
eligibility surviving the swap, the exclusive-speech minimum and reported
duration, file-backed window reads, the verified model install, no
cross-model comparison, and the missing-model fallback. `HybridDiarizationServiceTests`
cover fusion and both failure fallbacks.
Integration must cover disabled gates despite saved
preferences or stale observations, consent prerequisites, fingerprint isolation,
candidate preservation after rejected insertion, expiry without new meetings,
deletion cascades and transcript-label preservation. Flag verification must also
check that a release build ignores the DEBUG override.

Manual assignment must be covered on both sides of the boundary:
`SpeakerVoiceprintServiceTests` for the sentinel distance, the sample kept as a
manual enrollment however far the chosen voice sits from the profile, the
duration gate, a profile already held by another speaker of the same transcript,
replacing an earlier dismissal and the disabled gate; `TranscriptionVoiceEnrollmentTests` for
the write order, a refused rename recording nothing, and abandonment when the
fingerprint changed. `VoiceProfilesViewModelTests` must pin that the management
surface is offered after a failed read, since hiding it would leave stored
biometric data unreachable.

Outward-boundary verification must exercise populated voiceprint tables against
the app and CLI export projections. Inspect feedback and diagnostic builders for
database access and attachment selection, and run their existing tests. If these
builders gain library-storage inputs, add populated-table exclusion fixtures at
that boundary. Relevant suites include `SpeakerVoiceprintExportTests`,
`ExportServiceTests`, `ExportCommandTests` and `FeedbackServiceTests`. A release
review must record which surfaces were tested and which were only inspected.
Tests listed here are required coverage, not a claim that every release surface
or real-audio scenario has already passed.

Before official release, record held-out meeting precision and coverage before
correction, unknown-speaker false matches, sample counts and uncertainty under
criteria fixed before final evaluation. Include changed capture conditions,
overlap, brief speech and mixed-speaker clusters, plus actual app consent,
deletion and retention flows. User confirmations need independent checking.

## When This Changes

Update this contract, the focused tests and the governing plan when availability,
consent, identity, persistence, retention or outward-data behavior changes. Update
the [spec index](../README.md#release-channels-and-feature-flags) when the compiled
flag changes. Record release evidence separately from implementation status.
