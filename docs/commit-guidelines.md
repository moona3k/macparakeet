# Commit Message Guidelines

> Status: **ACTIVE**

This project uses **rich commit messages** as a primary form of project
memory. The git log is durable; chat transcripts and slack threads are
not. Treat each commit message as a small letter to the future reader
who will land here via `git blame` or `git log` with no surrounding
context.

## The spirit

The litmus test for any commit message:

> *A future reader landing here via `git blame`, with no surrounding
> context, should finish the message understanding the change as well
> as you understood it the moment you wrote it.*

That's the bar. Everything below is a scaffolding to help you clear
it, not a specification you must satisfy. The shape of a commit
message should follow whatever serves comprehension for *this specific
change*:

- A multi-system polish or architectural move earns depth — themed
  subsections, quantitative justification, internal-pattern
  anchoring.
- A targeted bug fix earns a tight Root Intent + a few sentences on
  why it broke + the fix.
- A typo or one-line change earns one well-written paragraph and no
  template at all.

The agent (or human) writing the commit has full latitude to choose
the shape. The bar is the litmus test, not the section count.

## The standard scaffolding

For comprehensive commits — multi-file UX polish, architectural moves,
new features, anything where a future reader will need more than a
glance — the following structure usually works:

```text
<title> (imperative mood, under 70 chars; `subject: detail` form is fine)

## What Changed
What changed in the diff, grouped into themes when there are several.
For 3+ themes, use ### subheaders. Each item should answer "why this
specifically?" — anchor decisions to existing internal patterns by
name, cite evidence (observed timings, screenshots, mathematical
reasoning), and call out the technical primitives behind non-obvious
choices.

## Root Intent
One paragraph naming the trigger that prompted this work (a specific
bug, a demo blocker, a perf number, an audit finding). Enough that
someone reading in 2027 with no project context understands the
motivation.

## Seed Prompt
The highest-level intent from which the whole change could be
reconstructed — the architect's brief, not a stepwise recipe. State
the goal, the constraints (don't break X, match Y's pattern), and the
design decisions that were settled before the work began. Reference
design docs and ADRs by name. Name specific files only when the
location is itself part of the intent — an agent reconstructing this
should be able to rediscover the right files from the intent alone
(case by case; a surgical fix may warrant them, a feature usually
doesn't). This section was formerly titled "Prompt That Would Produce
This Diff"; older commits use that heading.

## ADRs Applied (if any)
Links to architectural decisions that informed the change. If none,
say "None — this is X polish, not architecture" so the reader knows
it's a deliberate omission rather than oversight.

## Author's Notes (optional, encouraged for agent authors)
Honest first-person reflections from whoever wrote the diff: what
surprised you, what you are least confident about, where you
disagreed with the brief and what you did about it, debt knowingly
left behind, anything the reviewer should probe. Candor beats polish
— a doubt recorded here is a gift to the next debugger, and
disagreement with the brief is signal for the architect, not
insubordination.

## Files Changed
Per-file rationale with line counts. For comprehensive changes, the
rationale lines are more valuable than the line counts.
```

The scaffolding is a **default**, not a specification. If a different
shape serves the spirit better for this specific change, use that
shape.

## Latitude

Examples of when departing from the scaffolding is the right call:

- **Typo / one-line fix**: title + one paragraph explaining the bug
  is plenty. No What Changed, no Root Intent, no Files Changed.
- **Refactor with no behavior change**: a "Before / After" framing
  may serve the reader better than "What Changed / Root Intent"
  because the relevant question is "is the new shape better, and is
  it safe?"
- **Doc-only commit**: a single paragraph explaining the editorial
  intent often beats the full template.
- **Multi-fix bugfix with refuted findings**: a "## What Changed"
  list of numbered fixes + a "## Refuted" section for the findings
  you rejected with reasoning is often more useful than the standard
  Root Intent / Prompt split.
- **Cross-cutting polish session**: themed subsections inside What
  Changed (`### 1. Bottom-anchored Capsule`, `### 2. Sacred-geometry
  indicators`, ...) lets the reader navigate the change.

The agent's judgment about shape is part of the work. A commit message
mechanically filled out to match the template can fail the spirit
test; a commit message in an unconventional shape can pass it.

## Depth bar (when going comprehensive)

When a change warrants the full treatment, the difference between a
perfunctory rich commit and a great one is **substance density** per
section:

- **"Why this specifically?"** — for every non-obvious design knob,
  answer this. Why 5 seconds and not 10? Why squared rose curves and
  not standard `cos(kθ)`? Why `Task.yield()` and not `DispatchQueue`?
  The answer should be quantitative, mathematical, or empirical —
  not "it felt right."
- **Anchor to internal patterns by name** — say "extends
  `DictationOverlayView`'s `isIconOnly` branching" rather than
  "follows a common pattern." The names are searchable; the platitudes
  aren't.
- **Name the technical primitives** behind subtle choices — e.g.,
  "SwiftUI updates are runloop-bounded, so reading `fittingSize`
  synchronously after mutating `@Published` returns the previous
  layout — that's why we yield once before re-measuring."
- **Trade-offs considered and rejected** — what you chose not to do
  is often as informative as what you did. "Refuted" sections (with
  reasoning) are valuable.
- **What's out of scope** — name what this commit *doesn't* fix so a
  future reader expecting more doesn't go hunting.

## Exemplars

These commits on `main` demonstrate the spirit at different scales.
Read them with `git show <hash>`:

- **Comprehensive UI polish** — `6e7b61b5` (Polish Stats sub-tab:
  brand glyph, rich hover popover, coral pill picker). Many themed
  bullets covering picker chrome, heatmap hover popover, today's
  breathing pulse, typography unification — each with quantitative
  design rationale (cell size 12pt → 16pt, breathing-pulse 1.8s
  ease-in-out, empty-cell `opacity(0.07)` vs near-invisible
  `surfaceElevated` in dark mode). Internal-pattern anchoring
  throughout (matched-geometry pill, brand accent, `design:
  .rounded` typography).
- **Multi-fix bugfix addressing review feedback** — `e2af13d7`
  (Round 2 review: rename(2) commit, persist-then-delete, Sendable
  tests). Three numbered fixes on safety-critical concurrency paths,
  each with the failure mode named (POSIX `rename(2)` atomicity,
  persist-then-delete ordering to prevent orphaned m4a + dangling
  webm row, `@Sendable` closure capture hazard fixed via reference-
  type wrappers).
- **Feature introduction with schema migration** — `0442a2f4` (Split
  Dictations into History + Stats sub-tabs with daily streak
  heatmap). Multi-component feature with a v0.11 SQLite migration,
  schema decisions explained alongside UI rationale, prior decisions
  cross-referenced (mirrors #124's trade-off for surviving Clear
  History), 19 new repository tests characterized by scenario.
- **Short, well-articulated** — `f6edccc7` (Warn that Best-available
  YouTube audio breaks in-app playback). Three sentences. No
  template. Gives a future reader full understanding of why the
  Settings copy was edited.

## Inline examples

### Comprehensive (feature)

```text
Add dictation overlay with waveform visualization

## What Changed
- Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift: New
  compact dark pill overlay with recording state indicator, waveform,
  and cancel button.
- Sources/MacParakeet/Views/Dictation/WaveformView.swift: Real-time
  audio level waveform using AVAudioEngine tap data.
- Sources/MacParakeetCore/Services/Dictation/DictationService.swift:
  Added `audioLevelPublisher` for UI.
- Tests/MacParakeetTests/DictationServiceTests.swift: Test audio
  level callback registration.

## Root Intent
Users need visual feedback when dictating — they need to know the app
is recording, see their voice levels, and have a clear way to cancel.
The pill overlay appears over all apps without stealing focus.

## Seed Prompt
Give MacParakeet dictation visual feedback: a compact dark pill
overlay, visible over all apps, that shows recording state and live
voice levels and offers cancel (button + Escape). Hard constraints:
must never steal focus from the active app (non-activating panel),
and the audio-level source must come from the existing capture path
rather than a second tap. Expose whatever publisher the view needs
from `DictationService`.

## Author's Notes
The 100ms level-smoothing constant is eyeballed, not measured — if
the waveform ever feels laggy, start there. I considered driving the
waveform from the STT engine's VAD signal instead of raw levels and
rejected it: it would couple UI cadence to engine choice.

## ADRs Applied
- ADR-001 + ADR-007: Parakeet TDT model with FluidAudio CoreML runtime

## Files Changed
- Sources/MacParakeet/Views/Dictation/DictationOverlayView.swift
  (+145) — borderless NSPanel + state-driven layout.
- Sources/MacParakeet/Views/Dictation/WaveformView.swift (+62) —
  real-time waveform rendering from audio-level data.
- Sources/MacParakeetCore/Services/Dictation/DictationService.swift
  (+28, ~12) — new `audioLevelPublisher` exposed to the overlay.
- Tests/MacParakeetTests/DictationServiceTests.swift (+34) —
  audio-level callback registration tests.
```

### Targeted bug fix

```text
Fix clipboard not restoring after dictation paste

## What Changed
Save clipboard contents in `DictationService.paste(_:)` before writing
the transcription, restore after the CGEvent Cmd+V completes (100ms
delay to let the receiving app consume the paste).

## Root Intent
Users reported that dictation overwrites their clipboard. The paste
should be transparent: save → paste transcription → restore the
original.

## Files Changed
- Sources/MacParakeetCore/Services/Dictation/DictationService.swift
  (~18)
```

### Short

```text
Warn that Best-available YouTube audio breaks in-app playback

AVPlayer on macOS can't decode WebM/Opus, which is what yt-dlp picks
under "Best available". The old Settings detail glossed this as "may
save WebM/Opus files" without saying playback dies. Make the trade-off
explicit so users know to fall back to Show Video.
```

## Subsystem READMEs

Some folders under `Sources/MacParakeetCore/` carry a `README.md` that
captures non-obvious rules (threading, ordering, retention) that
aren't visible from grep. As of this writing: `Audio/`, `STT/`,
`TextProcessing/`, `Database/`, `Licensing/`.

**If your commit adds, removes, or renames files in one of those
folders, update the folder's `README.md` in the same commit.** CI
runs `scripts/check-readme-references.sh` and fails the build when
a backticked `.swift` reference no longer resolves — so drift is
caught at PR time, but only if the PR itself touches code.

The READMEs are not exhaustive listings; they call out the files
worth orienting around. If you add a new file that introduces a
non-obvious rule (a threading invariant, a "do not delete this," an
ordering constraint), document the rule in the README. If you add a
file whose purpose is self-evident from its name and contents, no
README change needed.

## Why this matters

1. **Git history becomes the project's long-term memory** — rich
   context lives in version control rather than disappearing into
   chat transcripts and PR comments that nobody re-reads.
2. **Reconstructable changes** — the seed prompt preserves the
   intent and constraints from which the work could be regenerated,
   which outlives any particular file layout.
3. **Onboarding via archaeology** — new devs and agents understand
   decisions by reading commits, not by scheduling explanations.
4. **Auditable reasoning** — the "why" is preserved alongside the
   "what," so future bug investigations can recover the original
   trade-offs.

The spirit test holds the whole system together: if a future reader
can't reconstruct your reasoning from the commit, the commit didn't
do its job — regardless of how many template sections it filled.
