# Live Dictation Preview — Stable Rolling Readout

> Status: **SHIPPED as #534; archived 2026-07-16**
> Requirement: REQ-DICT-007 (display-only live dictation transcript preview)
> Flag: `AppFeatures.liveDictationStreamingEnabled` (shipping since v0.7.0)
> Scope: refinement of the existing preview — no new feature surface, no flag change

## Problem

The live dictation preview above the pill is hard to follow. Two compounding
causes:

1. **Unstable rendering.** The preview is a fixed two-line `Text` with
   `.truncationMode(.head)`. Every update re-lays-out both lines and the
   head-truncation point shifts, so the same left edge shows different words
   each frame — the text *jumps*. The `.suffix(180)` character cut lands
   mid-word, and head truncation prepends `…` at a non-word boundary, so the
   user sees `…ybody` / `…those`.

2. **Unstable content.** For Parakeet the preview re-transcribes a rolling
   ~15-second audio window once per second and *replaces* the transcript
   wholesale. There is no stabilization: words can be revised retroactively
   between passes, and as the window slides the oldest words fall off the
   front. Nemotron emits cumulative partials whose tail churns. Either way the
   text the user is mid-read wobbles underneath them.

## Goals

- Newest words enter at the bottom; older lines rise and **fade out** at the
  top edge instead of being hard-cut with a mid-word ellipsis.
- The body of the readout is **stable** — once a word has settled it does not
  jump, change, or disappear. Only the live edge (the last few words) moves.
- No regression to latency, the recording pill, or — critically — the pasted
  text.

## Context Zone

**In scope**
- The preview's on-screen rendering (`DictationOverlayView` preview panel).
- A stabilization layer between the raw preview transcript and what the view
  renders, applied at the single `DictationService` chokepoint that feeds
  `liveTranscriptText` (covers both the Parakeet tail-window path and the
  Nemotron cumulative-partial path).

**Out of scope / must not change**
- The stop-time transcription path that produces the **pasted** text. The
  preview is display-only and must stay decoupled (REQ-DICT-007).
- The STT scheduler/runtime, the audio capture path, the 1s preview cadence,
  the 15s window length, engine routing, and the feature flag.
- The Settings toggle and the preview text-size picker (kept as-is).
- Whisper stays default-off for the preview.

**Invariants**
- Preview text never feeds the clipboard/paste.
- Stabilization is pure and runs inside the existing `DictationService` actor
  isolation — no new threads, no new async hops.
- A new dictation session starts from an empty, reset stabilizer.

## Design

### Stage 1 — Rendering (`DictationOverlayView.swift`)

Replace the fixed two-line head-truncated `Text` with a bottom-anchored
readout:

- A non-interactive vertical `ScrollView` pinned to its bottom (newest text),
  showing ~3 lines, left-aligned. `.allowsHitTesting(false)` so it never
  intercepts events from the pill below; programmatic `scrollTo(.bottom)` on
  each text change (no animation — avoids jitter from frequent updates).
- A top fade `.mask` (`LinearGradient`, clear → opaque over the top ~22%) so
  older lines dissolve at the top edge. No `.truncationMode(.head)`, no hard
  mid-word `…`.
- The visible string is a generous word-bounded tail (last ~45 words) — never
  cut mid-word.
- Keep the existing appear/disappear transition and the live size animation.
- Extend `previewMetrics` with a per-size `visibleHeight` (~3 lines).

### Stage 2 — Stabilization (`LiveTranscriptStabilizer` + `DictationService`)

A pure value type, `LiveTranscriptStabilizer`, turns the wobbly stream into a
monotonic, append-only readout:

- Holds `committedWords` (append-only within a session).
- `ingest(_ raw:) -> String`: aligns the latest raw transcript against the
  tail of `committedWords` (longest committed suffix, up to an anchor length,
  found contiguously in the new words). Multi-word anchors use the leftmost
  match so repeated phrases are preserved; weak single-word anchors use the
  rightmost match so adjacent transcriber stutters are not duplicated. Commits
  every newly-revealed word **except** the last few (`hypothesisHoldback`),
  which stay tentative so an incomplete trailing word is never frozen. Returns
  `committed + hypothesis`.
- Disambiguates the no-overlap case: if the new words are already contained in
  the committed tail it is a shorter re-statement (retraction) → nothing new;
  otherwise it is a genuine gap (long pause) → append.
- Caps `committedWords` for memory; the view caps the rendered tail again.
- Works uniformly for the Parakeet sliding window and Nemotron cumulative
  partials (cumulative growth is just the always-overlapping case).

Wired into `DictationService` at the two existing update points
(`updateDisplayPreview`, `updateLiveTranscript`) via a single
`setLiveTranscript(raw:)` helper; `clearLiveTranscript()` resets the stabilizer
at every session start/stop/clear boundary.

## Testing

- `LiveTranscriptStabilizerTests` (pure, deterministic): first ingest;
  growing window; sliding window with front-drop; trailing-word revision does
  not corrupt the committed body; repeated phrases; Nemotron cumulative
  partials; shorter re-statement (no duplication); long-pause gap; empty
  interim; memory cap; reset between sessions.
- `swift build` (typecheck) + full `swift test` for no regressions.
- Manual eyeball on a real dictation (mic) — the only way to validate the
  rendering visually; both engines.

## Rollout

No flag change — REQ-DICT-007 stays enabled on `main`. Update the REQ-DICT-007
description and the relevant spec notes to reflect the stable rolling readout.
Single PR, two commits (Stage 1, Stage 2) plus plan + docs.
