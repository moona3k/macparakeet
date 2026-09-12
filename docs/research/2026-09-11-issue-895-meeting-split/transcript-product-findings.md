# Investigator working notes — transcript

> Provisional Sonnet 5 analysis of the dirty local checkout at `1159dfca`, not the final recommendation. See [report.md](report.md) for the current-main synthesis and explicit corrections. In particular, do not adopt partial publication, parent retitling, copying whole-session metadata, or guessed per-slice capture coverage from these notes.

# Transcript and Product Feasibility: Splitting a Recorded Meeting (Issue #895)

## Summary

Splitting a saved meeting into 2–4 independent meetings is feasible **without retranscribing**, because the durable transcript-derived state (`wordTimestamps`, `transcriptSegments`, derived search `segments`) is either word-timestamped or index-addressable and is entirely rebuildable from those two source arrays. The hard product problems are not ASR — they are (a) reconciling free-text transcript edits against timestamp-anchored data, (b) deciding what whole-meeting-scoped state (notes, chat, prompt results, calendar snapshot, capture report) means once one recording becomes several, and (c) doing all of this as a set of independent `Transcription` rows rather than inventing a new "child meeting" concept in the schema.

Issue #895 (open since 2026-08-10, no comments) is exactly the "accidentally combined 2–4 meetings" case, so the target UX is a manual, transcript-assisted split with retained original — consistent with the settled scope for this investigation.

## Is retranscription avoidable?

Yes, for any meeting whose STT engine produced word timing. The evidence:

- `Transcription.wordTimestamps: [WordTimestamp]?` carries per-word `startMs`/`endMs`/`speakerId` (`Sources/MacParakeetCore/Models/Transcription.swift:31,226-239`). `hasWordTimestamps` is the app's own source of truth for whether a transcript can be split/timed at all (`Transcription.swift:179-182`).
- `TranscriptSegmentRecord` stores `startMs`/`endMs`/`speakerId`/`text` plus a half-open `wordRange` into `wordTimestamps` (`Transcription.swift:264-299`), and the artifact contract documents this explicitly as durable and index-stable *within one transcript version*: "meeting retranscription may replace the array with newly minted segment IDs" (`spec/contracts/meeting-artifacts-v1.md:230-236`).
- The searchable `segments` table is a **pure derivation**, not authored data: `KnowledgeSegmenter.deriveSegments(for:)` rebuilds it from `transcriptSegments` (preferred) or re-materializes turns from `wordTimestamps` when segments are absent, and only falls back to un-timed pseudo-segmentation of plain text as a last resort (`Sources/MacParakeetCore/Utilities/KnowledgeSegmenter.swift:106-159`). `SegmentRepository.replaceSegments(for:)` deletes and reinserts by `transcriptionId` (`Sources/MacParakeetCore/Database/SegmentRepository.swift:103-112, 292-304`).

This means a split implementation can: (1) slice `wordTimestamps` at chosen ms boundaries, (2) slice/renumber `transcriptSegments` at the nearest segment boundary, (3) build `rawTranscript`/`cleanTranscript` by concatenating the sliced words, and (4) call the *existing* `SegmentRepository.replaceSegments` per new child row to get search/citations working — no engine invocation required.

## Recommended entry point and flow

The transcript detail view already has the exact primitive a "transcript-assisted, time-entry" cut needs: `TranscriptTimestampedContentView`'s `onTimestampTap` seeks and plays the audio at a word's `startMs` (`Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift:3397-3437`, specifically `onTimestampTap: { startMs in playerViewModel.seek(toMs: startMs); ... }` at lines 3423-3430). This is the same tap-to-seek affordance a "mark split point" action would reuse — the user scrubs/plays, taps a boundary, and the ms value is already validated against the audio.

Proposed MVP flow, gated on `activeTranscription.hasWordTimestamps` (mirrors the existing `meetingNoWordTimestampsBanner` gate at `TranscriptResultView.swift:1544-1550`):

1. Library/Meetings row action **"Split Meeting…"** on a completed meeting row (parallel to the existing `Remove Audio Only…` / `Delete Meetings…` bulk actions described in `spec/04-ui-patterns.md:164-166`), and a matching action in the transcript detail header.
2. A dedicated split view reusing the timed transcript renderer read-only, with "Add split point" at the current playback position and a running list of boundaries (2–4 meetings ⇒ 1–3 cuts), each snapped to the nearest word/segment boundary, never mid-word.
3. Preview per-child duration and title before committing.
4. Commit creates N new `Transcription` rows (`sourceType: .meeting`) via the existing `TranscriptionRepository.save(_:)` upsert (`Sources/MacParakeetCore/Database/TranscriptionRepository.swift:156-160`), leaves the original row intact and retitles it (e.g. "Original — split into 3"), and calls `SegmentRepository.replaceSegments` for each child.
5. No LLM/provider call, no export hook, fires as part of the commit (matches the "Settled" fence).

## Per-field disposition

| Field | Disposition after split | Rationale / evidence |
|---|---|---|
| `wordTimestamps` | Slice by ms range, rebase each child's `startMs`/`endMs` to 0 at its own start | `Transcription.swift:31` |
| `transcriptSegments` | Slice at segment granularity, drop/clip the segment straddling a boundary (see Tricky Cases), assign new `id`s | Contract explicitly allows new segment IDs on structural change (`meeting-artifacts-v1.md:235`) |
| `rawTranscript`/`cleanTranscript` | Rebuild from sliced `wordTimestamps` text, **not** by string-splitting the stored blob | Blob can have drifted from word array after edits (see below) |
| `isTranscriptEdited` | Reset to `false` per child if rebuilt from words; if parent was already edited, carry a warning (see Tricky Cases) | `Transcription.swift:48`, edit path at `TranscriptionViewModel.swift:1556-1559` |
| Derived `segments` (search index) | Fully regenerated per child via `SegmentRepository.replaceSegments` | `SegmentRepository.swift:103-112` |
| Knowledge cards (`Card`) | Not carried over; each child needs `cards generate` re-run (opt-in, provider call) | `Card` keys on `transcriptHash`/`segmenterVersion` computed from that transcription's own segments (`Sources/MacParakeetCore/Models/Card.swift:34-57`) — parent card is now stale for all children |
| `userNotes` | Copy verbatim to every child by default (cheap, reversible); do not attempt time-splitting | Free text, no time anchor (`Transcription.swift:49-53`) |
| `PromptResult` (summaries/results) | Do **not** copy; stay on the original only | Generated against the *whole* prior transcript context and carries a `userNotesSnapshot` receipt (`Sources/MacParakeetCore/Models/PromptResult.swift:11-27`) that would misrepresent a child's actual content |
| `chatMessages` (Ask history) | Do **not** copy; stays on the original only | Plain `[ChatMessage]` with no time/segment anchoring (`Sources/MacParakeetCore/Models/LLMTypes.swift:5-24`); re-attaching it to a child would misattribute prior answers |
| `speakers` / speaker IDs | Copy the full roster to every child unchanged | IDs/labels must stay stable for cross-child voice identity continuity; per-child unused entries are harmless |
| `speakerCount` | Recompute per child from the sliced `wordTimestamps`' distinct `speakerId`s, or mark informational/stale | Original count can overstate who's actually present in a given slice |
| `meetingStartContext`, `calendarEventSnapshot` | Copy as-is to every child, unedited | One-shot snapshot only valid for actual recording start (`MeetingStartContext.swift`, `MeetingCalendarSnapshot.swift`); later children get a context that's *plausible but not authoritative* — surface this, don't hide it |
| `meetingCaptureReport` | Copy as-is with a UI note that it describes the *whole* original recording, not this slice | Report is a whole-timeline coverage/quality object (`MeetingCaptureReport.swift:66-83`); per-slice recomputation is a later enhancement |
| `meetingArtifactFolderPath`, `filePath` (audio) | Owned by the storage investigation; transcript-product assumes each child gets its own artifact folder and (ideally) its own sliced audio file | Out of this brief's scope; see `storage-findings.md` |
| `titleOverride`/`derivedTitle`/`fileName` | Prompt user per child; default to `"{original title} — part N"` | Meeting `effectiveDisplayTitle` uses `fileName` directly for meetings (`Transcription.swift:207-211`); rename path already exists and publishes the DB-returned row (`spec/04-ui-patterns.md:156-160`) |
| `isFavorite` | Default `false` on children; unaffected on original | No existing precedent for propagating this |
| `engine`/`engineVariant`/`language` | Copy as-is | Fixed facts about how the whole recording was transcribed |

## Tricky cases

- **Cuts inside a segment/word.** Snap every cut to a word boundary (never inside a word) and prefer the nearest `transcriptSegment` boundary so a turn isn't split mid-sentence when avoidable; when a cut must fall inside a segment (long single-speaker turn spanning the boundary), split that segment's `text`/`wordRange` and mint two new segment IDs rather than duplicating it into both children.
- **Overlapping speakers / cross-boundary utterances.** Diarization segments (`DiarizationSegmentRecord`) and `wordTimestamps` speaker turns can straddle a chosen ms boundary even when word timing doesn't overlap in text order (e.g. one speaker's turn logically continues just after the cut). MVP should warn but not block — the user chose to split there because it's musically their own accidental "new meeting" boundary, not a technical event boundary.
- **Timestamp coordinate rebasing.** All of a child's `startMs`/`endMs` (words, segments, and any future per-child capture-report recomputation) must subtract the child's own start offset. Miss this and playback seek (`onTimestampTap`, `TranscriptResultView.swift:3423`) will look correct in isolation only if rebasing is done consistently everywhere segments are read (search hits, `transcript --around`, cards).
- **`originalText`/`text`/segments drift after user edits.** This is the most consequential edge case. The plain-text "Edit" flow only mutates `cleanTranscript` and sets `isTranscriptEdited = true` (`TranscriptionViewModel.swift:1556-1559`); it does **not** touch `wordTimestamps` or `transcriptSegments`, and the Timed view keeps rendering straight from `wordTimestamps` regardless of edits (`TranscriptResultView.swift:1574-1581`). So an edited meeting has two transcripts that no longer agree word-for-word. Splitting must rebuild each child's text from the (untouched, still-accurate) `wordTimestamps`, which means **user edits to the flat text are silently dropped from split children** unless explicitly re-applied. Safest MVP default: block/flag split on `isTranscriptEdited == true` meetings with a clear warning ("this meeting has edited text; splitting will use the original transcript, not your edits") rather than quietly discarding edits.
- **Missing timestamps / old source version.** Rows with `hasWordTimestamps == false` (Cohere-engine transcripts, or legacy pre-timestamp rows) cannot be split with time-entry precision. MVP should hide/disable split for these rows entirely rather than degrading to a text-only splitter — consistent with how the app already gates the Timed view and export behind `hasWordTimestamps`.
- **Speaker label IDs.** Keep `SpeakerInfo.id` values identical across children so any future voiceprint/identity work (already tracked as [[project_voiceprints_662]] in memory, gated on post-AEC corpus) isn't broken by re-minted IDs per split.
- **Finalization/retranscription restrictions.** Split should be unavailable while a row is `.processing` (mirrors the existing rule that "Edit and Retranscribe are unavailable while the row is processing," `spec/04-ui-patterns.md:141-142`) and should not be offered on the currently-live/in-flight meeting.
- **Undo limits.** Because the original is retained and children are net-new rows, "undo" is really "delete the children, nothing lost." MVP should support this cleanly (delete all N children in one action, restoring the pre-split state) rather than a generic undo stack.
- **Archived-original alternative.** Two framings are viable: (a) keep the original visible in Library, clearly labeled "split," or (b) archive/hide it behind a "View original recording" link on each child. The Settled scope says "original retained and accessible," which (a) satisfies most directly and needs no new visibility state.
- **CLI parity.** No `meetings split` command exists today; `retranscribe`/`meetings` resolve by UUID/prefix/title (`integrations/README.md:270-277`). A later `macparakeet-cli meetings split <id> --at <ms>,<ms>,...` following the same envelope/exit-code conventions is a natural v2, not MVP-required per the brief's scope.

## Phased recommendation

**MVP:** completed meetings with `hasWordTimestamps == true` and `isTranscriptEdited == false`; manual, transcript-assisted split (tap-to-seek + "add split point"); 2–4 children; original retained and relabeled; each child gets sliced `wordTimestamps`/`transcriptSegments`, rebuilt `rawTranscript`, regenerated derived `segments`; notes copied to all children; chat/prompt-results/cards not copied; calendar/start-context/capture-report copied as-is with an explanatory note; GUI-only, no CLI command yet.

**Later enhancements:** per-child capture-report recomputation from source alignment (storage-team dependency), optional CLI `meetings split`, an explicit "carry edited text forward" reconciliation path instead of blocking edited meetings outright, per-child speaker-count recompute, and export/hook parity once the artifact-folder-per-child shape is settled with the storage investigation.

## Verification plan (not run — investigation only)

- Unit tests for a new `MeetingSplitPlanner`-style pure function: slicing `wordTimestamps`/`transcriptSegments` at ms boundaries, boundary snapping, rebasing, and the straddling-segment split.
- `SegmentRepositoryTests`-style coverage proving `deriveSegments`/`replaceSegments` produce correct, rebased `seq`/`startMs` for each child.
- New `TranscriptionRepositoryTests` cases for creating N sibling rows via `save(_:)` and preserving the parent row unmodified except its label.
- `MeetingArtifactStoreTests` extension (joint with the storage investigation) once folder-per-child is designed.
- Manual QA: split a real multi-topic meeting recording, verify Timed view seek accuracy and search/citation hits per child, and verify the edited-transcript warning path.

## What I did not test or verify

I did not fetch the live GitHub issue body (tool access was denied in this environment), did not run `swift build`/`swift test`, did not inspect `MeetingArtifactStore.swift`/`MeetingRecordingService.swift` internals in depth (deferred to the parallel storage investigation), did not trace the exact code path that deletes `PromptResult`/chat rows on full meeting deletion (only confirmed `segments`/`cards` have `ON DELETE CASCADE` at `Sources/MacParakeetCore/Database/DatabaseManager.swift:1170-1244`), and did not confirm a guard condition preventing split UI on an in-progress/live recording (inferred from the analogous documented Edit/Retranscribe restriction, not from reading a specific guard clause).
