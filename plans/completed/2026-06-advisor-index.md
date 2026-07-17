# Advisor Audit Index — 2026-06-12 (`f8e28be91` run)

> Status: **SUPERSEDED / HISTORICAL** — this is the prior advisor run at
> `f8e28be91`. It reached `main` via doc-bundling commits (#487/#509) and is
> superseded by
> [`../active/2026-06-12-advisor-index.md`](../active/2026-06-12-advisor-index.md)
> (2026-06-13 reconcile). Kept as the record of that run. Archived 2026-06-13.

Advisor audit at commit `f8e28be91` (branch `chore/improve-audit-fixes`),
deliberately complementing `docs/audits/2026-06-09-codebase-audit.md` by
covering only what it did not: distribution/CI scripts, Sparkle integration,
onboarding, hotkey internals, the SwiftUI view layer, diarization, and this
branch's own fix commits. Baseline `swift test` at `f8e28be91`: 3,576 tests,
0 failures.

**Headline result: the corners are clean.** Entitlements, Sparkle config,
hotkey event-tap re-enable handling, onboarding TOCTOU guards, and the
branch's quiesce/refcount scheduler work all held up under skeptical review.
Only one finding carries real stakes; the rest were deliberately pruned to
the opportunistic list below.

## Plans

| Plan | Title | Priority | Effort | Status |
|------|-------|----------|--------|--------|
| [2026-06-onboarding-stall-watchdog-test.md](2026-06-onboarding-stall-watchdog-test.md) | Make the warm-up stall watchdog testable and test it | P1 | S–M | DONE — #518 |

Status values: TODO | IN PROGRESS | DONE | BLOCKED (one-line reason) |
REJECTED (one-line rationale).

## Minor, opportunistic (no plan — pick up when touching the area)

1. **Chunker `reset()` tripwire asymmetry** *(introduced on this branch —
   ideally fold into its next review pass)*:
   `SpeechBoundaryMeetingLiveAudioChunker.swift` — `addSamples()`/`flush()`
   assert `!ingestInFlight` then set `ingestInFlight = true` +
   `defer { ingestInFlight = false }`; `reset()` (~line 105) has the assert
   but not the flag, so a future `await` inside `reset()` would escape the
   AUDIT-079 tripwire. Fix: add the same two lines after the assert.
2. **Per-render allocations in History/Stats views**:
   `DictationHistoryView.swift:546-551` (`formatTime` allocates a
   `DateFormatter` per row), `DictationStatsView.swift:556-571` +
   `:628-635` (formatters per body eval) — hoist to `private static let`
   following the `accessibilityDateFormatter` exemplar at
   `DictationStatsView.swift:459`. Plus `SonicMandalaView.swift:176`:
   `Array(text.utf8)` materializes the whole transcript to read 24 bytes —
   `Array(text.utf8.prefix(sampleCount))` is output-identical.
3. **Release/CI script hardening**: (a) `build_app_bundle.sh:358` —
   `TMP_NODE` has no `trap 'rm -rf "$TMP_NODE"' EXIT` (its sibling
   `download_ytdlp()` has the pattern); (b) Node tarballs verify against
   same-origin SHASUMS — since `NODE_VERSION` is pinned (24.13.1), the two
   darwin SHA-256s could be vendored in-script; (c)
   `scripts/ci/check-telemetry-allowlist.sh:78` — the awk range stops at
   the first `])`; if a TS refactor removes that terminator the parse
   silently runs to EOF (over-inclusive). Guard: track a `closed` flag in
   awk and `exit 9` from END when unset (recipe verified to work).

## Findings considered and rejected (do not re-audit)

- **Diarization rounding breaks segment ordering** — refuted: rounding is
  monotone non-decreasing so sorted input stays sorted, and
  `SpeakerMerger.swift:17-19` defensively re-sorts both inputs anyway.
  Zero-length rounded segments are filtered by the `overlap > 0` check.
- **SpeakerMerger missing input validation** — malformed (inverted-bounds)
  segments already degrade correctly to a nil speaker; not worth code.
- **FluidAudio `.upToNextMinor` vs `exact` pin** — deliberate policy;
  blocks breaking minors already.
- **Appcast `?v=` cache-bust is a manual step** — already encoded in
  docs/distribution.md, release tooling, and team memory; marginal.
- **FFmpeg download TOFU** — uses a `latest` redirect, so an in-repo pinned
  checksum would break on every upstream release; accepted as the same
  deferred class as AUDIT-077 (yt-dlp).
- **SettingsView/LLMSettingsView/TranscriptResultView god-files**
  (3,278/1,590/3,077 lines vs 202 median) — real debt, but SwiftUI views
  have no tests by policy, so a standalone split has no automated safety
  net. Fold the SettingsView split into
  `plans/active/2026-04-settings-ia-overhaul.md` instead.
- **Stray `test_proto`/`test_proto2` Mach-O binaries in repo root** —
  untracked local clutter; delete by hand.
