# Advisor Audit Index — 2026-06-12 (main baseline)

Advisor (`/improve`) run at `main` HEAD `3f9361005`. This run deliberately
**complements** the two recent audits rather than repeating them:

- `docs/audits/2026-06-09-codebase-audit.md` (two-pass, AUDIT-071+) covered the
  post-April churn: audio/meeting, STT engines, URL transcription,
  Transforms/LLM, DB/concurrency, CLI/telemetry. Its P1s (AUDIT-071/072/073)
  and hygiene one-liners (074/075/076/080) are all **FIXED** on main.
- A 2026-06-12 advisor run at `f8e28be91` covered the seams the Jun 9 audit
  skipped (distribution/CI, Sparkle, onboarding, hotkeys, SwiftUI views,
  diarization). **That run's branch never merged directly**, but its plan docs
  were later swept onto `main` in their original `f8e28be91` form via unrelated
  doc-bundling commits (#487/#509). This run **supersedes** them with
  re-validated versions — see "Reconciliation" below.

So this run scoped to **what neither audit could have covered**: the ~2,500
lines that landed on `main` *after* them — Nemotron live dictation (#496),
meeting echo-suppression hardening (#480/#485), shared-mic self-heal (#507),
plus smaller fresh items — and re-verified the still-open deferred items.

**Headline: the June churn is clean.** Four read-only agents plus direct
line-by-line vetting of the central STT scheduler found **no live correctness
bug** in the new code. The institutionalized patterns (per-call generation
guards, synchronous lease reservation, actor isolation) are correctly applied
(e.g. #496's begin-vs-shutdown race is guarded *and* tested at
`STTScheduler.swift:198`). What remains is one defensive-consistency item,
test-coverage gaps on dangerous paths, and known hygiene.

Baseline `swift test` was not re-run this session (read-only audit); the Jun 9
audit recorded green at `92c3dfdfb` and CI runs the full suite on every push.

## Plans

| Plan | Title | Priority | Effort | Status |
|------|-------|----------|--------|--------|
| [2026-06-12-telemetry-allowlist-ci-guard.md](2026-06-12-telemetry-allowlist-ci-guard.md) | Wire the cross-repo telemetry allowlist guard into CI | P2 | S | TODO |
| [2026-06-12-june-churn-regression-tests.md](2026-06-12-june-churn-regression-tests.md) | Regression tests for mic self-heal + Nemotron live dictation | P2 | M | TODO |
| [2026-06-onboarding-stall-watchdog-test.md](2026-06-onboarding-stall-watchdog-test.md) | Make the warm-up stall watchdog testable and test it | P1 | S–M | DONE (`test/onboarding-stall-watchdog`, 2026-06-14) |

Status values: TODO | IN PROGRESS | DONE | BLOCKED (one-line reason) |
REJECTED (one-line rationale). Plans are independent — no ordering
dependencies. Recommended order by leverage: onboarding watchdog (P1, real
trust-sensitive escape hatch) → telemetry guard (closes a recurring
data-loss class) → June-churn regression tests.

## Reconciliation (prior advisor run, now superseded)

The 2026-06-12 advisor run at `f8e28be91` produced two doc artifacts. Its branch
never merged directly, but the docs were later swept onto `main` in their
original `f8e28be91` form via unrelated doc-bundling commits (#487/#509). The
2026-06-13 reconcile supersedes them:

- **`2026-06-onboarding-stall-watchdog-test.md`** — a P1 test plan. The
  `f8e28be91` copy that reached main is **replaced** by the re-validated version
  in this run (re-checked against `3f9361005`; line numbers refreshed). It is
  the third plan in the table above.
- **The prior `2026-06-advisor-index.md`** — **superseded by this index** and
  moved to `plans/completed/` as the historical record of the `f8e28be91` run.
  Its AUDIT-074/075/076/080 *fixes* had already landed on main via separate
  commits; this index carries its still-relevant opportunistic items and
  rejections forward below.

## Minor, opportunistic (no plan — pick up when touching the area)

1. **STTScheduler quiesce/lease asymmetry** *(the Jun 9 PR#476 reviewer's
   deferred note — still real on main, confirmed)*:
   `STTScheduler.swift` — `clearModelCache()`/`shutdown()` call
   `quiesce(...)` (line ~566) which drains jobs but **not**
   `activeSpeechEngineSessionIDs`; and `beginSpeechEngineSession()` (line ~355)
   inserts a lease **without** the `acceptsNewJobs` guard that
   `setSpeechEngine`/`setParakeetModelVariant` (lines ~283-284, ~314-315) both
   have. **Vetted reachability: LOW today** — `clearModelCache` has no GUI
   caller (CLI single-shot only), `shutdown` is app-termination only where
   ADR-019 recovery covers an interrupted meeting; and `runtime` is an actor so
   calls serialize (it is **not** a use-after-free, despite a subagent's
   wording). Becomes reachable if the drafted "delete downloaded models" GUI
   ships ungated. Cheap defensive fix when next in this file: mirror the
   existing guard pattern (guard `acceptsNewJobs` in `beginSpeechEngineSession`;
   have `quiesce` refuse or drain while leases are active).
2. **Echo-suppression simultaneous-echo over-suppression (tuning, not a bug)**:
   `MeetingTranscriptNoiseFilter.swift:142-162` drops a mic run ≥5 words at
   ≥80% fuzzy-LCS overlap with concurrent system audio. A user who agrees-and-
   extends a system phrase can have the whole utterance dropped. Don't change
   the threshold speculatively — add telemetry on drop counts / validate
   against real meetings first. (An optional 80%-boundary unit test is noted in
   the June-churn regression plan, Step 3.)
3. **Already-tracked deferred hygiene (confirmed still OPEN on main)**:
   AUDIT-078 (`PodcastFeedParser.swift:~202` retains `<item>`s unbounded from a
   user-pasted feed — add a generous cap); AUDIT-079
   (`SpeechBoundaryMeetingLiveAudioChunker.swift:40-51` serialization contract
   is comment-only — add a `precondition`/in-flight tripwire so a future
   parallel-ingest refactor fails loudly); AUDIT-082 (`AudioRecorder.swift`
   downmix-to-mono `nil` returns don't log which path failed). All small.
4. **Stray `test_proto`/`test_proto2` Mach-O binaries in repo root** — untracked
   ~50KB executables, also flagged 2026-06-12 earlier. Not gitignored, so they
   show in `git status` and could be committed by accident. Delete by hand; or
   add `/test_proto*` to `.gitignore`.

## Findings considered and rejected (do not re-audit)

- **Nemotron live-dictation streaming has a correctness bug** — refuted: the
  begin-vs-shutdown TOCTOU is guarded (`STTScheduler.swift:198`) and tested
  (`testLiveDictationBeginRacingShutdownUnwindsRuntimeSession`); partial/final
  routing uses `bufferingNewest(1)` + a session-ID guard. Only *test-coverage*
  gaps remain (→ June-churn regression plan), not bugs.
- **Echo-suppression frame-carry / reference-delay / flush-reset bug** —
  refuted: arithmetic is sound and already covered by 6 dedicated tests
  (`MeetingEchoSuppressorTests.swift`), including batch-size invariance and
  reset-clears-carry.
- **Shared-mic self-heal restart race / observer leak / `defer` clobber** —
  refuted: four recovery gates, observer registered with `object:` and removed
  on teardown with weak `self`, generation guards intact, no `defer` flags.
  Only the missing buffer-delivery/tap-replay *assertion* remains (→ June-churn
  regression plan).
- **STTScheduler quiesce/lease gap is a P1 use-after-free** — downgraded: real
  asymmetry but actor-serialized (no UAF) and practically unreachable today
  (see opportunistic item 1). Kept as a cheap future-proofing item, not a plan.
- **Live telemetry data-loss (event missing from website allowlist)** —
  refuted by direct diff: 97 Swift `TelemetryEventName` cases, **0 missing**
  from the website `ALLOWED_EVENTS` (in sync at 2026-06-12). The value is the
  *CI guard* that keeps it that way (→ telemetry-allowlist plan), not a fix.
- **AI Formatter length cap / #492 phantom-fn hotkey / #478 timeout+retry** —
  all verified correct and (for #492) well-tested; no action.
- Carried from the Jun 9 audit and the prior advisor index (not re-litigated):
  diarization rounding (monotone + defensive re-sort), SpeakerMerger input
  validation (degrades to nil speaker), FluidAudio `.upToNextMinor` pin
  (deliberate policy), appcast `?v=` cache-bust (documented), FFmpeg/yt-dlp
  same-origin checksum TOFU (accepted deferred class), SettingsView/
  LLMSettingsView/TranscriptResultView god-files (no test safety net by
  policy — fold into `2026-04-settings-ia-overhaul.md`), AUDIT-081 stale
  website allowlist entries (retained on purpose).

## Coverage notes

- Audited this run: the post-`92c3dfdfb` functional churn on main (#496, #480/
  #485, #507, #474, #481/#483, #492, the AI Formatter Settings toggle), the
  STTScheduler lease/quiesce paths, and verification of the deferred AUDIT-078/
  079/082 + the two-repo telemetry allowlist.
- **Not** re-audited: everything the Jun 9 two-pass audit and the Jun 12
  advisor run already covered (their verdicts stand). Runtime-only behavior
  (real USB multichannel hardware, ScreenCaptureKit under stress) reviewed
  statically only.
