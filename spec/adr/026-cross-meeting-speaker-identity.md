# ADR-026: Opt-In Cross-Meeting Speaker Identity

> Status: **PROPOSAL**
> Date: 2026-06-15
> Related: ADR-002 (local-only), ADR-010 (speaker diarization), ADR-014
> (meeting recording), ADR-016 (STT runtime scheduler),
> `docs/research/speaker-diarization-frontier-2026-06.md`.

## Context

MacParakeet's current speaker model is intentionally anonymous and
per-transcript:

- diarization clusters a recording into stable local IDs such as `S1` / `S2`
- meeting finalization preserves source truth first (`microphone` = `Me`,
  `system` = remote speakers)
- `SpeakerInfo` stores display labels and provenance, not durable identity
- user rename changes a transcript label; it does not create a voice profile

That is the right default. Diarization can say "same cluster inside this
recording"; it cannot know a person's real name.

The pinned FluidAudio dependency now makes local cross-meeting identity
technically possible. Offline diarization can expose
`DiarizationResult.speakerDatabase` and per-chunk `chunkEmbeddings`;
`TimedSpeakerSegment` carries an embedding and quality score; `SpeakerManager`
supports `initializeKnownSpeakers(_:)`, `findSpeaker(with:)`, and matching by
embedding.

Those embeddings are voiceprints. They are biometric-like local data and carry a
different privacy and trust contract than anonymous diarization. A wrong
automatic name is worse than an anonymous speaker.

## Proposal

Add cross-meeting speaker identity only as an explicit, local-only, deletable
opt-in feature. Do not infer identity from calendar attendees, email addresses,
meeting titles, or a plain speaker rename.

The user-facing contract:

- Renaming `S1` to "Alice" stays a per-transcript display edit.
- A separate "Remember this speaker" action creates or updates a local speaker
  profile after explicit confirmation.
- Future transcripts may show "Looks like Alice" as a suggestion, not as a
  confirmed label.
- A user confirmation promotes a suggestion to a confirmed assignment for that
  transcript.
- Users can delete a speaker profile, its embeddings, and any future matching
  data derived from it.

The technical shape should be a new `SpeakerIdentity` module, not more logic
inside `TranscriptionService` or `SpeakerInfo`.

Proposed durable concepts:

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
  sourceTranscriptionId
  sourceSpeakerId
  sourceQualityScore
  createdAt

speaker_assignments
  id
  transcriptionId
  diarizedSpeakerId
  speakerProfileId?
  displayLabel
  confidence
  assignmentSource
  userConfirmedAt?
```

Model-specific details stay behind a `SpeakerEmbeddingAdapter` with a single
initial implementation backed by FluidAudio. Do not introduce a public
multi-provider embedding API until there is a second real local provider.

## Matching Flow

After final post-stop diarization:

1. Aggregate clean speech spans for each anonymous speaker.
2. Prefer high-quality segments and embeddings; discard low-quality or
   contaminated spans.
3. Compare the speaker embedding against local profiles with conservative
   thresholds.
4. Store pending suggestions with confidence/provenance.
5. Display suggestions as tentative until the user confirms them.
6. Learn only from explicit confirmation or explicit enrollment.

Meeting recordings keep source attribution as the first layer. The microphone
source remains `Me`; system-side diarization may suggest remote profiles only
for speakers inside the system source.

## Privacy Rules

- Local only. Do not upload audio, embeddings, speaker profiles, or matching
  requests.
- Default off. No voice profile is created unless the user explicitly opts in.
- Deletable. Profile deletion must remove stored embeddings and prevent future
  matching against that profile.
- Export-aware. JSON/artifact/export surfaces may include a profile identifier
  only for confirmed assignments, and must still distinguish anonymous
  `speakerId`, display label, and profile identity.
- Telemetry-free content. No speaker names, embeddings, distances, or profile
  identifiers in telemetry.
- Calendar is not identity. Calendar attendees may bound speaker count, but they
  must not name acoustic speakers.

## Implementation Gates

Do not implement this ADR until a follow-up decision accepts:

- the exact consent copy and enrollment UX
- deletion semantics for profiles, embeddings, assignments, and exports
- confidence thresholds and benchmark fixtures
- CLI/artifact/export schema additions
- how retranscription and correction replay preserve user intent

The trust benchmark must include wrong-name rate, unknown-speaker handling,
correction persistence after retranscription, speaker-count error, word-speaker
assignment accuracy, runtime, and local artifact parity.

## Consequences

### Positive

- Users can build durable local speaker memory without cloud processing.
- Confirmed profiles can make repeated meetings and interviews easier to read.
- Speaker corrections become reusable signal instead of isolated label edits.

### Negative

- Voice embeddings are sensitive local data and need first-class consent,
  deletion, backup/export, and support-language behavior.
- False positives create high-trust failures.
- The implementation requires new data models, UI states, CLI/artifact schema,
  and a benchmark loop before it is safe to ship.

## Rejected Alternatives

### Automatic Profiles From Rename

Rejected. A rename can be a local convenience ("Speaker 1 is Alice in this
transcript") without authorizing biometric reuse across future recordings.

### Calendar Attendee Names As Speaker Names

Rejected. Calendar metadata is useful as a count hint, not as acoustic identity.
Meetings can have silent attendees, shared rooms, dial-ins, guests, and people
speaking from a device not represented in the invite.

### Cloud Speaker Recognition

Rejected for the default product architecture. Cloud APIs may be useful
benchmark references, but they conflict with MacParakeet's local-first speech
contract.

### Store Identity Directly In `SpeakerInfo`

Rejected. `SpeakerInfo` is a display adapter for transcript speaker rows.
Growing it into a profile, embedding, consent, and deletion container would
make identity logic leak into every renderer.
