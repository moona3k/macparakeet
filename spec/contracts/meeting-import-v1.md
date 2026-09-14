# Meeting Import v1

This contract governs one local recording imported through Meetings or
`macparakeet-cli meetings import <path>`. It follows
[ADR-030](../adr/030-external-meeting-import.md), the
[meeting artifact contract](meeting-artifacts-v1.md), and the
[recovery and retention contract](meeting-recovery-retention.md).

## Input and metadata

Accept one local regular file with an extension supported by
`AudioFileConverter`. Missing, non-file, unsupported, corrupt, and audio-less
inputs fail before exposing a library row. For video, use the converter's
first/default audio selection. The external source is never modified, moved,
renamed, or deleted, and its path is never stored as owned meeting audio.

The initial title is the source filename without its extension. The meeting
date defaults to file creation, then modification, then the current date. The
app permits editing both before starting; CLI `--title` and `--started-at`
override the same defaults. Date-only CLI values mean local calendar midnight;
ISO-8601 values preserve the supplied instant. Explicit future dates are valid.

`createdAt` controls historical meeting chronology. The fresh
`audioRetentionStartedAt` controls managed-audio age with fallback to
`createdAt` for legacy rows. A normalized non-nil `titleOverride` marks an
explicit title and prevents automatic replacement during completion or Retry.
Meeting renames set that same marker; filename defaults and generated names
remain eligible for automatic generation. Repository completion saves preserve
the durable retention clock and title intent.

The current meeting-audio retention setting applies to the managed copy. Timed
retention starts at `audioRetentionStartedAt`; keep-forever retains it; and
delete-immediately removes managed audio only after successful transcription
and completion of the automation attempt, including a stopped or failed attempt.
Retryable imports retain audio regardless of that setting so Retry can finish the
same meeting. A cleanup failure is a partial-result warning.

## Managed publication and ownership

Normalize into an importer-owned hidden staging folder under the configured
meeting-recordings root. The destination phase holds the existing root media
mutation lease. Verify decodable audio, duration, sample rate, and nonzero
frames before publication. Store `system-raw.m4a`, canonical
`meeting-playback.m4a` through a hard link with copy fallback, and ordinary
recording metadata with system-only zero-offset alignment.

Write the ordinary `awaitingTranscription` recovery lock before moving the
archive into its UUID session folder, then save one `.meeting` stub. The lock
carries the historical start date plus optional retention clock and explicit
title metadata. Older locks decode with absent import metadata. A crash after
folder publication but before row creation can reconstruct the intended row.
Existing live-owner checks and finalization leases still prevent competing
recovery. Import does not introduce an alternate lock-deletion authority.

Orderly failure or Stop before row publication removes only the current
importer's unpublished artifacts. Stale hidden importer staging is reclaimed
under the same media mutation lease using the reserved import prefix. Once a
row is published, transcription failure leaves `.error`, and cancellation
leaves `.cancelled`, with owned audio and the protective lock. Ordinary Retry
and recovery complete that same record. Settlement removes the lock only after
verifying the completed meeting and folder association.

## Completion boundary

Use configured final meeting STT and diarization, deterministic text
processing, speaker-aware transcript data, retrieval indexing, and ordinary
meeting artifacts. After transcript durability, attempt configured knowledge
cards and enabled after-meeting prompts through saved-audio automation. Existing
explicit AI-provider settings continue to govern that automation.

Every entry point distinguishes these results:

| Result | Durable state | CLI exit |
| --- | --- | --- |
| Complete success | Completed, usable meeting; requested processing settled | Zero |
| Transcript-saved partial success | Completed, usable meeting with prompt, card, artifact, settlement, or stopped-automation warnings | Zero |
| Transcription needs retry | Error/cancelled meeting with its identity, managed audio, and recovery lock | Nonzero |
| Validation/pre-publication failure | No library row | Nonzero |

A later warning never erases a successful transcript. Progress goes to CLI
stderr; stdout contains only the final human or JSON result. `--json` and
`--envelope` preserve the normal CLI output convention. A durable failure prints
its saved meeting result before exiting nonzero. A normal retryable result exits
one; SIGINT after publication prints the same durable result before exit 130.
Partial success exits zero so an ordinary command retry does not accidentally
import a duplicate.

The CLI JSON result is a `MeetingImportRecord` with `id`, `completion`,
`status`, `title`, `startedAt`, optional `durationMs`, optional
`managedAudioPath`, and a `warnings` array. `managedAudioPath` is absent after
delete-immediately retention removes audio. Each warning exposes a stable
`kind` and plain-language `message`; failed prompts additionally carry their
optional prompt id and name. See the public [CLI JSON contract](cli-json-v1.md)
for output and exit-code details.

## App task lifetime

The native single-file picker opens a compact title/date form. App-owned state
owns preparation, transcription, and automation progress. Dismissing the sheet
or pressing Escape leaves processing running. Stop explicitly cancels it:
unpublished work is cleaned, a published unfinished meeting remains retryable,
and completed transcription survives stopped automation with a warning.
Reopening the sheet shows any unacknowledged terminal result with access to the
saved meeting. Validation and terminal summaries support keyboard focus and
VoiceOver announcements.

## Scope and verification

Re-importing deliberately creates another meeting. Batch selection, drag and
drop, deduplication, external-source bookmarks, link-in-place storage, audio
track selection, and a new automation scheduler are outside v1.

Focused tests cover nullable migration and legacy decoding; fresh retention
for historical meetings in SQL, policy, and split eligibility; explicit-title
survival; source preservation; invalid-input nonpublication; cancellation
before and after publication; same-row Retry; missing-row recovery; live-owner
protection; and full/partial/retry result output. Source and unit-test evidence
are separate from real media, app interaction, and stable-release verification.
