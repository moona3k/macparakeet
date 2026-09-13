# Transcript Correction Submission

> Status: ACTIVE - acceptance boundary for speaker and timed-text correction editors.

## Purpose

Let an editor retain pending input when the view model cannot accept a
transcript correction yet, and learn whether an accepted command ultimately
persisted. Immediate submission acceptance remains separate from asynchronous
persistence.

## Producers And Consumers

`MacParakeetViewModels.TranscriptionViewModel` exposes
`applySpeakerCorrection(_:completion:) -> Bool` and
`renameSpeaker(id:to:) -> Bool` on the main actor. `TranscriptResultView` uses
the immediate result when committing a speaker rename or transferring its draft
to another editing context. The timed-line editor also uses the optional
completion to keep its text draft open when an accepted save later fails.
Other callers may omit the completion and discard the return value.

## Stable Semantics

- `false` means a correction was refused because its service/target is missing,
  attribution is loading, or a previous correction is saving. The caller
  retains the draft and may retry after that state clears. Refusal must not
  replace the automatic attribution.
- `true` means the call was accepted or required no action. It does not mean a
  database write succeeded. A blank name or an unchanged or missing legacy
  speaker can be a no-op.
- Accepted commands through `applySpeakerCorrection` set
  `isApplyingSpeakerCorrection` before returning and complete asynchronously.
  Legacy renames update the in-memory speaker optimistically and persist
  separately. Existing identity, revision, and generation checks keep stale
  completions from replacing newer state.
- The optional completion receives `true` only after the accepted command has
  persisted and its effective projection has published; it receives `false`
  for immediate refusal, missing service/target, or asynchronous failure.
  Asynchronous failures still use the existing error and rollback paths.
- On submission or handoff, an editor transfers or clears an active draft
  only after acceptance. A refused handoff preserves its text and editing
  context; later events from an old context must not finish or cancel the
  current draft. Explicit cancellation, such as Escape, discards the draft.
- A timed-text editor dismisses only after a successful persistence completion.
  Failure preserves the draft and editing context so the user can retry.

## Non-stable Details

Error wording, focus scheduling, rendering context identifiers, and persistence
timing are implementation details. Tests protect ownership and refusal, not a
fixed completion delay.

## Versioning And Compatibility

Ordinary statement-style callers remain compatible because these methods are
`@discardableResult`, and the completion defaults to `nil`. Callers storing a
method reference with an older function type may need to adapt. The callback
does not change the CLI JSON schema or command persistence format.

## Tests That Enforce This

- `TranscriptionSpeakerCorrectionViewModelTests` covers loading/busy refusal,
  persisted success, asynchronous failure, accepted retry, and stale completion
  behavior.
- `SpeakerRenameStateTests` covers draft ownership, refused handoff and stale
  editing contexts.

## When This Changes

Update this contract and the focused view-model/editor tests when submission
acceptance, refusal, or draft ownership changes. Review consumers of both public
methods when changing their signatures or return semantics.
