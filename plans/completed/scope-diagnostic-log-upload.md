# Scope diagnostic-log feedback uploads to a recent window

> Status: **IMPLEMENTED** — issue #451

## Problem

The in-app feedback flow attaches the whole local `dictation-audio.log`
(up to the 5 MB on-disk cap) when a user opts in. The per-line content is
already scrubbed at write time (no audio, no transcript text, device identity
reduced to `present`/`none` + coarse transport). The remaining concern is
*breadth*: a full-history upload can carry weeks of behavioral cadence onto a
public GitHub issue when support only needs the recent window around the bug.

Owner steer: the behavioral metadata itself is valuable for debugging and is
already disclosed via the opt-in + preview affordance — **do not strip per-line
detail**, and don't filter so hard we miss key info. Since it's opt-in, lean
generous: the single change that matters is *not dumping the whole day-1
history* — send a generous **recent window** by default.

## Approach

Scope by *recency of whole lines*, never by redacting line contents.

### Core (`MacParakeetCore/Audio/DiagnosticLogScope.swift`)

- `enum DiagnosticLogScope { case recent, full }`
- `AudioCaptureDiagnostics.scopedLogForUpload(_ raw: String, scope:, now:) -> String`
  - **recent (default)**: keep the tail within the last **7 days** (the issue's
    week ceiling, used directly as the default), with **2 MB / 20k-line** safety
    ceilings, falling back to the last **500 lines** when the user has been idle
    longer than a week so the attachment is never empty.
  - **full (advanced opt-in)**: whole log, tail-capped at the on-disk ceiling
    (`diagnosticLogMaxBytes`, 5 MB).
  - Timestamp parse from each line's leading ISO-8601 token (shared format
    options with the writer; fractional + non-fractional fallback). Lines with
    no parseable timestamp never trigger the time cutoff — they ride the
    size/line caps (covers the "no parseable timestamps" fallback).

### ViewModel (`FeedbackViewModel`)

- New `includeFullDiagnosticHistory: Bool = false`.
- `readDiagnosticLogAttachmentIfNeeded` scopes via Core before base64.
- Remove `.tooLarge` (we now trim instead of reject); add `.empty` for a
  genuinely empty log. Reset the new flag in `resetForm`.

### View (`FeedbackView`)

- Light copy: the attach sentence reads "last 7 days" by default, "your full
  local history" when full is on. Keep the existing privacy framing + preview.
- Add a compact advanced **"Include full history"** checkbox, shown only when
  the user has opted into attaching diagnostics.

## Acceptance criteria (issue #451)

- [x] Default upload no longer attaches full history — recent window only.
- [x] Still useful for startup clipping, no-buffer, silent input, engine
      failures, model-empty (those events land in the recent window / min-tail).
- [x] UI copy accurately states what is attached (recent vs full) and that no
      audio/transcript text is included.
- [x] Tests: date filtering, size/line caps, no-timestamp fallback.

## Out of scope

- Per-line content/redaction changes (already done at write time).
- New telemetry params (would be a two-repo allowlist change).
- A broader multi-source diagnostic bundle (separate follow-up in spec/08).
