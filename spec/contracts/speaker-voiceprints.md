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
  `SpeakerVoiceprintService` after the transcription is persisted. The service
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
- Current policy is experimental: cosine distance `tau = 0.25`, margin `0.10`,
  minimum cluster speech of 3 seconds to match and 15 seconds to enroll, learn
  from a confirmation or retain a candidate. A shorter match can still be
  confirmed without storing an exemplar. These are duration gates, not clean-span or overlap filtering.
  Whole-cluster centroids can contain diarization errors; naming a cluster does
  not repair its attribution.
- An embedding-model mismatch prevents comparison. An aggregation-profile
  mismatch tightens the experimental threshold. Neither change deletes profiles.
- Profile-name lookup and uniqueness share the persisted `normalizedName`: trim
  surrounding whitespace and fold Unicode case and width while preserving
  accents. `displayName` remains display text; SQLite `COLLATE NOCASE` does not
  define identity. Name collisions still require the enrollment pollution guard.

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
capture tracks. Correcting an assignment to a different profile unlearns this
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
`SpeakerVoiceprintMatcherTests`, `SpeakerProfileRepositoryTests`,
`SpeakerEmbeddingCandidateRepositoryTests`, `SpeakerVoiceprintServiceTests` and
`SpeakerVoiceprintWiringTests`. `VoiceProfileFeatureGateTests` and
`SpeakerVoiceprintRetentionTests` cover availability and scheduled cleanup.
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
