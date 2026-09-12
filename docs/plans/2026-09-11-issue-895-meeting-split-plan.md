---
title: Split and transcribe - Implementation plan
type: feat
date: 2026-09-11
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: user-approved-split-and-transcribe
execution: code
origin: docs/research/2026-09-11-issue-895-meeting-split/report.md
---

# Split and transcribe

## Goal and authority

Repair a recording that spans two, three or more meetings. The user chooses manual audio boundaries; each part becomes an independent saved meeting and receives fresh transcription followed by the normal enabled meeting automations, including summaries.

This user-approved revision supersedes the earlier transcript-preserving research, the intermediate audio-only proposal, and conflicting HTML behavior. Processing time is an accepted cost. This document specifies the feature; it does not claim the implementation is shipped.

The [product contract](../../spec/contracts/meeting-splitting.md) governs behavior. Historical research remains useful for media experiments, not for old eligibility or metadata requirements.

## User experience

The action is **Split and transcribe**. Start with one editable cut and two part titles. Allow adding/removing cuts for three or more parts without a four-part cap. Reuse existing playback and time-entry controls; transcript context is an optional navigation aid. No automatic meeting detection, elaborate editor, permanent transcript-editing mode or WebView is required.

Before creation, show:

- Each part's title, source audio range and duration.
- The original stays unchanged; parts consume additional storage.
- Processing happens sequentially and takes time.
- Each part receives a new transcript and speaker labels, plus enabled meeting automations. Original corrections and derived content are not copied.
- The existing transcription/automation settings and provider privacy behavior apply; splitting does not silently enable providers or change settings.
- The original recording date remains the retention anchor; splitting does not renew audio lifetime.

Use native accessible controls and `.parakeetAction(...)`. Show separate audio-preparation and per-part processing progress. After audio publication, cancellation means stop processing, not undo creation. Keep completed and unfinished parts visible with retry actions and links to the original/siblings where they still exist.

## Settled behavior

1. **Audio is authoritative.** Cover the whole validated audio timeline with contiguous parts, retaining pauses. Reject duplicate, unordered, zero, terminal or out-of-range cuts. Crossing a word, missing timestamps or edited transcript text never blocks a valid audio cut. Prefer pauses through user choice, not automatic cut movement.
2. **Independent ownership.** Preserve the original row and every original artifact. Every part, including the first, is a new recording receiving its first transcription; no part is the original's remaining fragment. New IDs and independently owned media let users delete the original or any sibling without breaking remaining parts. Copying the original transcript, correction history or speaker baseline is unnecessary.
3. **New meeting processing.** Save all audio parts safely first. Then process each saved ID sequentially through existing speech processing and normal enabled meeting completion automation. Generate new transcripts, speaker labels and results. Do not copy notes, summaries, tasks, prompts, conversations, calendar identity, classification or favorites from the parent.
4. **Durable retry.** A failed/cancelled transcription or automation leaves audio parts saved. Retry unfinished work on those IDs; never split again or recreate deleted children. Preserve successful transcripts/results instead of redoing them just because a later stage failed. Continue to later parts after an individual failure; user cancellation stops starting further work.
5. **Retention and privacy.** Initial child recording dates retain the source age. Recheck current age-based expiry before publishing audio; expired/missing source audio cannot be split. The existing delete-immediately preference governs new capture, not retroactive removal of historical retained audio. Do not assert measured per-part capture quality from source aggregate counters.

## Small shared implementation

Core owns the operation; GUI and CLI call the same behavior. Separate audio creation from processing internally, without making callers sequence file/database publication themselves.

### A. Save the audio parts

- Inspect/preview without writes, migrations or lock creation. Probe actual media duration and capture source/media identity for creation revalidation.
- Acquire cross-process media ownership shared with complete deletion/retention mutations, including both their file and database phases. Do not reuse live-recording recovery locks.
- Persist a small feature-specific operation receipt with the approved request and fixed child IDs before exporting.
- Prepare positively marked, exclusively owned child folders at final paths, with validated audio and ordinary meeting artifacts. These are absent from the library until publication, not invisible to Finder.
- Revalidate the source and retention, then fresh-insert all child rows and commit the receipt in one short GRDB transaction. Precompute expensive work outside the write lock. No required post-commit artifact repair.
- Await writer termination before returning cancellation or releasing ownership. Discard only positively identified unpublished operation output. Unfamiliar folders are conflicts, not cleanup candidates.

Committed retries return the original IDs even if source/children were deleted; different requests under the same key conflict. Interrupted preparation may be retried or explicitly discarded. No broad startup cleanup or general workflow engine is needed.

### B. Process the saved IDs

Use a small sequential coordinator with existing Core saved-audio transcription methods and shared meeting-completion behavior. Persist enough per-part stage/outcome information to resume unfinished work after restart without resplitting. Distinguish transcription failure from automation failure; a summary failure does not erase a successful transcript.

The current app capture queue is not a generic saved-recording queue: it carries recording generations, finalization leases and settlement. Do not force split children through synthetic capture/recovery state. The normal retranscribe UI intentionally skips auto-prompts; merely calling it does not meet this feature's completion contract.

Extract only the existing completion behavior needed by both products into a narrow reusable Core service or adapter. Preserve prompt selection, provider settings, result persistence and retry semantics. Do not build a second summary pipeline or teach the CLI to call ViewModels.

The user permits pragmatic scope decisions: full meeting treatment is the intended experience, not a mandate to refactor the whole processing system. If one automation requires disproportionate work, report that specific limitation and recommend a bounded adjustment. Existing internal methods named `retranscribe` describe processing already-saved audio, not the child's product lifecycle; use clear saved-audio naming at the new boundary without a global rename.

Ensure canonical-playback-only parts use the existing single-file saved-audio route when aligned raw tracks are absent. An archived meeting with an empty source-alignment list must not be treated as a successful empty transcription.

Do not promise exactly-once external effects across a crash after a provider accepted work but before a local receipt was saved. Reuse existing idempotency where available; record ambiguous delivery and expose a deliberate retry rather than silently repeating an uncertain external action. This is distinct from duplicate-free local meeting creation.

## Delivery order

### U1. Establish the revised contract

Land this docs-only scope revision first. Mark old research/HTML as historical. Record inspected pipeline behavior and verification limits. No app feature, schema migration or automatic issue closure belongs in this PR.

### U2. Deliver Core and CLI end to end

Retain useful audio-export and media-deletion-ownership work. Remove transcript partitioning and split-specific speaker-baseline machinery. Implement the smallest range planner, safe group creation, sequential saved-audio processing and shared completion automation.

Expose CLI preview, Split and transcribe, operation status and retry/cancel/discard semantics through the same Core surface. Use existing CLI JSON/envelope conventions and settings. Update integration documentation, help/spec discovery and contracts with actual names. Start with a synthetic two-part success through saved audio, transcription and enabled summary completion.

### U3. Add native interaction and failure coverage

Use a focused native sheet or equally small interaction, informed but not dictated by HTML. Keep state testable in an observable ViewModel. Verify two/three-part title/range editing, processing progress, keyboard/VoiceOver access, cancellation, retry and independent navigation/deletion.

### U4. Verify and deliver

Commit each meaningful verified milestone. Use one implementation PR unless a genuinely independent change warrants a separate PR. Resolve valid independent review findings, publish a self-contained PR and merge after relevant local verification. Slow CI is not an instruction to skip known failures or claim unrun tests passed. Stable release is separate.

## Acceptance tests

- Exact approved audio ranges with independent IDs/files; original row/artifact hashes unchanged.
- Inside-word boundaries, edited text and absent timing work because original transcript content is not used for eligibility.
- No original speaker corrections, notes, summaries, tasks or other derived content are copied.
- Fresh transcription and enabled normal completion automation operate on each child ID, sequentially, with normal provider/privacy settings. Disabled automation stays disabled.
- Canonical-only and aligned raw-track sources both receive actual STT; no empty-source false success.
- Last-child export/materialization/insert failure publishes no children. Pre-publication interruption/retry does not duplicate output.
- Transcription failure/cancellation leaves published audio available. Completed parts and successful stages are not unnecessarily repeated; automation failure can retry without resplitting or rerunning successful transcription.
- Restart and repeated submission use durable identities; deleted children are never resurrected. Test duplicate processing submissions separately from duplicate audio creation.
- Concurrent deletion/retention/source changes are excluded or rejected safely; process death releases ownership. Honor retention at publication and before later audio use without a hidden grace period.
- Deleting any source/sibling does not damage another part. A source deletion after publication does not prevent processing independent children.
- Preview writes nothing; GUI and CLI use the same outcomes. Explicit external-effect ambiguity is not mislabeled exactly-once success.
- Use synthetic/approved fixtures, not personal recordings or databases. Measure hour-scale audio time/memory/storage and note minimum-OS runtime limits.

Run focused tests while iterating, build in the owning worktree, and run the full Swift suite at most once at the final code gate. Follow the repository review workflow in proportion to risk. Record exact commands, test counts and unverified behavior. Future implementation owns runtime acceptance, not this documentation PR.
