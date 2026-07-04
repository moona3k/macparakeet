# Meeting corpus capture — agent-ready raw materials

> Status: **COMPLETED 2026-07-04** — all five slices merged: #684 segments
> (`6d255fd84`), #686 start context (`679bea9ae`), #687 calendar context
> (`8f7fd7dfb`), #688 diarization default (`cfbcccb30`), #689 retention copy
> (`358f2c460`).
> Date: 2026-07-03
> Governing decision: [ADR-027](../../spec/adr/027-product-north-star.md) —
> the meeting corpus is the product's long-term asset; interfaces and indexes
> are re-derivable later, but context not captured at meeting time is lost
> forever.
> Evidence: capture-data audit 2026-07-03; key source surfaces are named below.
> Drift-check before executing any slice.

## Goal

Every meeting record carries the capture-time context and stable structure
that future cross-meeting search, QA, and agent access will need — with no
new UI and no user-visible behavior change. This plan is capture-side only:
it makes records richer from the day it ships. It deliberately builds
nothing on top (no index, no chat surface, no embeddings — all re-derivable
later per [ADR-027](../../spec/adr/027-product-north-star.md)).

What already exists and must not regress: word timestamps + confidence +
mic/system attribution persist (`Transcription.wordTimestamps`, finalizer
sets `speakerId` = source), meetings have stable UUIDs with clean joins to
summaries/Ask/artifact folder, and `macparakeet-cli meetings` already
exposes list/show/transcript/export with words + speakers in JSON.

## Slice 1 — Calendar context snapshot (the big one)

Today only the event **title** survives auto-start (as the record's
`fileName`). `Sources/MacParakeetCore/Calendar/CalendarEvent.swift` carries
event id, external id, scheduled start/end, attendees, and meeting URL at
poll time, then `Sources/MacParakeet/App/MeetingAutoStartCoordinator.swift`
passes only the title into the recording flow. Organizer is not converted
today, so adding it belongs to this slice. ADR-017 §6 decided not to persist
events; that rationale predates ADR-027, so **amending ADR-017 is part of
this slice** (repo rule: update the ADR deliberately, don't code around it).

- On auto-start, snapshot the triggering event onto the meeting record:
  `eventIdentifier`, `externalId`, title, scheduled start/end, attendees
  (names + emails as EventKit exposes them), organizer (the current
  `CalendarEvent` conversion has no organizer field — add it), detected
  meeting URL/service.
- On manual start, best-effort match: if the coordinator's current poll
  data has an event overlapping now, snapshot it flagged as
  `probable` rather than `confirmed`. Cheap because the poll data is
  already in hand; skip if it isn't.
- Storage: one snapshot per meeting. A JSON column on `transcriptions` or a
  small sidecar table keyed by `transcriptionId` — implementer's choice per
  GRDB conventions (raw-SQL migration; see the known
  historical-migration/Codable pitfall). Also write the snapshot into the
  artifact-folder metadata (`MeetingArtifactStore` / metadata sidecar) so
  the folder stays self-describing.
- Surfacing: include in `meetings show --format json` and the artifact
  contract. `spec/contracts/` + CLI CHANGELOG + `spec/01-data-model.md`
  updates in the same PR.
- Privacy: attendee names/emails are user data — local only, exportable
  locally, **never in telemetry** (not even counts without an explicit
  allowlist decision).

## Slice 2 — Start context for every recording (small)

Manually started meetings get a date-as-title and nothing else
(`Sources/MacParakeet/App/MeetingRecordingFlowCoordinator.swift` start path);
ADR-024's app-detection collectors are compiled but disabled, and activity
snapshots are transient.
Without turning ADR-024 detection on:

- Persist at recording start: trigger kind (manual / hotkey / calendar
  auto-start / CLI), frontmost app bundle id + name at start, and source
  mode. DB + artifact metadata, same surfacing rules as Slice 1.
- Do NOT resurrect the ADR-024 coordinator; this is a one-shot snapshot,
  not ongoing detection.

## Slice 3 — Durable transcript segments

Segments are currently derived on the fly for UI from word timestamps
(`Sources/MacParakeetCore/Utilities/TranscriptSegmenter.swift`), with
synthesized identity (start + speaker) — an agent cannot stably cite
"meeting X, segment 47".

- At finalization, materialize segments with: UUID, start/end, speaker or
  source label, text, and word-index range into the persisted word array.
- Persist alongside the transcript (DB JSON or a
  `transcript-segments.json` artifact plus DB pointer — implementer's
  choice; the artifact folder must remain self-describing either way).
- IDs are stable per transcript version: re-transcribing a meeting may
  mint new segment IDs; renders/UI reuse the persisted segments rather
  than re-deriving with different boundaries.
- Expose in `meetings show/transcript --format json`; contract + CHANGELOG
  in the same PR. UI may keep its own presentation grouping — this slice
  does not require UI changes.

## Product decisions (decided 2026-07-03)

1. **Diarization default: ON where supported.** Flip the default
   (`Sources/MacParakeetCore/AppRuntimePreferences.swift`) so meeting
   diarization runs post-meeting whenever a system track exists; the
   setting remains available to turn it off. Rationale: speaker structure
   is only recoverable while raw audio exists, so capture-time diarization
   is the last chance to get speaker labels into the corpus given
   decision 2. Ships as **Slice 4** (small): default flip + focused test
   that the preference default changed + release-notes line (user-visible
   behavior change).
2. **Raw-audio retention: keep deletion, add honest copy.** "Remove
   Audio" and the retention sweeper keep deleting all raw tracks
   (`Sources/MacParakeetCore/Utilities/TranscriptionAssetCleanup.swift`) —
   removal means removal; that is the privacy posture. Ships as
   **Slice 5** (small): warning copy at the Remove Audio action and the
   retention setting stating that deletion permanently prevents
   re-transcription and speaker backfill. No behavior change.

## Deliberately deferred

- Detailed capture-provenance sidecar (chunk drops, watchdog signatures,
  AEC frame counts, STT asset checksums): diagnostics value, not corpus
  value. Revisit if debugging demand appears.
- Speaker embeddings / cross-meeting speaker identity: requires
  `DiarizationService` API surface changes and a privacy design; depends
  on the diarization-default decision. Its raw material (audio) is covered
  by decision 2 above.
- Everything Class C: embeddings, RAG chunks, search index, chat UI.

## Acceptance (per slice)

- Focused tests: migration + persistence round-trip, artifact-contract
  test updates, CLI JSON contract test.
- `spec/01-data-model.md`, matching `spec/contracts/` doc, and CLI
  CHANGELOG updated in the same PR as the behavior.
- No telemetry of any captured content; a PR-body statement confirming
  the privacy rule was checked.
- Slices are independent and can ship in any order; Slice 1 first if
  sequencing is free (highest irreversibility value).
