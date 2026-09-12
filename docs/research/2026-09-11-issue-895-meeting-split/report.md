# Splitting a saved meeting recording

Investigation of [MacParakeet issue #895](https://github.com/moona3k/macparakeet/issues/895). Prepared September 11, 2026. Research and an interactive HTML concept; no production implementation.

For implementation, use the [agent handoff](../../plans/2026-09-11-issue-895-meeting-split-plan.md) with the current code and governing contracts. The HTML is reference material only. The user explicitly left the optimal UI/UX open to exploration and decision during implementation; no layout or container in this report is mandatory.

## Recommendation

**Yes, this is feasible. Build a manual, non-destructive “Split recording…” action that creates independent meetings and keeps the original.** For a completed recording with a trustworthy timed transcript, split the existing audio and transcript without rerunning speech recognition. Let the user choose one or more boundaries, preview and name the parts, then create them together.

This directly repairs the reported problem: leaving recording on through several successive meetings. It also makes each conversation independently searchable, summarizable and exportable, fitting [ADR-027](../../../spec/adr/027-product-north-star.md). Automatic meeting detection can help prevent the mistake, but cannot repair recordings already in the library.

The media operation is tractable. The substantial work is preserving timestamps, edits and speaker corrections; coordinating files with database publication; and keeping retention, recovery and citations honest. This should be a focused library feature, with its own safety contract, rather than a general audio editor.

Open [the interactive mockup](split-recording-prototype.html). It uses fictional meetings and changes no real files. The final recommendations in this document take precedence over the investigator working notes.

## Architecture and design assessment

**High confidence in the architectural fit; moderate implementation complexity, concentrated in data integrity.** This is a sensible addition to the saved-meeting workflow and can be implemented as clean, maintainable code. The assessment is based on the source investigation and synthetic media experiment below; production recovery, retention and multi-track behavior still require implementation-level verification.

### Ordinary meetings as the output

Each result should be an ordinary saved meeting with its own identity, audio, transcript and search entries. A small provenance record connects it to the original recording and source time range. Playback, summaries and exports can operate on the results through their existing meeting interfaces. Split-specific behavior stays concentrated in creation and provenance, with explicit integration into retention and recovery where required.

Independent output files make ownership understandable: deleting the original must leave the parts usable, and deleting one part must leave its siblings usable. The original remains intact with its existing title, notes, conversations, results and citations.

### One small interface, three internal responsibilities

Place the operation in one Core module, provisionally `MeetingSplitService`, shared by the GUI and CLI. Its interface should let callers preview a split and create the approved parts. The preview captures source identity/revision, proposed boundaries, output titles and eligibility; creation revalidates those facts before publishing anything.

| Internal responsibility | What it owns |
|---|---|
| Plan | Deterministic boundary validation and calculation of each part's transcript, timestamps and effective speaker assignments from a supplied source snapshot |
| Prepare audio | Background export of independent files, preserving source alignment and checking the resulting media |
| Save the group | Staging, operation identity, source revalidation, database publication, recovery and completion reporting |

Keep these helpers internal unless a real caller or alternate implementation needs their interface. Use the existing repositories and media facilities at appropriate seams. The caller should not have to know the order of file installation, transaction commits, search-index updates or cleanup to use the module correctly.

The operation lifecycle is the substantial engineering task. If the app quits while preparing the third of four meetings, the original must remain intact and a retry must not create duplicates. A small durable operation journal earns its place by keeping that behavior local to the split module. It must also account for the gap between filesystem changes and database commits, as detailed in [Atomic creation and recovery](#atomic-creation-and-recovery).

### Native design and first-release scope

A focused native SwiftUI sheet with the transcript and resulting parts visible together is a promising candidate, not a settled design. Compare it with an in-detail mode or another appropriate native approach before deciding. Users need to add boundaries, review titles and durations, and create the parts. ViewModels own preview and progress state; Core owns audio work and persistence. The HTML is an interaction reference, not a pixel-perfect specification, mandatory control set or instruction to add a permanent editor workspace.

The first release should handle manual cuts into contiguous parts with trustworthy timing, including explicitly labeled text-only results where valid timing survives audio removal. Preserve all recorded time. Keep the original accessible and leave whole-recording notes, summaries and conversations attached to it. Edited transcripts and uncertain timing need explicit unavailable states or separately reviewed fallback flows. Automatic boundary detection can follow later.

The clean-code criterion is that a timing, ownership or recovery fix can be made once inside the split module and benefit every caller. Shipping confidence should come from deterministic partition checks, database/filesystem failure cases and real multi-track verification, in addition to the working UI concept.

## Evidence and scope

- The issue was open with no comments when checked. It was submitted August 10, 2026 from version 0.7.3 on an M1 Max. It requests separating two, three or four accidentally combined meetings; it does not request automatic boundary detection.
- Initial Claude Code investigations examined the existing dirty checkout at `1159dfca8ae53a15ffcc1562b1efb9220f95cd88`. I fetched and separately inspected current `origin/main` at **`aaf3dc261536e5fc5158c4b1ca714bd3f4cece19`**, 334 commits ahead. Current-main citations below are pinned to that revision. Neither checkout content nor either SHA is a claim about the installed stable release.
- The heavier storage investigation, transcript investigation and HTML creation used **`claude -p --model claude-sonnet-5`**. The orchestrator checked their conclusions, resolved disagreements and ran the audio experiment and artifact checks. The raw notes are retained as [storage findings](storage-findings.md) and [transcript/product findings](transcript-product-findings.md), explicitly marked provisional.
- No private recordings, meeting databases or transcripts were opened. The investigation ran no app build or app test suite; the standalone synthetic audio experiment is the only native execution described here. The research-time verification receipt predates the subsequent request to commit and merge these documents. Documentation publication does not implement or release the feature, and must not close the issue.

## What already exists

| Existing capability | Consequence for splitting | Current-main evidence |
|---|---|---|
| One transcription identity, durable artifact folder and canonical playback path | A child can look like an ordinary saved meeting to playback and export | [Transcription fields](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Models/Transcription.swift#L18), [folder resolution](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Services/MeetingRecording/MeetingArtifactStore.swift#L458) |
| Word timestamps and durable passage records with word-index ranges | Many recordings can reuse recognized speech; children need rebased times and fresh passage IDs | [Word and passage models](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Models/Transcription.swift#L231) |
| Mic/system alignment, including start offsets and playable frame counts | Every track must be sliced in the same meeting coordinate system | [Alignment model](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingMetadata.swift#L3) |
| Plain-text edits change `cleanTranscript` without realigning words | Timed splitting cannot silently carry arbitrary edits forward | [Edit implementation](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetViewModels/TranscriptionViewModel.swift#L1859) |
| Effective speaker attribution is a separate correction projection | Copying the base speaker roster alone loses corrections | [Resolver](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Services/Diarization/SpeakerAttributionResolver.swift#L99) |
| Search passages and knowledge cards derive from canonical content | Rebuild child search records; whole-parent cards are not child summaries | [Database architecture](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Database/README.md) |
| Audio removal and full deletion operate on a meeting folder | Sharing parent paths would make independent deletion unsafe | [Asset cleanup](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Utilities/TranscriptionAssetCleanup.swift#L73) |

I found no saved-meeting split operation in the inspected Swift sources or CLI subcommands. Existing speaker-turn splitting is a different operation. A new application service is required; this is not just exposing a hidden export option.

## Recommended interaction

This sequence illustrates the user outcomes, not a fixed UI contract. The implementing agent may choose a different native presentation or interaction after exploring alternatives, while preserving explicit cut approval, source protection and truthful result states.

1. Open a saved meeting in Meetings or Library. Choose **Split recording…** in the detail actions or row context menu. Keep the action discoverable when unavailable and explain why.
2. Show a read-only transcript alongside a compact timeline and the existing audio player. Let the user add a cut before a passage, at a reviewed playback position, or by typing a time. Show the text immediately before and after each cut.
3. Prefer gaps between passages. If a chosen time crosses speech, propose a nearby safe boundary and show the adjustment for confirmation. Never silently move a cut or discard a crossing word.
4. Preview each part’s title, original time range and duration. Titles default to “Original title — Part 1”, etc., and are editable. One cut makes two meetings; three cuts make four. The implementation should represent an ordered array of boundaries, not four hardcoded fields.
5. Explain once: **“The original stays in your library. Each part gets its own audio and transcript. Notes, summaries and Ask history stay with the original.”** Show the estimated additional storage before confirmation.
6. **Create N meetings** starts local preparation with progress and cancellation before publication. Publish the complete group together. The success screen opens any child and provides **Open original recording**.

Keep all recorded time in the first version, including pauses between meetings. For example, cuts at 36:20 and 1:12:10 divide a 1:48:00 recording into 36:20, 35:50 and 35:50. “Exclude this break” introduces intentional removal and discontinuous timelines; add it separately if demanded. Do not silently trim silence.

The original keeps its ID, title, content and existing citations. A computed “Original of 3 parts” relationship can appear without rewriting its title. Keep it visible in the library initially; hiding or archiving it would require broader visibility and search semantics. Duplicate search results are an acknowledged consequence, and can be identified through provenance rather than hidden unexpectedly.

Do not offer a generic destructive Undo after children can be edited or summarized. Cancellation before publication is safe; deleting new meetings afterward uses the existing explicit deletion flow. The mockup’s Reset button only resets fictional in-memory data.

## Eligibility and fallbacks

| Source state | Recommended behavior |
|---|---|
| Completed, audio retained, valid timed transcript matching displayed content | Full audio-and-transcript split, no STT run |
| Audio removed or missing, but trustworthy timed transcript remains | Explicit **text-only** split; no playback/export promise. User must know the resulting meetings have no audio |
| Free-text edits no longer match timestamps | Explain the mismatch and block the fast path. Keep edits intact. A later explicit “create parts from original timed transcript” or per-part retranscription flow may be offered without overwriting the original |
| No word timing, but valid durable passage timing | Potential passage-boundary-only fast path after validating passage/text consistency; do not assume the presence of arrays proves validity |
| No usable timing, audio retained | Audio splitting remains technically possible, but producing correct child text requires explicit new transcription or manual text partitioning. Defer this path from the first release |
| Neither audio nor trustworthy timing | Explain that an accurate time-based split is unavailable. A plain-text organizer would be a separate feature |
| Recording, processing, recovery/finalization ownership, or conflicting mutation | Refuse admission with a specific explanation; a completed status alone is insufficient |
| Source audio already past its retention cutoff | Refuse audio-producing split. Offer text-only splitting, or let the user explicitly change the existing retention setting first; do not create audio eligible for immediate removal |
| Partial capture or ambiguous legacy track alignment | Show inherited uncertainty. Permit only outputs whose timeline can be established; never manufacture missing audio or report healthy per-part capture without evidence |

The mockup demonstrates the common fast path, text-only splitting and the edited-transcript block. It does not simulate real audio, alignment recovery or speech recognition.

## How the data should be split

### Audio and time coordinates

Give every child a fresh UUID and independent artifact directory. Export its own `meeting-playback.m4a`; preserve the available raw mic/system and cleaned-mic slices when their alignment is known. Read legacy filenames through the existing compatibility resolver and write current filenames. Do not alias the original folder, symlink parent audio or give children full copies of the entire recording with playback offsets.

For a child range `[s,e)` on the recording timeline and a source track starting at offset `o` with duration `d`, intersect the ranges:

```text
a = max(s, o)
b = min(e, o + d)
source-local range = [a - o, b - o)
child start offset = a - s
```

If `b <= a`, that track contributes no audio. A late-starting track must remain late in the child; treating every sliced track as starting at zero shifts speakers. The canonical playback slice is already on the common timeline. Validate cleaned-mic alignment against its actual producer; do not assume every file has the raw mic’s exact length.

Use rational time and one shared sample-boundary calculation. At each sample rate, derive neighboring ranges from the same converted boundary indices; subtract endpoints rather than independently rounding start and duration. Probe and decode outputs, validate their durations and metadata, and preserve original media. Prefer validated passthrough where possible; use bounded decode/re-encode when necessary. AAC passthrough export success is not proof of bitwise decoded-sample equivalence or perfect privacy redaction; this feature is not a redaction tool.

Apple provides [range export](https://developer.apple.com/documentation/avfoundation/avassetexportsession/timerange) and [reader/writer APIs](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/05_Export.html). No FFmpeg dependency is necessary for this feature. The macOS 14.2 deployment floor requires an availability-compatible export path.

### Transcript boundaries and speakers

Partition the original interval into contiguous half-open ranges covering the entire source. Fast-path cuts must not intersect **any** word interval, including words from overlapping speakers. A timestamp at one speaker’s word boundary can still cut another speaker’s word. For a cut inside continuous speech, move to a user-approved safe gap or defer to a more expensive explicit reprocessing path.

Slice words, subtract the child start, rebuild passage ranges against the child’s word array, and mint new durable passage IDs. Preserve complete passage text where possible and use existing language-aware derivation for reconstruction; naive joining with spaces damages punctuation and languages without word separators. Validate text/timing consistency before claiming edits were preserved. Never drop a whole passage merely because it crosses a cut.

Current main adds a critical requirement: snapshot **effective** speaker attribution, including correction revision and explicit unassigned spans. Preserve automatic source provenance separately. Map relevant corrections onto child word ranges and the child fingerprint as a fresh baseline; do not copy the parent’s undo chain or correction IDs. Preserve the labels actually used in each child. Do not enroll new voice profiles, clone full-recording embeddings, or relabel historical assignments as fresh biometric matches. Feature-off behavior must remain feature-off. [Attribution and source provenance](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Services/Diarization/SpeakerAttributionResolver.swift#L99), [profile persistence](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Database/DatabaseManager.swift#L1954).

### Disposition of related data

| Data | Child behavior |
|---|---|
| Audio, words and passages | Independent slices with local times; new identity and passage IDs |
| Speaker labels and corrections | Preserve relevant effective assignments with mapped child provenance; preserve original history only on original |
| Notes | Stay on original. Free-form notes have no dependable time mapping; later manual copying can be explicit |
| Summaries, prompt results, tasks, knowledge cards | Stay on original. Children start without generated results; users may generate fresh results normally |
| Ask conversations, including separate conversation tables | Stay on original; never imply answers based on several meetings apply to one part |
| Meeting labels/types and favorite | Default unset/false on children, with explicit review/copy if subsequently added. Classification can influence prompt availability, so do not copy it as an unnoticed side effect |
| Calendar event, attendees and start context | Retain as original provenance, not asserted child identity. A recording spanning multiple meetings is precisely where the first event is likely wrong for later parts |
| Engine/model provenance | Carry the source transcription’s attribution with a “derived by split” provenance record; no claim of a new model run |
| Capture quality | Preserve parent warning as inherited context. Do not copy parent duration/coverage into a child’s capture report |
| Search index and exports | Derive child search records from child content and effective attribution; materialize fresh artifact exports. Do not copy export paths |
| Original references | Keep old IDs/citations intact. Children get new citation scopes and a link to their source range |

**Per-child capture coverage cannot generally be reconstructed from today’s aggregate counters.** `writtenFrameCount` and `timelineFrameCount` distinguish captured frames from inserted padding but do not locate each missing interval. Clamping or proportionally distributing those totals invents evidence. Store “derived from partial recording; per-part coverage unknown” when appropriate; precise reports require interval-level provenance or additional measurement. The existing nil report means unknown, not healthy. [Alignment/capture fields](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Services/MeetingRecording/MeetingRecordingMetadata.swift#L3).

### Dates, retention and provenance

Add narrowly scoped split provenance: operation ID, source meeting ID, source content fingerprint/revision, source range, part ordinal and split-created time. Source references must survive deletion as descriptive provenance without a cascading dependency that deletes children.

Preserve the original recording date and source-relative offsets. Do not present `parent.createdAt + audioOffset` as an exact wall-clock start when pause time was removed; it is at best an estimate. For an initial design, keep the original `createdAt` for retention/date grouping, use part order for siblings, and store split creation separately. This avoids silently granting old audio a new retention lifetime. The current sweeper selects by `createdAt`. **Refuse an audio-producing split when the source is already past its cutoff**, offering text-only splitting or an explicit change to the existing retention setting. Show the inherited removal date when retention is enabled, and recheck eligibility before publication. A hidden grace-period exemption would alter retention policy and is not recommended for this feature. [Candidate query](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/Sources/MacParakeetCore/Database/TranscriptionRepository.swift#L469).

## Atomic creation and recovery

Use a dedicated `MeetingSplitService` in Core with a pure planner, an audio range exporter and a repository transaction for publication. ViewModels own preview/progress; SwiftUI owns presentation. Expose the same saved-corpus operation through the CLI with a preview/dry-run, expected source revision and idempotency key. These CLI names/options are a proposal, not existing commands. Update the artifact, recovery and CLI contracts together; do not introduce another service protocol for agents.

```text
Validate and lease source
        ↓
Snapshot content + corrections + audio identity
        ↓
Stage all child files and artifacts; validate them
        ↓
Install independent folders; recheck source revision
        ↓
One DB transaction: all child rows + provenance + derived search state
        ↓
Publish success, settle operation journal, release lease
```

Filesystem renames and SQLite commits are not one atomic transaction. Journal operation intent and fixed child IDs before file work; keep staging outside normal recovery enumeration. Install validated folders before publishing rows, so the database never exposes children with absent media. A crash before DB publication leaves recoverable staged outputs, not a partially visible split. A crash after commit is recognized by operation ID and settled without making duplicate children.

All children should become visible together. A disk-full failure on part three must not quietly leave only parts one and two as the result of “Create 4 meetings.” Preserve the original throughout. Cancellation/discard may remove only files positively owned by that operation, after writers stop; startup must not broadly delete unfamiliar directories.

An ordinary database transaction failure after folder installation follows the same non-publication rule as a pre-commit crash: the transaction rolls back every child row, the journal records failure, and prepared files stay associated with that operation for retry or explicit discard. Report “No new meetings were created” rather than partial success. Release the lease only after writers have stopped and recoverable operation state is durable.

Admission and mutation guards must coordinate across GUI/CLI, retranscription, deletion and retention. A new in-memory lock is insufficient. The existing finalization mutex and `recording.lock` semantics are useful precedents, but a split journal is not a recording lock. Explicitly integrate a split lease with relevant mutators/sweepers rather than relying on a new file they do not inspect. Revalidate source content and correction revision before publication; row `updatedAt` alone does not describe every related-table change. External Finder changes also require file-identity/read-failure checks. [Recovery contract](https://github.com/moona3k/macparakeet/blob/aaf3dc261536e5fc5158c4b1ca714bd3f4cece19/spec/contracts/meeting-recovery-retention.md).

Use fresh insert semantics, not generic upserts that could replace an existing ID. Reuse transaction-level segment derivation rather than independently committing each child through today’s public save methods. Artifact refresh is per-file atomic today, not a multi-meeting commit protocol. Splitting must not trigger recording-completion hooks, automatic summary policies or provider calls.

## Measured feasibility and cost

The [standalone Swift experiment](audio-range-spike.swift) generated an eight-second, 48 kHz mono tone recording, encoded it to AAC, and split it at 2.137 and 5.419 seconds with both AAC re-encoding and passthrough.

**Final observed result:** all six exported files decoded, were non-silent, and had exactly the requested decoded frame counts and durations: 2.137, 3.282 and 2.581 seconds. The original SHA-256 was unchanged. Individual exports took roughly 4–5 ms on this machine after source setup. See [results](audio-range-results.json).

The [initial attempt](audio-range-results-initial.json) independently converted floating-point start/duration values and lost one frame in the middle part (0.020833 ms at 48 kHz). The final experiment uses integer endpoints shared across neighboring parts. This is a small but concrete reason to specify the boundary arithmetic.

These measurements establish basic local range-export viability, not real-meeting performance, waveform equivalence, dual-source alignment, crash safety, macOS 14 compatibility or production readiness. Do not extrapolate the short-fixture timing to hour-long recordings.

Storage scales with total selected duration, not the number of parts: three non-overlapping parts covering the full recording add approximately one more recording’s audio when encoding is comparable. Example assumptions only: two raw mono tracks at 96 kbps, playback at 128 kbps and cleaned mic at 64 kbps total 384 kbps, or about **173 MB per hour**. Keeping original plus parts is about **346 MB per recorded hour**, before temporary overhead. Actual codecs, missing tracks and bitrate settings change this; preflight should sum real source sizes and budget exporter overhead. A three-hour recording at that illustrative rate needs about 518 MB additional, not three full extra copies.

## Delivery plan and verification gates

1. **Implement the split kernel and eligibility rules.** Validate safe boundaries, transcript consistency, timestamps, child provenance and speaker projection. Include valid text-only sources. Add the governing contract before exposing the action.
2. **Implement independent audio export and durable publication.** Handle source offsets, legacy names, optional tracks, integer sample boundaries, low disk space, cancellation, source changes, retention and crash recovery. The source-preserving fast path must be complete before UI success can be reported.
3. **Add the native preview flow and CLI parity.** Integrate Library/Meetings/detail entry points, title editing, boundary preview, progress, text-only copy, original links and specific unavailable states. Keep any suggested boundaries local and optional.
4. **Later:** silence-based suggestions, reviewed calendar hints, exclusion of breaks, edited-text reconciliation, and explicit per-part STT for untimed recordings. Automatic semantic splitting is unnecessary for resolving #895.

Planning estimate, not measured delivery: roughly **one to three engineer-weeks** for a reviewed first release with recovery and integration coverage, depending on how reusable the current transaction/lease boundaries prove. The actual media trim is a much smaller portion; a short technical spike can establish that independently. Do not promise a release date from this estimate.

Required verification should include:

- Pure partition cases: two/three/four parts, duplicate/zero/end cuts, out-of-order input, long recordings, CJK text, all words preserved exactly once, overlapping speakers and cuts inside words/passages.
- Current-main speaker correction cases: explicit unassigned spans, renamed/manual speakers, undo history remaining on original, stale fingerprint/revision rejection, voice-profile feature-off no-read/no-write behavior.
- Database/artifact integration: all-or-none visibility, fresh IDs and child FTS, correct exports and local timestamps, old citations unchanged, source deletion leaving children usable, deletion of one child leaving siblings usable, no AI/hook side effects.
- Fault injection: disk full at every stage, cancel while exporting, crash before/after folder install and DB commit, retry with the same operation ID, retention/delete/retranscribe from a second process, missing or malformed sidecars and lost source files.
- Media fixtures: asymmetric source starts/ends, different rates, raw/cleaned mic, recovery padding, partial capture, canonical single-source fallback, legacy recordings and audio removed. Decode outputs and check actual sample content around cuts, not only container duration.
- Final native QA on retained multi-hour recordings and the minimum supported macOS, plus relevant focused tests and one full project suite at the final implementation gate. None of those production gates was run for this research.

## Corrections to the delegated working notes

The working notes are useful code-discovery evidence, but several initial suggestions were rejected in this synthesis:

- Independent folders reduce coupling; they do **not** eliminate changes to retention/recovery coordination or artifact provenance.
- Aggregate frame counts cannot establish per-part capture coverage or the locations of recovery gaps.
- Do not copy the first calendar event, all notes or the whole capture report into every part; those can describe a different meeting.
- Keep the original title/content unchanged. Do not publish partial groups or silently drop crossing passages.
- Do not infer that word timings alone prove displayed text is aligned, or that base speaker IDs include current correction state.
- A valid timed transcript can support an explicitly labeled text-only split after audio removal. Conversely, untimed audio is still technically splittable; it needs a different transcript workflow.
- Provide saved-corpus CLI parity through the same service. The raw notes’ proposal to defer it was not adopted.

The frontend and prototype skills shaped the artifact into an offline, native-style interaction model with synthetic data and explicit state. Its browser verification is recorded separately in `artifact-check.json`; that receipt verifies the HTML concept, not the Swift feature.

The [final Sonnet review](recommendation-review.md) found no blocking factual errors in its targeted current-main checks. Its retention and ordinary-transaction-failure caveats were resolved above. Date grouping and visible original/part relationships remain required first-release behavior, not optional follow-up polish.
