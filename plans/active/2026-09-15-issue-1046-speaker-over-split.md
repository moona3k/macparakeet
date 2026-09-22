# Issue 1046 — over-split speaker IDs and one-word bubbles

> Status: **PARTIAL** (2026-09-15)
> Issue: [#1046](https://github.com/moona3k/macparakeet/issues/1046)
> Related: ADR-010 follow-ups after [#972](https://github.com/moona3k/macparakeet/issues/972) / [#1023](https://github.com/moona3k/macparakeet/issues/1023); Auto 1:1 hole in [#944](https://github.com/moona3k/macparakeet/issues/944)
> Decision note: [`docs/audits/2026-09-15-issue-1046-speaker-detection.md`](../../docs/audits/2026-09-15-issue-1046-speaker-detection.md)
> Frozen A/B: [`benchmarks/diarization/2026-09-15-issue-1046-baseline.md`](../../benchmarks/diarization/2026-09-15-issue-1046-baseline.md)

## Verdict

Keep one GitHub issue. Ship the conservative word-assignment smoothing around the current FluidAudio 0.15.7 high-accuracy labels. The evaluated centroid consolidator changed zero rosters and is not shipping. Do not retune `clustering.threshold`, fit a merge tau to this gate, auto-adjust distance, or let voice profiles steer clustering.

We have enough labeled public audio to reject this centroid-only consolidation attempt and to prove that smoothing preserves speaker rosters. We do not yet have a safe signal that reduces Auto over-split rosters, and we do not have enough to claim overlap / two-talker perfection.

## Enough data?

**Yes, for this PR's claim** ("fewer isolated word-level artifacts without changing speaker rosters"):

- Seven VoxConverse v0.3 test WAVs on disk, SHA-256 frozen.
- Matching RTTM unique-speaker counts in git.
- Frozen Auto JSON from the 0.15.7 pin (unconstrained rosters identical to 0.15.6).
- Reproducible roster and word-assignment scorer: `benchmarks/diarization/scripts/score_speaker_count.py`, with pure-Python metric tests.

**No, and out of this PR:**

- DER / overlap scoring (never wired).
- Calendar 1:1 meetings (no recoverable labeled 1:1 audio locally).
- Max's private meetings as CI.
- Isolated one-word flips are rare on this slice (0–4 per file). Smoothing is gated by unit tests, not by roster.

CLI JSON has no centroids. Candidate quality **must** re-run diarization. Baseline JSON is the roster SoT, not a replay of consolidation.

## Product rules

1. Prefer no merge over merging two real people (`ledhe` stay 3, `gylzn` stay 2).
2. Automatic IDs remain evidence. User corrections stay the overlay. Voices stay gated and must not rewrite labels.
3. A failed experiment stays failed: do not ship inactive consolidation code or raise tau to make the frozen fixtures pass.

## Implementation (this PR)

### 1. `SpeakerMerger` smoothing

After max-overlap assignment, in the same public function so file and meeting paths both get it:

- A **singleton** word whose previous and next assigned IDs are equal and different from it inherits that ID.
- A **nil** word (or run of nils) whose previous and next assigned IDs are equal inherits that ID.
- Do not fill a gap between two different speakers (`SpeakerMergerTests.testWordInGap` stays nil).
- Do not touch a two-or-more-word run (that is clustering, not a one-word bubble).

### 2. Evaluated and deferred: centroid consolidation

The implementation used the existing VBx centroids, frozen tau 0.25, mutual-nearest long clusters, unique-neighbor short fragments, and an Exact-N floor. It changed zero of seven unconstrained rosters. On the primary one-speaker failure, `wibky`, both embeddings were present but the two centroids were distance 0.474 (227.5 s / 19.7 s of assigned speech). Raising tau enough to merge them would overlap Phase 0b's measured different-speaker range of 0.47–0.84.

The experiment is documented in the frozen A/B report. Its source and synthetic tests are intentionally not shipped: dead product code would add risk without user-visible benefit.

### 3. Not in this PR

- Changing `MeetingSpeakerPrior` (`max = n + 1`). Separate, needs meeting fixtures.
- Settings slider / live tau.
- New diarizer or re-embedding clean representative spans.
- DER harness.

## Tests

Focused only:

- `SpeakerMergerTests` — isolated flip; same-speaker nil-run fill; different-speaker gap unchanged; transcript edges unchanged; two-word speaker run unchanged.
- Frozen VoxConverse run — all seven speaker rosters remain identical; report isolated-flip and unlabeled-word changes separately.

## Recorded A/B

Same seven WAVs. Baseline = frozen unconstrained 0.15.7 JSON. Candidate = this branch CLI, unconstrained only.

```sh
export CANDIDATE_CLI=.build/debug/macparakeet-cli
export VOXCONVERSE_ROOT="$HOME/asr-bench/voxconverse"
export RESULTS_DIR="$HOME/asr-bench/issue-1046-ab/results"
benchmarks/diarization/scripts/run_issue_1046_unconstrained_ab.sh
```

The candidate roster was identical to baseline on 7/7 files. That is a pass for smoothing safety and a fail for the consolidation hypothesis. The full table and centroid diagnostics are recorded next to the freeze file. Do not raise tau to turn the failed hypothesis into a fitted result.

## Docs in the same PR

- Short ADR-010 amendment: smoothing exists; Auto roster over-split remains open; centroid consolidation was evaluated and deferred.
- Pointer from this plan and the 2026-09-15 audit.
