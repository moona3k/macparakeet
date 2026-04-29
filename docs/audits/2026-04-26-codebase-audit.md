# Codebase Audit — 2026-04-26

> **Status:** IMPLEMENTED. Two-pass independent audit of the `macparakeet`
> codebase at the time of branch `feat/cli-llm-json-output` (HEAD `702ce37e`).
> 70 findings catalogued. Fixes landed across #149, #154, and follow-up
> hygiene PRs. Refuted findings retained with rationale. Deferred items list
> explicit reasons and revisit triggers.

| | Count |
|---|---:|
| Total findings (P0 / P1 / P2) | 70 |
| FIXED | 30 |
| REFUTED on verification | 5 |
| DEFERRED with reason | 35 |

---

## Methodology

### Pass 1 — broad scan

Six parallel read-only Explore agents, each scoped tight to avoid duplication.
Combined coverage: ~249 source files, ~128 test files.

| Scope | Coverage |
|---|---|
| Concurrency + memory safety | actor isolation, Task lifetime, retain cycles, MainActor hops, continuations |
| Audio + STT runtime | AVAudioEngine, Core Audio Taps, STTRuntime/Scheduler, AEC, crash recovery, external processes |
| Database + persistence | GRDB migrations, repos, transactions, schema/spec drift, lifetime-stats invariant |
| CLI public surface | semver, `--json` envelope, exit codes, stderr/stdout, contract docs |
| Code quality + design | dead code, abstraction quality, DesignSystem compliance, MainActor consistency |
| Security, privacy, telemetry | API keys, local-first invariants, telemetry payload leakage, external binary safety |

### Pass 2 — independent verification

- **Codex** — anchored verification of every Pass-1 P0/P1 finding.
- **Gemini** — independent un-anchored full-repo scan; cross-referenced.
- **4 fresh Explore agents** on gap areas: LLM provider adapters, hotkey state
  machine, Sparkle update path, test quality.

Pass 2 corrected several Pass-1 findings (cross-cutting theme C5, AUDIT-014,
AUDIT-001/004 narrowed) and added AUDIT-031 through AUDIT-070.

### Fix sprint

Two sprints landed in two PRs. PR #149 (Sprint 1) shipped 13 fixes alongside
the CLI `--json` envelope. PR #154 (Sprint 2 + carryovers) shipped the
remaining 13 commits. Each commit references the AUDIT-NNN finding it
addresses; commit messages document the fix and any review-pass refinement.
Follow-up hygiene PRs can move deferred P2 items to fixed without changing the
original two-pass audit scope.

---

## Findings — by area

Status legend: **FIXED** (commit referenced) · **REFUTED** (with reason) ·
**DEFERRED** (with revisit trigger).

### Audio + STT runtime

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-001 | STTScheduler continuation lifecycle | DEFERRED | Pass 2 narrowed: `STTScheduler` is `actor`; sub-claims (a) and (b) prevented by isolation. Only `cancelAndDrainRunningJobs` race remains, severity P2. Watch production telemetry. |
| AUDIT-003 | `@unchecked Sendable` on Core Audio paths | FIXED | Follow-up PR removes the blanket `@unchecked Sendable` from `MeetingAudioStorageWriter`. The writer is non-Sendable and remains serialized by `MeetingRecordingService`; only the AVFoundation finish callback boundary keeps a narrow unchecked wrapper. |
| AUDIT-005 | FFmpeg conversion + mix temp files leak on timeout / cancel | FIXED | `28ceba2c` (#149). SIGTERM-zombie sub-claim refuted (FFmpeg cleans on SIGTERM); `outputURL` leak on Swift-timeout path was the real concern. |
| AUDIT-006 | `SystemAudioTap` watchdog only logs on silent buffer timeout | FIXED | `a13717cb` + review polish in `43e97090`. Adds 2s first-buffer budget + 1s repeating heartbeat (5s mid-session stall threshold) wired through the existing `MeetingAudioCaptureEvent.error` channel. |
| AUDIT-014 | `ObjCExceptionBridge` "wired nowhere" | REFUTED | Pass-1 grep was too narrow. `catchingObjCException` is actually used 11 times across `AudioRecorder.swift` + `MicrophoneCapture.swift`. |
| AUDIT-025 | DictationService temp audio leak on paste failure | DEFERRED | P2 polish; rare path. |
| AUDIT-029 | Lock-file recovery clock-skew | FIXED | `25260010`. Duration fallback clamped non-negative — guards against NTP correction or manual time change putting `lock.startedAt` in the future. |
| AUDIT-031 | `VideoStreamService` DispatchQueue continuation leak | FIXED | `8ed94de8`. Drains pipes synchronously after process exit instead of concurrently on a global queue thread that TaskGroup cancellation couldn't interrupt. SIGKILL fallback after 2s SIGTERM grace. |
| AUDIT-032 | `$TMPDIR/macparakeet/` cleanup ownership | DEFERRED | P2 polish. |

### LLM provider layer

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-036 | Stream EOF detection (silent truncation) | FIXED | `16d756f0` (#154). Strict providers (OpenAI, OpenRouter, Anthropic) now throw `streamingError` on EOF without their contractual sentinel (`[DONE]` / `message_stop`). Lenient providers (Gemini, OpenAI-Compatible aggregators, LM Studio, Ollama, localCLI) keep prior behavior. Detail string distinguishes "no content yielded" (auth/backend issue) from "content then EOF" (mid-response truncation). |
| AUDIT-037 | `PromptTemplateRenderer` silently drops unknown vars / unterminated `{{` | FIXED | `eed7ad43` (#154). Logs to OSLog when present. |
| AUDIT-038 | Anthropic API version "2 years stale" | REFUTED | Anthropic's [public version history](https://docs.anthropic.com/en/api/versioning) lists `2023-06-01` as the current latest pin (only `2023-01-01` and `2023-06-01` exist). The original Pass-1 framing was incorrect. The constant was factored to a single `LLMClient.anthropicAPIVersion` for chat + listModels parity, but the value remains `2023-06-01` because that IS the current version. |
| AUDIT-039 | Anthropic `listModels` missing version header | REFUTED | Header is set at `LLMClient.swift:567` (verified read). Gemini #8 was wrong on this. |
| AUDIT-040 | Provider error messages echo API-key fragments | FIXED | `1699c2aa` (#154). New `LLMClient.scrubAPIKeyArtifacts(from:)` runs every provider error message through it before propagating into Swift `LLMError` values, telemetry, logs, UI. Patterns: `sk-…`, `Bearer …`, `x-api-key: …`, `key=…`, `api[_-]?key=…`. Idempotent + conservative (false negatives over false positives). |
| AUDIT-041 | URLSession not cancelled on stream Task cancel | REFUTED | `URLSession.AsyncBytes` on macOS 12+ propagates Task cancellation to the underlying `URLSessionDataTask` per Apple's contract. Existing `task.cancel()` in `continuation.onTermination` is sufficient. |
| AUDIT-042 | 30s/120s timeouts + no exponential backoff | DEFERRED | P1; needs telemetry on actual long-meeting summary durations before tuning. |
| AUDIT-043 | Anthropic `thinking` blocks silently dropped (Claude 3.7+) | DEFERRED | Only triggers if MacParakeet uses Claude 3.7+ models. |
| AUDIT-044 | `try?` on JSONDecoder swallows decode errors | DEFERRED | P2; current `LLMError.invalidResponse` is informative enough. |
| AUDIT-045 | Silent transcript truncation when over context budget | DEFERRED | P2; UI signal + telemetry event would be valuable but not urgent. |

### CLI

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-007 | `--json` failure-envelope contract asymmetry | FIXED | `30a6f0a7` (#154). Locked: after argument parsing succeeds, `--json` success and failure emit JSON to stdout. New `CLIErrorEnvelope { ok, error, errorType }` with stable `errorType` taxonomy. Parse-time ArgumentParser failures remain plain stderr with exit code 2. Documented in `Sources/CLI/CHANGELOG.md` + `integrations/README.md`. |
| AUDIT-008 | Zero `--json` error-path tests | FIXED | `30a6f0a7` (#154). Tests cover envelope shape, taxonomy mapping for every `LLMError` case, and CLI-error mapping. |
| AUDIT-009 | Exit codes under-specified | FIXED | `359df673` (#149). Enumerated table in `Sources/CLI/CHANGELOG.md` and `integrations/README.md`. |
| AUDIT-020 | `--api-key` shell-history exposure | FIXED | `359df673` (#149). Help text now recommends `"$VAR"` shell expansion. |
| AUDIT-023 | yt-dlp leading-dash URL injection | REFUTED | Args at `YouTubeDownloader.swift:198–206` already include POSIX `--` separator before url. |
| AUDIT-030 | `--json` vs `--format json` split untested | DEFERRED | P2. |
| AUDIT-034 | `LLMTestCommand` only catches `LLMError` | FIXED | `30a6f0a7` (#154). Wrapped in shared `emitJSONOrRethrow`; catches every `Error` type. |

### Database + persistence

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-002 (narrowed) | `MeetingNotesViewModel` debounce loses 250ms idle window | FIXED | `31458869` (#154). `scheduleDebounce` reads latest text post-sleep instead of pre-sleep snapshot; symmetric flush on `cancelRecording` matches existing flush on `stopRecordingAndTranscribe`. (Stale-callback sub-claim refuted — `bindPersist` already cancels in-flight task.) |
| AUDIT-012 | Migration silently drops malformed `chatMessages` rows | FIXED | `f3851884` (#149). Logs skipped row IDs via OSLog; emits rolled-up telemetry. |
| AUDIT-018 | Raw SQL inconsistency vs GRDB DSL | DEFERRED | P2 consistency polish. |
| AUDIT-021 | `Transcription.speakers` decode failure silent | FIXED | `25260010` (#154). Logs to OSLog when key is present and value isn't explicit JSON `null`. |
| AUDIT-026 | Lifetime stats save+increment opaque | DEFERRED | P2; correctness already verified, only naming polish. |
| AUDIT-027 | `v0.5-private-dictation` migration column pre-check | FIXED | `25260010` (#154). Mirrors the v0.7.1 pattern; idempotent re-run for hand-restored DBs. |
| AUDIT-028 | FK cascade silently deletes user notes | DEFERRED | By design; UX documentation gap only. |
| AUDIT-035 | Malformed UUIDs nulled by bulk UPDATE | FIXED | `f3851884` (#149). Only-null successfully-migrated rows. |

### Onboarding + Sparkle

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-010 | Onboarding lacks timeout on `EngineState.working` | FIXED | `3bf399f5` (#154). 180s no-progress watchdog transitions to `.failed` with retry hint instead of stranding users. Memory: v0.4.22 stranded ~23 users for ~24h on this exact path. |
| AUDIT-033 | Re-entrance window on `startEngineWarmUp` | DEFERRED | Currently safe under MainActor non-re-entrance; flagged as fragile. |
| AUDIT-053 | Sparkle update guard | FIXED | `b3dbfb00` (#154). Refuses checks on dev/`0.0.0`/`*pdx*` builds and during active meeting recordings. Also returns `false` from `updaterShouldRelaunchApplication` so an already-downloaded update can't relaunch the app mid-recording. 6 unit tests. |
| AUDIT-054 | Update-failure UI invisible | DEFERRED | P2 UI polish. |
| AUDIT-055 | Appcast cache-busting manual | DEFERRED | P1 dist-script hardening; needs validation script. |
| AUDIT-056 | Notarytool retry/SIGBUS | DEFERRED | P2; already documented in MEMORY. |
| AUDIT-057 | No update-related telemetry | DEFERRED | Needs website allowlist follow-up. |
| AUDIT-058 | Hardcoded `SIGN_IDENTITY` in dist script | DEFERRED | Needs maintainer input on env-var vs gitignored `.env`. |

### Telemetry + security

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-011 | Telemetry sanitization at call sites, not boundary | FIXED | `b6cb2344` + `cdc7970c` (#149). `errorOccurred` now runs `errorDetail()` regardless of caller. |
| AUDIT-022 | `wordCount` / `processingSeconds` unbucketed | DEFERRED | P2 fingerprintability concern. |

### Hotkey + global input

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-046 | Tap re-enable doesn't reset edge flags | FIXED | Follow-up PR resets stale gesture state after tap re-enable, cancels pending timers, resyncs modifier edges, and preserves physical key-held state so held repeats are not treated as new triggers. |
| AUDIT-047 | Tap callback races with MainActor closures | DEFERRED | Same regression-risk class. |
| AUDIT-048 | Mach time conversion assumes 1:1 timebase | DEFERRED | P2; precision-only. |
| AUDIT-049 | `bareTap` invalidation doesn't cancel debounce timer | FIXED | Regression tests lock that regular-key bare-tap interruption cancels startup/hold windows; tap-disabled recovery also resets the gesture controller so stale timer callbacks cannot start or stop recording. |
| AUDIT-050 | Paste pipeline doesn't verify frontmost app | DEFERRED | Focus race window 0–15ms; fix needs careful UX consideration. |
| AUDIT-051 | `start()` doesn't log `AXIsProcessTrusted` on tap failure | FIXED | `2a0e557b` (#154). Observability-only; one-line OSLog warning on the existing failure branch. Distinguishes Accessibility-permission denial from generic system error in log triage. |
| AUDIT-052 | `GlobalShortcutManager` swallows unrelated shortcuts | DEFERRED | P2. |

### Diarization + view layer

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-015 | `nonisolated(unsafe)` EKEventStore from non-actor | DEFERRED | P2. |
| AUDIT-016 | `TranscriptResultView` 2,475 lines | DEFERRED | Decomposition refactor; separate sprint. |
| AUDIT-017 | `SettingsViewModel` 1,108 lines | DEFERRED | Decomposition refactor; separate sprint. |
| AUDIT-019 | Hardcoded paddings/widths bypass DesignSystem | DEFERRED | P2 token sweep. |
| AUDIT-024 | Test/source counts drift | FIXED | `359df673` (#149). |
| AUDIT-064 | Speaker IDs assigned in iteration order, not chronological | FIXED | `f0de13a4` (#154). Sorts segments by `startMs` before stable-ID assignment. |
| AUDIT-065 | `modelsReady` never re-validated | DEFERRED | P2; rare path. |
| AUDIT-066 | Single-endpoint preflight (HF only) | DEFERRED | Pragmatic fix needs UI message changes too. |
| AUDIT-067 | Accessibility (Dynamic Type, VoiceOver) | DEFERRED | Multi-day separate sprint. |
| AUDIT-068 | i18n unstarted | DEFERRED | Multi-day separate sprint. |
| AUDIT-069 | CI: no SPM cache, no per-step timeouts | FIXED | Follow-up CI hygiene PR adds SwiftPM dependency cache, per-step `timeout-minutes`, and uploaded build/test logs. |
| AUDIT-070 | Node SHASUMS file not pinned | DEFERRED | P2. |

### Test quality

| ID | Title | Status | Note |
|---|---|---|---|
| AUDIT-059 | 92 tests use hardcoded `Task.sleep` | DEFERRED | P1 suite reliability; separate test-refactor sprint. |
| AUDIT-060 | `DiscoverViewModel`, `MeetingRecordingPillViewModel` zero tests | DEFERRED | P1; separate sprint. |
| AUDIT-061 | 53 tests reference `/tmp/...` paths | DEFERRED | P2. |
| AUDIT-062 | `TelemetryServiceTests` wall-clock polling | DEFERRED | P2. |
| AUDIT-063 | `TelemetryMockURLProtocol` static-state leak | DEFERRED | P2. |

---

## Cross-cutting themes

1. **Continuation + cancellation hygiene** — Pass-1 flagged a cluster
   (AUDIT-001 / 004 / 005 / 031). Pass 2 narrowed it: STTScheduler is actor-
   isolated; AUDIT-004 uses TaskGroup correctly; AUDIT-005 outputURL leak was
   real and fixed; AUDIT-031 (VideoStreamService inner DispatchQueue) was the
   only true class-of-bug instance and is fixed. URLSession cancellation
   propagation works correctly per Apple's contract (AUDIT-041 refuted).

2. **Cleanup-on-cancel paths** — Multiple FFmpeg/yt-dlp output files orphaned
   on timeout/cancel paths. `process.terminate()` (SIGTERM) without SIGKILL
   fallback risked zombies. AUDIT-005 + AUDIT-031 fix the immediate cases;
   pattern documented in commit messages for future reuse.

3. **Sanitization at the event boundary, not the call site** — Telemetry
   `errorOccurred` previously trusted callers to run
   `TelemetryErrorClassifier.errorDetail()`. AUDIT-011 moves it into the
   constructor. LLM provider error messages similarly now run through
   `scrubAPIKeyArtifacts` at `mapError()` rather than being scrubbed
   ad-hoc per call site.

4. **Strict-vs-lenient SSE protocol contracts** — OpenAI / OpenRouter /
   Anthropic contractually emit a stream terminator (`[DONE]` /
   `message_stop`). Gemini, OpenAI-Compatible aggregators, LM Studio,
   Ollama, localCLI vary or omit. AUDIT-036 enforces the sentinel for
   strict providers only.

5. **Threading-boundary fragility at C-callback / Swift-Concurrency seams** —
   CGEvent tap → MainActor, URLSession callbacks → actor state, Core Audio IO
   block → @unchecked Sendable. Recurring pattern; partial mitigation via
   AUDIT-006 watchdog and AUDIT-031 pipe-drain ordering. Hotkey tap recovery
   now resets edge state and pending timers (AUDIT-046 / 049); the callback
   actor-boundary concern remains deferred (AUDIT-047).

6. **External fragility with no fallback** — Single-endpoint network
   preflight (AUDIT-066), single LLM provider with tight timeouts and no
   retry/backoff (AUDIT-042), single appcast URL with manual cache-busting
   (AUDIT-055). Class concern; fixes deferred individually.

7. **Accessibility + i18n entirely absent** — AUDIT-067 / 068. Not
   post-launch polish; baseline macOS expectations. Multi-day separate
   sprint.

---

## Strengths preserved (worth not regressing)

- **19/19 ViewModels are `@MainActor @Observable public final class`** — no
  ObservableObject debt.
- **LLM API keys** — `LLMConfigStore` excludes `apiKey` from Codable via
  `CodingKeys`, stores per-provider in macOS Keychain.
- **`CrashReporter` is signal-safe** — pre-allocated buffers, async-signal-
  safe POSIX I/O.
- **`TelemetryErrorClassifier.errorDetail()`** — strips `file://` URLs and
  absolute paths via regex (now the default path, AUDIT-011).
- **Public CLI contract** — `Sources/CLI/CHANGELOG.md`, `AGENTS.md`,
  `integrations/README.md` consistent. Stable JSON schemas (`LLMResult`,
  `LLMUsage`, `LLMTestConnectionResult`); no semver breaks 1.0 → 1.2.
- **Lifetime stats atomicity** — both writes inside a single `dbQueue.write`
  block (`DictationRepository.swift:107–145`).
- **`YouTubeDownloader.swift:113–129`** — correct continuation pattern
  (`OSAllocatedUnfairLock` + flag); template for any future `Process` wrapper.
- **`FnKeyStateMachine` `bareTap` filtering** — well-designed.
- **Modular Core / ViewModels / UI separation** — protocol-driven services.
- **Sparkle `startingUpdater: false` in DEBUG** — correctly prevents
  auto-update during dev (in addition to AUDIT-053's runtime guards).
- **FFmpeg + Node.js SHA256 verification in build scripts** — binary
  checksum verified (Node SHASUMS file itself isn't pinned per AUDIT-070,
  separate concern).

---

## Recommended follow-up sequence

The deferred items, in priority order:

1. **Hotkey/paste follow-ups** (AUDIT-047 / 050; AUDIT-048 / 052 lower-risk
   P2). Remaining items need careful runtime verification around active
   dictation and paste targeting.
2. **Notes durability — scene-phase persistence + lock-file rotation flush**
   (AUDIT-002 follow-up). The narrowed crash-window concern remains.
3. **Test-quality cleanup** (AUDIT-059 / 060 / 061 / 062 / 063). 92 hardcoded
   sleeps, missing VM tests, hardcoded `/tmp` paths, wall-clock polling.
4. **Dist-script hardening** (AUDIT-055 / 056 / 058 / 070). Appcast cache-
   bust validation, notarytool SIGBUS retry, SIGN_IDENTITY env-var,
   SHASUMS pinning.
5. **View / VM decomposition** (AUDIT-016 / 017). `TranscriptResultView`
   2,475 lines and `SettingsViewModel` 1,108 lines — refactor sprint.
6. **Accessibility + i18n** (AUDIT-067 / 068). Multi-day work.
7. **Telemetry bucketing** (AUDIT-022). Reduces fingerprintability on small
   cohorts.

---

## Changelog

- **2026-04-26 Pass 1** — 30 findings across 6 scopes. Branch
  `feat/cli-llm-json-output` @ `702ce37e`.
- **2026-04-26 Pass 2** — 40 additional findings (AUDIT-031–070) across LLM,
  hotkey, Sparkle, test-quality, diarization, onboarding, CI, accessibility,
  i18n. Cross-cutting themes corrected; AUDIT-014 dropped (refuted by
  re-grep).
- **2026-04-26 Sprint 1** — 13 fixes shipped via PR #149.
- **2026-04-26 Sprint 2** — 13 fixes shipped via PR #154.
- **2026-04-26 AUDIT-069 follow-up** — CI hygiene: SwiftPM cache,
  per-step timeouts, and uploaded CI logs.
- **2026-04-26 AUDIT-003 follow-up** — `MeetingAudioStorageWriter` no longer
  declares blanket `@unchecked Sendable`; finalization uses a narrow
  AVFoundation callback bridge while writer access remains actor-owned.
- **2026-04-26 AUDIT-046/AUDIT-049 follow-up** — hotkey tap-disabled recovery
  now resets stale gesture state, cancels pending startup/hold timers, and
  resyncs edge detection without changing normal dictation gestures.
