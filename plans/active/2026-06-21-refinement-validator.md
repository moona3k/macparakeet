# Plan: RefinementValidator — guard AI-formatter output, fall back to the deterministic baseline

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. If
> anything in "STOP conditions" occurs, stop and report — do not improvise.
> When done, update the status row for this plan in `plans/README.md`.
>
> **Step 0 — read the real code first (drift check).** This plan was written
> against the shipped `TranscriptFormatter` (post-`2026-06-15-transcript-formatter-dedup`).
> Before editing, read the live versions of:
> `Sources/MacParakeetCore/TextProcessing/TranscriptFormatter.swift` (the
> `format(...)` success return + the `Lane` enum), `…/TextProcessing/AIFormatter.swift`
> (`maxTranscriptionInputChars`), and `Models/LLMRun.swift`
> (`failedFormatterRun(...)`). If the `format()` success return is no longer
> `return FormatterOutcome(text: trimmed.isEmpty ? nil : trimmed, run: run, resolution: resolution)`,
> reconcile the "Current state" excerpt against the live code; on a material
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW–MED (additive pure type; Phase B changes a live default path only when the LLM output is actually broken — see "Risk + mitigation")
- **Depends on**: `2026-06-15-transcript-formatter-dedup` (the shared `TranscriptFormatter` chokepoint — shipped). Soft: `2026-06-15-dx-format-lint-baseline` for `scripts/dev/check.sh`.
- **Category**: feature / safety
- **Planned at**: commit `a8e1e3948`, 2026-06-21

## Why this matters

The AI formatter is the one place in the text path where a language model is
allowed to **rewrite the user's transcript**. Today, when it runs, whatever
non-empty string it returns is accepted verbatim:

```swift
// TranscriptFormatter.format(...) — the success return today
let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
…
return FormatterOutcome(text: trimmed.isEmpty ? nil : trimmed, run: run, resolution: resolution)
```

The **only** guard on formatter output anywhere in the codebase is "is it
empty." There is no check that the model didn't drop half the words, summarize
the transcript away, append commentary, or fall into a repetition loop — all
known failure modes of small / quantized / local models, which is exactly the
configuration a local-first app encourages users to run.

This is a **live gap, not a hypothetical**. File/URL + meeting transcription
formatting ships **on by default** (`aiFormatterEnabledForTranscriptions = true`
in `AppRuntimePreferences`); dictation formatting is opt-in
(`aiFormatterEnabledForDictation = false`). So a real default-on path can today
persist a mangled transcript as the user's `cleanTranscript` with no floor under
it.

The fix follows a simple, first-principles asymmetry:

- The **deterministic baseline is always shippable.** Before the LLM runs, the
  text has already been through `TextRefinementService` (filler trim, custom
  words, snippets) — a clean, verbatim-preserving result. The LLM formatting is
  *optional polish on top*.
- So a guard that **falls back to that baseline whenever the polish looks
  broken loses nothing in the bad case and keeps the win in the good case.** The
  cost is a few hundred lines of pure, synchronous, deterministic string logic.

A deliberately *narrow* guard — catch gross corruption, never second-guess
legitimate light edits — is the right scope. We are not trying to detect subtle
meaning changes (that needs a different mechanism); we are putting a floor under
catastrophic output on a path that has none.

## Current state

- **Single chokepoint.** Both LLM-formatted lanes — (a) dictation
  (`DictationService`) and (b) file/URL + meeting transcription
  (`TranscriptionService`) — route through one method:
  `TranscriptFormatter.format(_:runSource:lane:resolvePrompt:)` in
  `Sources/MacParakeetCore/TextProcessing/TranscriptFormatter.swift`. The
  per-lane differences (input cap, telemetry source, lifecycle notifications,
  `LLMRun.Feature`) are already modeled by `TranscriptFormatter.Lane`
  (`.dictation` / `.transcription`). One insertion point covers every formatted
  lane.
- **Existing fallback shape is already correct and documented.** On an LLM
  error the method returns `FormatterOutcome(text: nil, run: failedFormatterRun(…),
  resolution: nil)`; the caller's downstream `formattedTranscript ?? baseText`
  then delivers the deterministic baseline, and `resolution` is intentionally
  dropped so History does not claim "Formatted with profile '<x>'" for text the
  profile never produced. A validator rejection is the same situation ("no
  usable formatted text") and reuses this exact return shape.
- **No content guard exists.** `grep -rn "overlap\|repetition\|hallucinat" Sources/MacParakeetCore`
  → nothing on formatter output. The only output check is `LLMService`'s
  empty-response rejection.
- **`TextProcessing` is a pure subsystem** (`Sources/MacParakeetCore/TextProcessing/README.md`,
  ADR-004): the deterministic pipeline does no I/O and never calls an LLM. A
  validator fits this ethos exactly — it is a pure function that *judges* LLM
  output; it does not call an LLM itself.
- **Flag precedent.** `AppFeatures.meetingCaptureReliabilityEnabled` is a
  default-on reliability path documented as kept "behind a kill switch while …
  phases are still being validated." This plan reuses that idiom.

## Scope

**In scope** (create/modify):
- `Sources/MacParakeetCore/TextProcessing/RefinementValidator.swift` (create — the pure validator)
- `Sources/MacParakeetCore/TextProcessing/TranscriptFormatter.swift` (call the validator at the success return; reject → existing fallback shape)
- `Sources/MacParakeetCore/AppFeatures.swift` (add the default-on kill switch)
- `Tests/MacParakeetTests/TextProcessing/RefinementValidatorTests.swift` (create)
- `Tests/MacParakeetTests/TextProcessing/TranscriptFormatterTests.swift` (extend: reject → fallback, accept → passthrough, flag-off → passthrough)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- **Transforms** (`TransformExecutor`, `LLMService.transformStream`). Transforms
  are *intentional rewrites* (summarize, translate, reformat, voice-instruction
  over a selection — see `2026-06-21-spoken-transforms`). A length/overlap guard
  would wrongly reject correct Transform output. Transforms never call
  `TranscriptFormatter`, so they are naturally excluded; do not add the validator
  to that path. This boundary — *validate cleanup, never validate rewrites* — is
  the load-bearing scope decision.
- The deterministic `TextProcessingPipeline` / `TextRefinementService` (already
  verbatim-safe; nothing to validate).
- The default state of `aiFormatterEnabled*` prefs, prompt templates,
  `formatTranscriptDetailed` signature, `LLMRun` shape, notification names,
  telemetry event names.
- Any user-facing surfacing of a rejection (see Open questions — recommend none).

**Invariants** (must hold):
- `RefinementValidator` is **pure**: no I/O, no global state, no LLM call, no
  throwing; same `(refined, original, limits)` always yields the same `Decision`.
- The validator can only ever **downgrade to the deterministic baseline** — it
  never rewrites, truncates, or "fixes" text. It is a yes/no gate, not a
  transformer. (Normalization stays `AIFormatter`'s job.)
- The deterministic baseline remains the floor: a rejection delivers exactly the
  text the user would have gotten with the formatter off.
- Transforms output is never routed through the validator.
- Telemetry log **keys** for the existing failure/skip paths are unchanged; the
  new rejection path adds a new log line, not a renamed one.

## Design

### The validator (Phase A) — pure value type

`Sources/MacParakeetCore/TextProcessing/RefinementValidator.swift`. Match the
shape of the neighboring `AIFormatter` (a stateless namespace is fine — no
instance state):

```swift
/// Judges whether AI-formatter (LLM) output is a safe replacement for the
/// deterministic baseline transcript. Pure and deterministic: it never rewrites
/// text, only accepts the refinement or rejects it in favor of the baseline.
/// Scope is light *cleanup/formatting* — NOT intentional rewrites (Transforms).
public enum RefinementValidator {
    public enum Decision: Equatable, Sendable {
        case accept
        case reject(Reason)
    }

    public enum Reason: String, Equatable, Sendable {
        case empty            // refinement is blank
        case lengthRunaway    // refinement is implausibly longer than the input
        case repetitionLoop   // a short word n-gram repeats degenerate-many times
        case lowContentOverlap // too few of the input's content words survived
    }

    public struct Limits: Sendable {
        public var maxLengthGrowth: Double      // reject if refined.count > original.count * this + slack
        public var lengthSlack: Int
        public var minContentOverlap: Double    // fraction of original content words that must survive
        public var overlapMinContentWords: Int  // only apply overlap check above this many content words
        public var repetitionMinWords: Int      // only apply repetition check above this many words
        public var repetitionMaxRepeats: Int    // reject at this many occurrences of a 3- or 4-gram

        // Starting values — tune from Phase C telemetry, do not treat as sacred.
        public static let dictation = Limits(
            maxLengthGrowth: 1.8, lengthSlack: 80,
            minContentOverlap: 0.5, overlapMinContentWords: 6,
            repetitionMinWords: 24, repetitionMaxRepeats: 4)
        public static let transcription = Limits(
            maxLengthGrowth: 2.0, lengthSlack: 200,
            minContentOverlap: 0.5, overlapMinContentWords: 8,
            repetitionMinWords: 40, repetitionMaxRepeats: 4)
    }

    public static func validate(refined: String, original: String, limits: Limits) -> Decision
}
```

The four checks, in order (first failure wins; bias toward **accept** so good
formatting is never second-guessed):

1. **empty** — `refined` trimmed is blank → `.reject(.empty)`. (At the call site
   the empty case is already short-circuited today; the enum case exists for
   completeness and unit coverage.)
2. **lengthRunaway** — `refined.count > Int(Double(original.count) * limits.maxLengthGrowth) + limits.lengthSlack`
   → reject. Catches appended commentary / essays / duplication. Generous slack so
   structural formatting (paragraph breaks, light markdown) never trips it.
3. **repetitionLoop** — tokenize `refined` to lowercased words; only if word
   count ≥ `repetitionMinWords`, scan 3-grams and 4-grams; if any gram occurs
   ≥ `repetitionMaxRepeats` times → reject. Catches small-model degeneration.
4. **lowContentOverlap** — build content-word **sets** for both texts: lowercase,
   strip punctuation, drop pure-markdown tokens (`#`, `##`, `-`, `*`, `>`), and
   drop the narrow filler set (`um`, `uh`, `umm`, `uhh` — matches the
   subsystem's intentionally-narrow filler discipline; the formatter is allowed
   to remove fillers, so they must not count against it). Only if the original
   content-word set size > `overlapMinContentWords`, compute
   `|refined ∩ original| / |original|`; if `< minContentOverlap` → reject. This
   is the core anti-drop / anti-substitution guard. Skipped for short inputs so a
   single dropped word in a 3-word dictation can't tank the ratio.

No question-form / subject-verb checks (model-specific), no semantic checks
(needs a model), no compression-ratio (redundant with #2 + #3). Four general,
deterministic checks — each mapped to a real, catchable failure mode — is the
whole design.

### Wiring (Phase B) — at the chokepoint, per lane, behind a kill switch

In `TranscriptFormatter.format(...)`, replace the success return:

```swift
let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
let run = runSource.map { LLMRun(formatterResult: result, source: $0, feature: lane.feature) }

if !trimmed.isEmpty, AppFeatures.refinementValidationEnabled {
    switch RefinementValidator.validate(refined: trimmed, original: text, limits: lane.validatorLimits) {
    case .accept:
        break
    case .reject(let reason):
        // Same situation as an LLM error: no usable formatted text. Reuse the
        // documented fallback shape — caller's `?? baseText` delivers the
        // deterministic baseline; resolution dropped so provenance doesn't claim
        // a profile formatted this text.
        switch lane {
        case .dictation:
            logger.warning("dictation_ai_formatter_rejected reason=\(reason.rawValue, privacy: .public)")
        case .transcription:
            logger.warning("transcription_ai_formatter_rejected reason=\(reason.rawValue, privacy: .public)")
        }
        let rejectedRun = runSource.map { /* failedFormatterRun(...) — see Step note */ }
        return FormatterOutcome(text: nil, run: rejectedRun, resolution: nil)
    }
}

return FormatterOutcome(text: trimmed.isEmpty ? nil : trimmed, run: run, resolution: resolution)
```

- Add `var validatorLimits: RefinementValidator.Limits` to `TranscriptFormatter.Lane`
  (`.dictation` → `.dictation`, `.transcription` → `.transcription`), alongside
  the existing per-lane computed properties. Meeting formatting, if/when it
  routes through this formatter, picks up the `.transcription` lane and is
  covered for free.
- **Kill switch.** Add to `AppFeatures.swift`, mirroring `meetingCaptureReliabilityEnabled`:

  ```swift
  /// AI-formatter output validation. When `true`, LLM-formatted transcripts are
  /// checked against the deterministic baseline (length runaway, repetition
  /// loop, dropped content) and fall back to that baseline when the output looks
  /// broken. Default-on safety floor; kept behind a kill switch so it can be
  /// disabled if thresholds over-reject in the field before they're telemetry-tuned.
  /// Transforms are intentional rewrites and are never validated.
  public static let refinementValidationEnabled: Bool = true
  ```

- **`rejectedRun` provenance:** reuse `LLMRun.failedFormatterRun(...)` exactly as
  the catch path does, **iff** the error-type vocabulary has a value that
  honestly represents "output rejected" (do NOT mislabel it as an API error). If
  no honest value exists, return `run: nil` (like `.skipped`) and rely on the new
  `*_ai_formatter_rejected` log line for observability. Do not invent an
  `LLMRun`/error enum case in this plan — see STOP conditions.

## Commands you will need

| Purpose                 | Command                                              | Expected   |
|-------------------------|------------------------------------------------------|------------|
| Validator unit tests    | `swift test --filter RefinementValidatorTests`       | all pass   |
| Formatter tests         | `swift test --filter TranscriptFormatterTests`       | all pass   |
| Transcription tests     | `swift test --filter TranscriptionServiceTests`      | all pass   |
| Dictation tests         | `swift test --filter Dictation`                      | all pass   |
| Build                   | `swift build`                                        | exit 0     |
| Full suite              | `swift test`                                         | all pass   |

## Steps

### Step 1 (Phase A): Create `RefinementValidator` + unit tests

Create `Sources/MacParakeetCore/TextProcessing/RefinementValidator.swift` per
the Design. Pure, `public`, no dependencies beyond `Foundation`. Then create
`Tests/MacParakeetTests/TextProcessing/RefinementValidatorTests.swift` (XCTest —
`final class RefinementValidatorTests: XCTestCase`, `func testX()`,
`XCTAssertEqual`, modeled on `TextProcessingPipelineTests`). Cover:

- **accept** light cleanup: original `"um so the kubernetes cluster is down"` →
  refined `"So the Kubernetes cluster is down."` → `.accept`.
- **accept** structural formatting: refined adds paragraph breaks / a markdown
  heading / bullet markers while preserving content words → `.accept`.
- **accept** filler removal: refined drops `um`/`uh` only → `.accept` (fillers
  excluded from overlap denominator).
- **reject `.lengthRunaway`**: refined ≈ 3× original + commentary.
- **reject `.repetitionLoop`**: refined contains a 3-gram repeated ≥ the
  threshold in a ≥`repetitionMinWords` body.
- **reject `.lowContentOverlap`**: refined replaces / drops most content words of
  a long input.
- **short-input safety**: a 3-word input with one substitution is NOT rejected by
  overlap (below `overlapMinContentWords`).
- **empty**: blank refined → `.reject(.empty)`.
- **purity**: same inputs → identical `Decision` twice.

**Verify**: `swift test --filter RefinementValidatorTests` → all pass. No
production wiring yet; this phase is zero behavior change and can ship alone.

### Step 2 (Phase B): Add the kill switch + per-lane limits

- Add `AppFeatures.refinementValidationEnabled = true` (Design copy).
- Add `validatorLimits` to `TranscriptFormatter.Lane`.

**Verify**: `swift build` → exit 0.

### Step 3 (Phase B): Gate the success return in `TranscriptFormatter.format`

Apply the Design wiring at the success return. Resolve `rejectedRun` per the
provenance note (honest error-type or `nil`).

**Verify**: `swift build` → exit 0; `swift test --filter TranscriptFormatterTests`,
`--filter TranscriptionServiceTests`, `--filter Dictation` → all pass **without
editing existing assertions** (a needed assertion change means behavior drifted
— STOP).

### Step 4 (Phase B): Extend `TranscriptFormatterTests`

Using the existing `LLMServiceProtocol` mock, add:
- LLM returns broken output (e.g. a runaway / low-overlap string) → outcome
  `text == nil`, caller falls back to baseline, `*_ai_formatter_rejected` logged.
- LLM returns good output → outcome carries the refined `text` (passthrough
  unchanged).
- `AppFeatures.refinementValidationEnabled == false` (inject/override if the flag
  isn't directly togglable in tests — otherwise note it as a manual check) →
  broken output passes through unvalidated (proves the kill switch).
- Per-lane: a transcription-length input that the `.transcription` limits accept
  is not rejected (guards against an over-tight cap on the on-by-default lane).

**Verify**: `swift test --filter TranscriptFormatterTests` → all pass.

### Step 5: Full suite

**Verify**: `swift test` → all pass. `grep -rn "RefinementValidator" Sources/MacParakeetCore`
→ matches only in `RefinementValidator.swift` and `TranscriptFormatter.swift`.

## Test plan

- **New:** `RefinementValidatorTests` (pure, the bulk of the coverage — fast,
  deterministic, no mocks).
- **Extended:** `TranscriptFormatterTests` (reject→fallback, accept→passthrough,
  flag-off→passthrough, per-lane accept).
- **Regression nets (must pass unchanged):** `TranscriptionServiceTests`,
  Dictation tests, `LLMServiceTests`. The accept path is byte-for-byte the prior
  behavior, so these pass without edits.

## Risk + mitigation

The one real risk is a **false reject** on the on-by-default transcription lane:
a legitimately heavy-but-correct reformat dips below a threshold and the user
silently gets the (still-correct) baseline instead of the polished version.
Mitigations: (1) deliberately permissive starting thresholds; (2) the fallback is
always a correct transcript, never broken output; (3) the `*_ai_formatter_rejected`
log line makes over-rejection visible in dev logs; (4) the default-on kill switch
disables the whole gate without a revert; (5) Phase C telemetry turns threshold
tuning into a data-driven follow-up rather than a guess.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `Sources/MacParakeetCore/TextProcessing/RefinementValidator.swift` exists; pure (no `import` beyond `Foundation`; no `await`, no `throws`).
- [ ] `AppFeatures.refinementValidationEnabled` exists, defaults `true`.
- [ ] `TranscriptFormatter.Lane` exposes `validatorLimits`; `format()` validates the success path only when the flag is on and text is non-empty.
- [ ] Reject path returns `text: nil` (baseline fallback) and logs `dictation_ai_formatter_rejected` / `transcription_ai_formatter_rejected reason=…`.
- [ ] `swift test --filter RefinementValidatorTests` passes (≥ 9 cases).
- [ ] `swift test --filter TranscriptFormatterTests` passes (incl. reject→fallback + flag-off passthrough).
- [ ] `TranscriptionServiceTests` and `Dictation` filters pass **without assertion edits**.
- [ ] `swift test` exits 0.
- [ ] Transforms untouched: `grep -rn "RefinementValidator" Sources/MacParakeetCore` shows no match under `Services/Transforms/`.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report (do not improvise) if:
- The live `format()` success return differs materially from the "Current state"
  excerpt (Step 0 mismatch).
- Reusing `failedFormatterRun(...)` for a rejection would require an error-type
  value that misrepresents the rejection as an API error, and no honest value
  exists — report it; default to `run: nil` + the log line rather than inventing
  an enum case.
- A regression assertion in `TranscriptionServiceTests` / Dictation must change
  to pass — behavior drifted; STOP.
- Adding the validator would require touching the Transforms path — it must not;
  STOP and report.

## Open questions (for the owner)

- **Thresholds.** The `Limits` values are first-pass. Ship as-is and tune from
  Phase C telemetry, or tighten/loosen now? (Recommendation: ship permissive.)
- **Surface rejections to the user?** Recommendation: **no** — silent fallback +
  log only. It's a quality floor, not an event the user should act on; the
  existing `.macParakeetAIFormatterWarning` is for hard failures, not "we used
  the clean baseline instead."
- **Kill switch.** Keep the default-on `AppFeatures` flag (recommended, matches
  `meetingCaptureReliabilityEnabled`), or wire the gate unconditionally?

## Maintenance notes

- **Phase C (deferred): rejection telemetry for threshold tuning.** Emit a
  metadata-only counter of rejection reason + lane so thresholds can be tuned on
  real output. Telemetry event names are a **two-repo allowlist contract**
  (`docs/telemetry.md` + the website `ALLOWED_EVENTS`) — that cross-repo step is
  why this is deferred, not bundled. v1 ships with `logger` only. Track as its
  own plan when the allowlist change is scheduled.
- **Transforms guardrails are a separate problem.** If Transforms / Spoken
  Transforms ever want a safety net, it is NOT this validator (overlap/length
  guards reject legitimate rewrites). That needs a different mechanism
  (structured output, diff preview, constrained generation) — out of scope here
  by design.
- **Meeting lane.** Meeting transcripts are raw/verbatim by default today, so the
  immediate impact is the file/URL transcription lane; the guard is already in
  place for whenever meeting AI formatting routes through `TranscriptFormatter`.
