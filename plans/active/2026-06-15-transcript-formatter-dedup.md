# Plan: Extract a shared TranscriptFormatter to kill the duplicated AI-formatter path

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update the status row for this plan in `plans/README.md`.
>
> **Drift check (run first)**:
> `git diff --stat 16e3f865f..HEAD -- Sources/MacParakeetCore/Services/Dictation/DictationService.swift Sources/MacParakeetCore/Services/TranscriptionService.swift`
> If either changed since this plan was written, compare the "Current state"
> excerpts against the live code; on a mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (soft: land the DX baseline first so `scripts/dev/check.sh` exists)
- **Category**: tech-debt
- **Planned at**: commit `16e3f865f`, 2026-06-15

## Why this matters

The two highest-traffic capture modes — dictation and file/URL transcription —
carry a **duplicated AI-formatter path**: both declare a `private struct
FormatterOutcome` and a near-identical `private func formatTranscriptIfNeeded(…)`.
The duplication has **already drifted**: `DictationService`'s `FormatterOutcome`
has a `resolution: AIFormatterPromptResolution?` field (and a 3-arg `.skipped`),
while `TranscriptionService`'s has neither (2-arg `.skipped`). Every change to the
formatter contract (a new telemetry field, an error-classification tweak, a
prompt-normalization rule) must be made twice and silently diverges when it isn't.
Extracting one `TranscriptFormatter` collaborator that both services call collapses
the duplication, makes the formatter path unit-testable in isolation (today it can
only be reached through the full service), and removes a recurring maintenance tax.

## Current state

Two near-identical implementations:

**DictationService** (`Sources/MacParakeetCore/Services/Dictation/DictationService.swift`):
- `private struct FormatterOutcome: Sendable` (line 47): `text: String?`,
  `run: LLMRun?`, `resolution: AIFormatterPromptResolution?`; `static let skipped =
  FormatterOutcome(text: nil, run: nil, resolution: nil)`.
- `private func formatTranscriptIfNeeded(_:runSource:formatterContext:)` (lines 1277–1359):
  guards `shouldUseAIFormatter(), let llmService`; posts `.macParakeetAIFormatterDidStart`
  (userInfo source="dictation"), `defer` posts `.macParakeetAIFormatterDidFinish`;
  resolves prompt via `await aiFormatterPromptResolver.resolvePrompt(for: formatterContext)`;
  computes `defaultPromptUsed` via `AIFormatter.normalizedPromptTemplate(_) == AIFormatter.defaultPromptTemplate`;
  calls `llmService.formatTranscriptDetailed(transcript:promptTemplate:source: .dictation, defaultPromptUsed:)`;
  builds `LLMRun(formatterResult:source:feature: .formatterDictation)`; on error rethrows
  `CancellationError`, else logs `dictation_ai_formatter_failed`, posts `.macParakeetAIFormatterWarning`
  (source="dictation"), returns a failed `LLMRun.failedFormatterRun(...)`.
  **No input-length cap.** Carries `resolution` through on success.

**TranscriptionService** (`Sources/MacParakeetCore/Services/TranscriptionService.swift`):
- `private struct FormatterOutcome: Sendable` (line 50): `text: String?`, `run: LLMRun?`;
  `static let skipped = FormatterOutcome(text: nil, run: nil)`.
- `private func formatTranscriptIfNeeded(_:runSource:)` (lines 1638–1700):
  same guard; **adds an input cap** `guard text.count <= AIFormatter.maxTranscriptionInputChars`
  (logs `transcription_ai_formatter_skipped`); prompt via `aiFormatterPromptTemplate()`
  (no resolver, no profiles); same `defaultPromptUsed`; calls `formatTranscriptDetailed(… source: .transcription …)`;
  builds `LLMRun(… feature: .formatterTranscription)`; on error rethrows `CancellationError`,
  else logs `transcription_ai_formatter_failed`, posts `.macParakeetAIFormatterWarning`
  (source="transcription"), returns a failed run. **No DidStart/DidFinish notifications.
  No resolution.**

Shared dependency types (all in `MacParakeetCore`):
- `llmService: LLMServiceProtocol?` (Dictation :113, Transcription :221).
- `shouldUseAIFormatter: @Sendable () -> Bool` (Dictation :115, Transcription :223).
- `formatTranscriptDetailed(transcript:promptTemplate:source: TelemetryFormatterSource, defaultPromptUsed:) -> LLMFormatterResult` on `LLMServiceProtocol` (`Services/LLM/LLMService.swift:30`).
- `AIFormatter.maxTranscriptionInputChars` (= 20_000), `.defaultPromptTemplate`, `.normalizedPromptTemplate(_:)` (`TextProcessing/AIFormatter.swift`).
- `LLMRun`, `LLMRun.failedFormatterRun(...)`, `LLMRunFeature.{formatterDictation,formatterTranscription}` (`Models/LLMRun.swift`).
- `AIFormatterPromptResolution` (`Models/AIFormatterProfileMatcher.swift`).
- Notification names: `.macParakeetAIFormatterDidStart`, `.macParakeetAIFormatterDidFinish`,
  `.macParakeetAIFormatterWarning` (`AppNotifications.swift`).
- `Self.errorType(for:)` in each service wraps `TelemetryErrorClassifier.classify(error)`.

The only behavioral differences between the two methods: (1) input cap
(transcription yes / dictation no), (2) prompt source (resolver+context vs flat
template), (3) lifecycle notifications (dictation yes / transcription no), (4) the
`source`/`feature`/warning-source values, (5) whether `resolution` is carried.
Everything else — the guard, `defaultPromptUsed`, the call, success trim, the
`CancellationError` rethrow, the warning log + notification, the failed-run build —
is identical.

Existing mock + tests: `Tests/MacParakeetTests/ViewModels/ViewModelMocks.swift`
has an `LLMServiceProtocol` mock; `Tests/MacParakeetTests/Services/LLM/LLMServiceTests.swift`
and `Tests/MacParakeetTests/Services/TranscriptionServiceTests.swift` are the
regression nets and the structural pattern for the new test.

## Commands you will need

| Purpose             | Command                                                       | Expected   |
|---------------------|--------------------------------------------------------------|------------|
| New formatter test  | `swift test --filter TranscriptFormatterTests`               | all pass   |
| Transcription tests | `swift test --filter TranscriptionServiceTests`              | all pass   |
| Dictation tests     | `swift test --filter Dictation`                              | all pass   |
| Build               | `swift build`                                                | exit 0     |
| Full tests          | `swift test`                                                 | all pass   |

## Scope

**In scope** (create/modify):
- `Sources/MacParakeetCore/TextProcessing/TranscriptFormatter.swift` (create — holds the unified `FormatterOutcome` + `TranscriptFormatter`)
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift` (remove the dup; delegate)
- `Sources/MacParakeetCore/Services/TranscriptionService.swift` (remove the dup; delegate)
- `Tests/MacParakeetTests/TextProcessing/TranscriptFormatterTests.swift` (create)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- The `refine(...)` text-refinement step, persistence (`save`), and telemetry
  emission around these methods — only the AI-formatter sub-step moves. (The
  capture-telemetry dual-emit dedup is a separate deferred follow-up — see notes.)
- Notification names, `LLMRun` shape, `formatTranscriptDetailed` signature,
  `TelemetryFormatterSource` — unchanged.
- The `aiFormatterPromptResolver` / profile-resolution logic itself — it stays in
  `DictationService`; only its *result* is passed into the formatter.

## Git workflow

- Branch: `advisor/transcript-formatter-dedup` off `origin/main`.
- Commit style: rich message (`docs/commit-guidelines.md`). Example subject:
  `Refactor: extract shared TranscriptFormatter from Dictation/Transcription`.
- Do NOT push or open a PR unless instructed.

## Steps

### Step 1: Create the unified FormatterOutcome + TranscriptFormatter

Create `Sources/MacParakeetCore/TextProcessing/TranscriptFormatter.swift`:

1. One internal `struct FormatterOutcome: Sendable` with `text: String?`,
   `run: LLMRun?`, `resolution: AIFormatterPromptResolution?` (superset — the
   transcription path simply leaves `resolution` nil). One `static let skipped =
   FormatterOutcome(text: nil, run: nil, resolution: nil)`.
2. A `struct TranscriptFormatter: Sendable` holding the shared deps:
   `llmService: LLMServiceProtocol?`, `shouldUseAIFormatter: @Sendable () -> Bool`,
   `logger: Logger`. Expose one async method that captures the unified body and
   the five differences as parameters:

   ```swift
   func format(
       _ text: String,
       runSource: LLMRunSource?,
       source: TelemetryFormatterSource,         // .dictation / .transcription
       feature: LLMRun.Feature,                  // .formatterDictation / .formatterTranscription (match the real enum path)
       warningSource: String,                    // "dictation" / "transcription"
       maxInputChars: Int?,                      // nil = no cap (dictation); 20_000 (transcription)
       lifecycleNotificationSource: String?,     // non-nil => post DidStart/DidFinish (dictation = "dictation"; transcription = nil)
       resolvePrompt: () async -> (template: String, resolution: AIFormatterPromptResolution?)
   ) async throws -> FormatterOutcome
   ```

   The body is the merged logic: guard `shouldUseAIFormatter(), let llmService`
   (else `.skipped`); if `maxInputChars` is non-nil and `text.count` exceeds it,
   log the `…_skipped reason=input_too_long` line and return `.skipped`; if
   `lifecycleNotificationSource` is non-nil, post `.macParakeetAIFormatterDidStart`
   and `defer` `.macParakeetAIFormatterDidFinish` (userInfo `["source": that]`);
   `let (promptTemplate, resolution) = await resolvePrompt()`; compute
   `defaultPromptUsed`; `do { call formatTranscriptDetailed(…); trim; build LLMRun(…
   feature:); return FormatterOutcome(text:, run:, resolution:) } catch { rethrow
   CancellationError; else log `…_failed`, post `.macParakeetAIFormatterWarning`
   (userInfo source+message), return FormatterOutcome(text: nil, run:
   failedFormatterRun(…), resolution: nil) }`.

   Move the log strings verbatim, parameterizing only the `dictation_`/`transcription_`
   prefix by `warningSource` if you wish, OR keep two literal log lines selected by
   `warningSource` to preserve exact telemetry strings. **Preserve the exact log
   keys** (`dictation_ai_formatter_failed`, `transcription_ai_formatter_failed`,
   `transcription_ai_formatter_skipped`).

**Verify**: `swift build` → the new file compiles (it may be unused until Step 2).

### Step 2: Delegate from DictationService

In `DictationService`:
- Delete the local `private struct FormatterOutcome` (line 47) and `private func
  formatTranscriptIfNeeded` (lines 1277–1359).
- Construct a `TranscriptFormatter` (a stored `let` built in `init`, or inline)
  with `llmService`, `shouldUseAIFormatter`, `logger`.
- Replace the call site (line 1204) with:
  ```swift
  let formatterOutcome = try await transcriptFormatter.format(
      baseText,
      runSource: saveHistory ? LLMRunSource(dictationId: dictationID) : nil,
      source: .dictation,
      feature: .formatterDictation,
      warningSource: "dictation",
      maxInputChars: nil,
      lifecycleNotificationSource: "dictation",
      resolvePrompt: {
          let resolution = await self.aiFormatterPromptResolver.resolvePrompt(for: formatterContext)
          return (resolution.promptTemplate, resolution)
      }
  )
  ```
  (The downstream use of `formatterOutcome.text` / `.run` / `.resolution` at lines
  1209–1257 stays exactly as-is — the unified `FormatterOutcome` has all three fields.)

**Verify**: `swift build` → exit 0; `swift test --filter Dictation` → all pass.

### Step 3: Delegate from TranscriptionService

In `TranscriptionService`:
- Delete the local `private struct FormatterOutcome` (line 50) and `private func
  formatTranscriptIfNeeded` (lines 1638–1700).
- Build a `TranscriptFormatter` the same way.
- Replace the call site (line 1548) with:
  ```swift
  let formatterOutcome = try await transcriptFormatter.format(
      baseText,
      runSource: persistResult ? LLMRunSource(transcriptionId: transcription.id) : nil,
      source: .transcription,
      feature: .formatterTranscription,
      warningSource: "transcription",
      maxInputChars: AIFormatter.maxTranscriptionInputChars,
      lifecycleNotificationSource: nil,
      resolvePrompt: { (self.aiFormatterPromptTemplate(), nil) }
  )
  ```
  (`formatterOutcome.text` / `.run` usage at lines 1552–1570 stays as-is;
  `.resolution` is simply unused here — fine.)

**Verify**: `swift build` → exit 0; `swift test --filter TranscriptionServiceTests` → all pass.

### Step 4: Add focused TranscriptFormatter tests

Create `Tests/MacParakeetTests/TextProcessing/TranscriptFormatterTests.swift`,
using the `LLMServiceProtocol` mock from `ViewModelMocks.swift` (or a local minimal
mock if that one isn't reusable). Cover:
- `skipped` when `shouldUseAIFormatter` returns false (no llmService call).
- `skipped` when `maxInputChars` is set and text exceeds it (transcription cap path);
  and NOT skipped when `maxInputChars` is nil even for long text (dictation path).
- success: returns trimmed text + a non-nil `run`; `resolution` carried when the
  prompt provider returns one.
- failure: a mock that throws a non-cancellation error returns `text == nil`, a
  failed `run`, and posts `.macParakeetAIFormatterWarning` (observe via a
  NotificationCenter expectation).
- `CancellationError` from the mock is rethrown (not swallowed).
- lifecycle: when `lifecycleNotificationSource` is non-nil, DidStart/DidFinish are
  posted; when nil, they are not (NotificationCenter expectations).

**Verify**: `swift test --filter TranscriptFormatterTests` → all pass.

### Step 5: Full suite + duplication gone

**Verify**:
- `swift test` → all pass.
- `grep -rn "struct FormatterOutcome" Sources/MacParakeetCore` → exactly **one**
  match (in `TranscriptFormatter.swift`).
- `grep -rn "private func formatTranscriptIfNeeded" Sources/MacParakeetCore` → **zero** matches.

## Test plan

- **Regression nets (must pass unchanged):** `TranscriptionServiceTests`, the
  Dictation tests, and `LLMServiceTests`. The formatter contract is preserved, so
  these pass without edits.
- **New:** `Tests/MacParakeetTests/TextProcessing/TranscriptFormatterTests.swift`
  (cases listed in Step 4), modeled on `LLMServiceTests.swift`'s mock usage. This is
  the first time the formatter path is testable without standing up a full service.
- Verification: `swift test` → all pass; the three filters in Steps 2–4 each green.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `Sources/MacParakeetCore/TextProcessing/TranscriptFormatter.swift` exists with one `FormatterOutcome` and one `TranscriptFormatter`.
- [ ] `grep -rn "struct FormatterOutcome" Sources/MacParakeetCore` → exactly 1 match.
- [ ] `grep -rn "private func formatTranscriptIfNeeded" Sources/MacParakeetCore` → 0 matches.
- [ ] `swift build` exits 0.
- [ ] `swift test --filter TranscriptFormatterTests` passes (≥ 6 tests).
- [ ] `swift test --filter TranscriptionServiceTests` and `--filter Dictation` pass **without assertion edits**.
- [ ] `swift test` exits 0 (full suite).
- [ ] Telemetry log keys unchanged: `grep -rn "ai_formatter_failed\|ai_formatter_skipped" Sources/MacParakeetCore` still shows `dictation_ai_formatter_failed`, `transcription_ai_formatter_failed`, `transcription_ai_formatter_skipped`.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report back (do not improvise) if:

- The two methods differ in a way not captured by the five parameters above (e.g.
  a third notification, a different trim rule) — report the extra difference rather
  than dropping it.
- Preserving the exact telemetry log strings/keys conflicts with parameterizing the
  body — keep the exact strings (select by `warningSource`) and report the awkwardness.
- `LLMRun.Feature` / `TelemetryFormatterSource` are not the exact type names at the
  call sites (the excerpt used shorthand) — use whatever the real call sites use and
  report the discrepancy; do not invent enum cases.
- A regression test (`TranscriptionServiceTests` / Dictation) needs an assertion
  change to pass — that means behavior drifted; STOP.
- The `aiFormatterPromptResolver` resolution carries fields the dictation call site
  reads beyond `promptTemplate`/`profileID`/`profileName`/`matchKind` — confirm the
  `resolution` round-trips intact through `FormatterOutcome`.

## Maintenance notes

- **Deferred follow-up (the other half of the "three-modes dedup" cluster):** extract
  a `CaptureTelemetryEmitter` for the duplicated dual-emit completed/operation
  telemetry in `DictationService` (`Telemetry.send(.dictationCompleted)` +
  `sendDictationOperation`) and `TranscriptionService` (`.transcriptionCompleted` +
  `sendTranscriptionOperation`). Lower value, and telemetry event names are a
  two-repo allowlist contract (`docs/telemetry.md`) — keep names identical. Track as
  its own plan.
- A reviewer should verify the formatter posts the **same** notifications with the
  **same** userInfo, preserves the `CancellationError` rethrow (a swallow here would
  break cancellation), and that `resolution` still reaches the dictation record
  (the History "Formatted with profile" provenance depends on it).
- When a third capture mode wants AI formatting (e.g. meeting), it now reuses
  `TranscriptFormatter` instead of copy-pasting a third method.
