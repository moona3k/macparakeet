---
title: Split editor validation and current-position actions
type: fix
date: 2026-09-25
---

# Split editor validation and current-position actions

## Goal and scope

Address manual QA finding 1: applying playback at zero or at another cut must not damage a valid split draft, “Use current position” must look actionable when available, and typed invalid times must show understandable recovery guidance. Final native-app QA belongs to the user; deliver a reviewed PR without merging.

The existing local QA log and screenshots stay local. This plan describes the behavior without publishing the recording title or screenshots.

## Code findings

- `MeetingSplitSheetView.boundaryRow` always enables a subtle-styled button and forwards playback directly to `updateCut`.
- `updateCut` mutates the draft before `revalidate` checks it. This allows zero, terminal, duplicate, and unordered cuts into the draft.
- `revalidate` uses `localizedDescription` on `MeetingSplitCutValidationError`, which has no `LocalizedError` conformance. The sheet exposes the internal error domain/code.
- Editable time text and parsed millisecond values are separate. Availability must use current text; malformed edits retain an older numeric value.
- `addSplit` already inserts a valid midpoint in the longest range. Preserve that behavior and custom part titles.

## Intended behavior

- Render “Use current position” as an existing secondary action with native disabled semantics.
- Enable it only in a ready, editable draft when replacing that row with the playback position produces valid cut geometry and changes the parsed time. Ignore title errors for this action so time editing remains possible.
- Validate the proposed cuts using the existing Core geometry validator, reading other rows from their current text. Never use stale parsed values from incomplete neighboring edits.
- A malformed target row can be repaired using a valid playback position, even if its old numeric value equals that position. Other malformed rows must be corrected before applying playback.
- Recheck the same predicate inside the action. Invalid or unchanged actions are no-ops and preserve all text, cuts, titles, and validation state.
- Typed editing remains permissive while drafting; invalid geometry disables submission and shows plain-language guidance for bounds and order/duplicates. No sorting, clamping, or automatic movement of cuts.
- Explain the action's requirements in its help/accessibility hint.

## Invariants and exclusions

Keep audio export, source preservation, persistence, CLI behavior and error schemas, leases, processing, retry/resume, retention, default midpoint insertion, and title ownership unchanged. No model calls or semantic classification are needed; time validation is deterministic. No new visual system or editor abstraction.

## Implementation

One cohesive change across the sheet, view model, and its tests: add a guarded playback-position action plus availability predicate; map typed Core validation failures to UI messages in the view model; wire secondary styling and disabled/help states in the sheet. Update the governing split contract and original feature plan with these editor rules.

## Verification

- Strengthen an existing out-of-order test and add zero/duplicate manual-entry assertions; observe failure before implementation.
- Exercise valid application, zero/end/outside positions, duplicates, both ordering directions, unchanged positions, first/last millisecond cuts, stale indices, no draft, active processing, malformed target repair, malformed neighbor blocking, and title-error independence.
- Verify invalid action attempts preserve the complete draft and do not call the processing service.
- Run focused split tests during iteration; run the full Swift test suite at most once as the final gate, subject to available disk/build resources.
- Review the exact diff independently, run formatting checks, open the PR, and report CI and any unavailable tooling honestly.

## User QA

1. At playback zero, the current-position button is visibly disabled and does not disturb the default split.
2. Move to a valid different time: the button becomes enabled and applies the time; it disables again when the time matches.
3. Add another split: applying a duplicate or a position across a neighboring cut is disabled for that row; a valid interior position is enabled.
4. Type zero, recording-end, duplicate, and reversed times: submission is disabled with understandable guidance. Correct them and verify the error clears.
5. Replace an incomplete target time using playback, and confirm normal add/remove/title editing still works.
