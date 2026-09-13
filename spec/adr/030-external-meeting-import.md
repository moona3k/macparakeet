# ADR-030: Import external recordings as managed meetings

**Status:** Accepted
**Date:** 2026-09-13

## Context

People have useful recordings from before MacParakeet or from other recorders.
Generic file transcription does not enter the meeting lifecycle with its
speaker-aware playback, artifacts, retry, and meeting automation. External
files remain user-owned; importing them must not grant MacParakeet authority
to delete or rewrite those originals. Historical dates also cannot serve as
the retention age of a newly stored copy.

## Decision

Offer one-file import in Meetings and `macparakeet-cli meetings import` through
one Core service. Normalize a supported local audio/video file into a managed
system-only meeting archive and use ordinary meeting finalization, settlement,
and saved-audio automation. The default audio stream selected by the converter
is sufficient for this first version.

Keep the chosen historical date in `createdAt`. Add nullable
`audioRetentionStartedAt` for the owned copy's retention age; existing rows
fall back to `createdAt`. Retention queries, policy evaluation, and meeting
split eligibility share that rule. A normalized non-nil `titleOverride`
records intentional meeting naming, including later renames, so automatic
generation and Retry preserve it.

Use the existing recovery lock, finalization lease, and settlement authority.
The archive and lock precede the row; optional lock metadata preserves the
historical date, retention clock, and title intent if recovery reconstructs a
missing row. A published import that cannot complete transcription remains
retryable under the same meeting identity. After a transcript is durable,
subsequent automation or settlement warnings cannot turn it into a failed
transcription or encourage a duplicate import.

The [meeting import v1 contract](../contracts/meeting-import-v1.md) governs the
app/CLI behavior and result classifications. This decision is not evidence of
a shipped stable release or physical/runtime verification.

## Consequences

The managed copy consumes storage independently of its external source. Users
may delete or retain each independently. Retention and deletion only operate
on MacParakeet-owned artifacts. Delete-immediately is applied after a successful
import; retryable imports keep managed audio until Retry can finish. Import does
not change local STT or explicitly configured AI-provider boundaries.

App-owned task state permits sheet dismissal without losing progress or a
terminal result. The CLI reports durable partial completion with warnings and
exit zero; transcription-needs-retry results exit nonzero with the saved
meeting identity. Duplicate imports deliberately create separate meetings.

Batch import, drag and drop, duplicate detection, source bookmarks, linked
media, embedded-track selection, and a general automation retry scheduler are
outside this decision.
