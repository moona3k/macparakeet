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
> `format(...)` success/error return + the `Lane` enum),
> `…/TextProcessing/AIFormatter.swift` (`maxTranscriptionInputChars` **and any
> existing output normalization/validation it already does** — don't duplicate
> it), `Models/LLMRun.swift` (`LLMRun(formatterResult:…)` vs
> `failedFormatterRun(...)`), and the two call sites
> (`Services/Dictation/DictationService.swift`, `Services/TranscriptionService.swift`)
> to confirm how `FormatterOutcome.text == nil` is consumed. If the `format()`
> success return is no longer
> `return FormatterOutcome(text: trimmed.isEmpty ? nil : trimmed, run: run, resolution: resolution)`,
> reconcile against the live code; on a material mismatch, treat it as a STOP condition.

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
  emitted/pasted text is already a clean, verbatim-preserving result (the
  formatter is *optional polish on top*). When formatting is skipped or fails
  today, the user gets exactly that baseline back.
- So a guard that **falls back to that baseline whenever the polish looks
  broken loses nothing in the bad case and keeps the win in the good case.** The
  cost is a small amount of pure, synchronous, deterministic string logic that
  runs once per formatted transcript — negligible next to the LLM call that just
  completed.

A deliberately *narrow*, **accept-biased** guard — catch gross corruption, never
second-guess legitimate light or structural edits — is the right scope. We are
not trying to detect subtle meaning changes (that needs a different mechanism);
we are putting a floor under catastrophic output on a path that has none.

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
- **What a "no usable formatted text" return actually does at the call sites
  (verify in Step 0).** When `format()` returns `text: nil` (today: empty output
  or an LLM error), the callers fall back to the pre-formatter text:
  - `DictationService`: emitted/pasted text is `formattedTranscript ?? baseText`
    (always non-nil); the **persisted** `cleanTranscript` is
    `formattedTranscript ?? cleanTranscript`, which is `nil` in Raw mode.
  - `TranscriptionService`: persisted `cleanTranscript` is
    `formattedTranscript ?? refinement.text`, which is `nil` in Raw mode.

  So a rejection reproduces **exactly the existing skip/failure outcome**: the
  emitted text is always the baseline, and the stored `cleanTranscript` is
  whatever a skip/failure would store today (nil in Raw mode). This is correct
  and is the intended behavior — **do not "fix" the Raw-mode nil by changing the
  call sites to store `baseText`; that would be an out-of-scope behavior change.**
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
- `Sources/MacParakeetCore/TextProcessing/TranscriptFormatter.swift` (call the validator at the success return; reject → existing `text: nil` fallback shape; add an injectable enable closure + per-lane limits on `Lane`)
- `Sources/MacParakeetCore/AppFeatures.swift` (add the default-on kill switch)
- `Tests/MacParakeetTests/TextProcessing/RefinementValidatorTests.swift` (create)
- `Tests/MacParakeetTests/TextProcessing/TranscriptFormatterTests.swift` (extend)
- `plans/README.md` (status row)

**Out of scope** (do NOT touch):
- **Transforms** (`TransformExecutor`, `LLMService.transformStream`). Transforms
  are *intentional rewrites* (summarize, translate, reformat, voice-instruction
  over a selection — see `2026-06-21-spoken-transforms`). A length/overlap guard
  would wrongly reject correct Transform output. Transforms never call
  `TranscriptFormatter`, so they are naturally excluded; do not add the validator
  to that path. This boundary — *validate cleanup, never validate rewrites* — is
  the load-bearing scope decision. (Verified: `TransformExecutor` calls
  `llmService.transformStream(...)` directly; `format()` has exactly two
  production callers, both transcription/dictation.)
- The deterministic `TextProcessingPipeline` / `TextRefinementService` (already
  verbatim-safe; nothing to validate).
- The call sites' fallback expressions and the Raw-mode `nil` storage semantics
  (preserve as-is — see Current state).
- The default state of `aiFormatterEnabled*` prefs, prompt templates,
  `formatTranscriptDetailed` signature, `LLMRun` shape, notification names,
  telemetry event names.

**Invariants** (must hold):
- `RefinementValidator` is **pure**: no I/O, no global state, no LLM call, no
  throwing; same `(refined, original, limits)` always yields the same `Decision`.
- The validator can only ever **downgrade to the deterministic baseline** — it
  never rewrites, truncates, or "fixes" text. It is a yes/no gate, not a
  transformer. (Normalization stays `AIFormatter`'s job.)
- A rejection delivers **exactly the existing skip/failure outcome** at both call
  sites (emitted text = baseline; persisted `cleanTranscript` unchanged from
  today, including Raw-mode `nil`). No call-site edits.
- On rejection, the **succeeded** `LLMRun` is preserved (the call really did
  succeed); only the *use* of its text is declined. The run is never relabeled
  as failed and never dropped.
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
        case empty             // refinement is blank
        case lengthRunaway     // refinement is implausibly longer than the input
        case repetitionLoop    // a short word n-gram repeats back-to-back (degeneration)
        case lowContentOverlap // too few of the input's content words survived
    }

    public struct Limits: Sendable {
        public var maxLengthGrowth: Double         // reject if refined.count > original.count * this + slack
        public var lengthSlack: Int
        public var minContentOverlap: Double       // fraction of original CONTENT words that must survive
        public var overlapMinContentWords: Int     // only apply overlap check above this many content words
        public var maxConsecutiveNGramRepeats: Int // reject when a 3-/4-gram repeats back-to-back ≥ this many times

        // Starting values — CALIBRATE against the fixtures in Step 1 before wiring,
        // then refine from Phase C telemetry. Not sacred.
        public static let dictation = Limits(
            maxLengthGrowth: 1.8, lengthSlack: 80,
            minContentOverlap: 0.5, overlapMinContentWords: 6,
            maxConsecutiveNGramRepeats: 3)
        public static let transcription = Limits(
            maxLengthGrowth: 2.0, lengthSlack: 200,
            minContentOverlap: 0.5, overlapMinContentWords: 8,
            maxConsecutiveNGramRepeats: 3)
    }

    public static func validate(refined: String, original: String, limits: Limits) -> Decision
}
```

**Shared tokenizer (used by both the repetition and overlap checks — define
once):** lowercase the text; split on whitespace; for each token strip *leading
and trailing* non-alphanumeric characters (this removes commas, colons, quotes,
and markdown decoration `# ## - * > ** _`); drop tokens that become empty. This
makes `"team,"`, `"team"`, and `"**team**"` compare equal and prevents
punctuation from hiding a repeat. Keep this normalization byte-for-byte identical
between the two checks.

**Content words** = tokenized words minus a defined `stopWords` set:
- narrow fillers: `um, uh, umm, uhh`
- common function words the formatter may legitimately swap (so swapping them
  must NOT count as lost content): `a, an, the, and, or, but, of, to, in, on,
  at, for, with, as, is, are, was, were, be, been, it, its, this, that, i, you,
  he, she, we, they, my, your, on, upon`

The four checks, in order (first failure wins; **bias toward accept**):

1. **empty** — `refined` trimmed is blank → `.reject(.empty)`. (At the call site
   the empty case is short-circuited before the validator runs; this case is
   covered by calling `validate()` directly in unit tests.)
2. **lengthRunaway** — `refined.count > Int(Double(original.count) * limits.maxLengthGrowth) + limits.lengthSlack`
   → reject. Catches appended commentary / essays / duplication. Generous slack so
   structural formatting (paragraph breaks, light markdown) never trips it.
3. **repetitionLoop** — tokenize `refined`; for `n` in `{3, 4}`, walk adjacent
   n-grams and count the longest run of the **same** n-gram repeating
   **back-to-back**; if any run length ≥ `maxConsecutiveNGramRepeats` → reject.
   Consecutive-run detection (not total count in a window) is what distinguishes
   model degeneration ("the team the team the team the team") from legitimate
   recurring phrasing ("pursuant to the …" five times across a transcript) and
   from scattered speaker labels ("John:" … "Sarah:" … "John:"), neither of which
   should ever trip it.
4. **lowContentOverlap** — build content-word **sets** for both texts (tokenize,
   then drop `stopWords`). Only if the original content-word set size >
   `overlapMinContentWords`, compute `|refined ∩ original| / |original|`; if
   `< minContentOverlap` → reject. This is the core anti-drop / anti-substitution
   guard. Skipped for short inputs so a single swapped word in a short dictation
   can't tank the ratio. Stop-word exclusion is the deliberate fix for the
   formatter's *intended* job (fixing grammar/function words) — that work must
   not read as "lost content." (Considered and rejected: lowering the floor to
   ~0.35 on raw words — too permissive on real drops while still penalizing
   function-word rephrasing. Stop-word exclusion targets the actual cause.)

No question-form / subject-verb checks (model-specific), no semantic checks
(needs a model), no compression-ratio (redundant with #2 + #3). Four general,
deterministic checks — each mapped to a real, catchable failure mode — is the
whole design.

### Wiring (Phase B) — at the chokepoint, per lane, behind an injectable kill switch

Add to the `TranscriptFormatter` struct an injectable enable closure with a
production default (so existing construction sites need no change and tests can
override it — the same idiom as `shouldUseAIFormatter`):

```swift
var isValidationEnabled: @Sendable () -> Bool = { AppFeatures.refinementValidationEnabled }
```

Then replace the `format(...)` success return:

```swift
let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
let run = runSource.map { LLMRun(formatterResult: result, source: $0, feature: lane.feature) }

if !trimmed.isEmpty, isValidationEnabled() {
    if case .reject(let reason) = RefinementValidator.validate(
        refined: trimmed, original: text, limits: lane.validatorLimits
    ) {
        // The LLM call SUCCEEDED — we are declining to USE its output. Keep the
        // succeeded `run` (provider/model/tokens intact, correct cost attribution)
        // but deliver the deterministic baseline: text: nil routes the caller to
        // `?? baseText`; resolution dropped so History never stamps a profile onto
        // text it didn't produce. Same delivered outcome as a skip/failure — by design.
        switch lane {
        case .dictation:
            logger.warning("dictation_ai_formatter_rejected reason=\(reason.rawValue, privacy: .public)")
        case .transcription:
            logger.warning("transcription_ai_formatter_rejected reason=\(reason.rawValue, privacy: .public)")
        }
        return FormatterOutcome(text: nil, run: run, resolution: nil)
    }
}

return FormatterOutcome(text: trimmed.isEmpty ? nil : trimmed, run: run, resolution: resolution)
```

- **Do NOT** post `.macParakeetAIFormatterWarning` on rejection. That
  notification is for hard LLM failures; a silent fall-back to the clean baseline
  is not a user-facing warning.
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

### Step 1 (Phase A): Create `RefinementValidator` + unit tests, and calibrate the limits

Create `Sources/MacParakeetCore/TextProcessing/RefinementValidator.swift` per
the Design (pure, `public`, only `import Foundation`). Then create
`Tests/MacParakeetTests/TextProcessing/RefinementValidatorTests.swift` (XCTest —
`final class RefinementValidatorTests: XCTestCase`, `func testX()`,
`XCTAssertEqual`, modeled on `TextProcessingPipelineTests`).

**Accept fixtures (must NOT be rejected — these are the false-reject guardrails
for the on-by-default transcription lane):**
- light cleanup: `"um so the kubernetes cluster is down"` → `"So the Kubernetes cluster is down."`
- structural formatting: refined adds a markdown heading + bullets + paragraph
  breaks while preserving content words.
- filler removal only: refined drops `um`/`uh`.
- function-word rephrase: `"on"`→`"upon"`, `"the"`→`"a"` (stop words — excluded).
- technical phrase tidy: `"the kubernetes thing"` → `"the Kubernetes cluster"`
  inside a longer sentence.
- dispersed legitimate repetition: a phrase like `"pursuant to the"` appearing 5×
  scattered across a long transcript.
- speaker labels: `"John: … Sarah: … John: …"`.

**Reject fixtures:**
- `.lengthRunaway`: refined ≈ 3× original + appended commentary.
- `.repetitionLoop`: back-to-back `"the team the team the team the team"`, AND the
  comma variant `"the team, the team, the team, the team,"` (proves shared
  punctuation-stripping).
- `.lowContentOverlap`: refined replaces/drops most content words of a long input.
- `.empty`: blank refined via `validate()` directly.

**Edge:** a short (≤ `overlapMinContentWords`) input with one substitution is NOT
rejected by overlap. **Purity:** same inputs → identical `Decision` twice.

**Calibrate:** run the fixtures; if any *accept* fixture is rejected, adjust the
lane `Limits` (raise `overlapMinContentWords`, or `maxLengthGrowth`/`lengthSlack`)
until all accept fixtures pass while all reject fixtures still fail. Record the
final numbers. Do not weaken a check so far that a reject fixture passes.

**Verify**: `swift test --filter RefinementValidatorTests` → all pass. No
production wiring yet; this phase is zero behavior change and can ship alone.

### Step 2 (Phase B): Add the kill switch + injectable enable closure + per-lane limits

- Add `AppFeatures.refinementValidationEnabled = true` (Design copy).
- Add `var isValidationEnabled: @Sendable () -> Bool = { AppFeatures.refinementValidationEnabled }`
  to `TranscriptFormatter`.
- Add `validatorLimits` to `TranscriptFormatter.Lane`.

**Verify**: `swift build` → exit 0.

### Step 3 (Phase B): Gate the success return in `TranscriptFormatter.format`

Apply the Design wiring at the success return. On reject, return
`FormatterOutcome(text: nil, run: run, resolution: nil)` (the **succeeded** run)
and log `<lane>_ai_formatter_rejected reason=…`.

**Verify**: `swift build` → exit 0; `swift test --filter TranscriptFormatterTests`,
`--filter TranscriptionServiceTests`, `--filter Dictation` → all pass **without
editing existing assertions** (a needed assertion change means behavior drifted
— STOP).

### Step 4 (Phase B): Extend `TranscriptFormatterTests`

Using the existing `LLMServiceProtocol` mock, add:
- LLM returns broken output (runaway / low-overlap / back-to-back repetition) →
  outcome `text == nil`, `run != nil` (the succeeded run is preserved),
  `resolution == nil`, and `<lane>_ai_formatter_rejected` logged.
- LLM returns good output → outcome carries the refined `text` unchanged
  (passthrough; `run`/`resolution` intact).
- **Kill switch:** construct the `TranscriptFormatter` with
  `isValidationEnabled: { false }` → broken output passes through unvalidated.
- **Raw-mode rejection:** a rejected formatting in a Raw-mode flow yields the
  baseline (formatter `text == nil`) — assert the formatter contract; the
  call-site Raw `nil` storage is unchanged.
- Per-lane: a transcription-length input that the `.transcription` limits accept
  is not rejected.

**Verify**: `swift test --filter TranscriptFormatterTests` → all pass.

### Step 5: Full suite

**Verify**: `swift test` → all pass. `grep -rn "RefinementValidator" Sources/MacParakeetCore`
→ matches only in `RefinementValidator.swift` and `TranscriptFormatter.swift`.

## Test plan

- **New:** `RefinementValidatorTests` (pure, the bulk of the coverage — fast,
  deterministic, no mocks; includes the accept/reject/edge fixtures above).
- **Extended:** `TranscriptFormatterTests` (reject→succeeded-run+baseline,
  accept→passthrough, flag-off→passthrough, Raw-mode, per-lane accept).
- **Regression nets (must pass unchanged):** `TranscriptionServiceTests`,
  Dictation tests, `LLMServiceTests`. The accept path is byte-for-byte the prior
  behavior, so these pass without edits.

## Risk + mitigation

The one real risk is a **false reject** on the on-by-default transcription lane:
a legitimately heavy-but-correct reformat dips below a threshold and the user
silently gets the (still-correct) baseline instead of the polished version.
Mitigations: (1) accept-biased checks + stop-word-aware overlap + consecutive-run
repetition, all calibrated against realistic accept fixtures in Step 1 *before*
wiring; (2) the fallback is always a correct transcript, never broken output;
(3) the `<lane>_ai_formatter_rejected` log line makes over-rejection visible in
dev logs; (4) the default-on kill switch disables the whole gate without a
revert; (5) Phase C telemetry turns threshold tuning into a data-driven follow-up.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `Sources/MacParakeetCore/TextProcessing/RefinementValidator.swift` exists; pure (no `import` beyond `Foundation`; no `await`, no `throws`).
- [ ] `AppFeatures.refinementValidationEnabled` exists, defaults `true`; `TranscriptFormatter` reads it via an injectable `isValidationEnabled` closure.
- [ ] `TranscriptFormatter.Lane` exposes `validatorLimits`; `format()` validates the success path only when enabled and text is non-empty.
- [ ] Reject path returns `text: nil` + the **succeeded** `run` (not a failed run, not nil) + `resolution: nil`, and logs `dictation_ai_formatter_rejected` / `transcription_ai_formatter_rejected reason=…`.
- [ ] No `.macParakeetAIFormatterWarning` is posted on the rejection path.
- [ ] `swift test --filter RefinementValidatorTests` passes (all accept fixtures accept, all reject fixtures reject, incl. the comma-repetition and dispersed-phrase cases).
- [ ] `swift test --filter TranscriptFormatterTests` passes (reject→succeeded-run+baseline, flag-off passthrough via injected closure, Raw-mode).
- [ ] `TranscriptionServiceTests` and `Dictation` filters pass **without assertion edits**.
- [ ] `swift test` exits 0.
- [ ] Transforms untouched: `grep -rn "RefinementValidator" Sources/MacParakeetCore` shows no match under `Services/Transforms/`.
- [ ] `plans/README.md` status row updated.

## STOP conditions

Stop and report (do not improvise) if:
- The live `format()` success return differs materially from the "Current state"
  excerpt (Step 0 mismatch).
- A regression assertion in `TranscriptionServiceTests` / Dictation must change
  to pass — behavior drifted; STOP.
- Adding the validator would require touching the Transforms path, or changing a
  call site's fallback expression / Raw-mode storage — it must not; STOP.
- After calibration, no `Limits` setting makes all accept fixtures pass while
  keeping all reject fixtures failing — the heuristics need rethinking; STOP and
  report which fixtures conflict.

## Open questions (for the owner)

- **Thresholds.** Step 1 calibrates against fixtures; Phase C tunes from real
  telemetry. Ship the calibrated defaults, or hand-tighten first?
- **Surface rejections to the user?** Recommendation: **no** — silent fallback +
  log only. It's a quality floor, not an event to act on; `.macParakeetAIFormatterWarning`
  stays reserved for hard failures.
- **Kill switch.** Keep the default-on `AppFeatures` flag (recommended, matches
  `meetingCaptureReliabilityEnabled`), or wire the gate unconditionally?

## Maintenance notes

- **Phase C (deferred): make rejections queryable for tuning.** v1 records
  rejections via `logger` only. To tune thresholds from the database rather than
  scraping logs, add a queryable signal — either an `LLMRun` rejection marker
  (e.g. an `ErrorType.outputRejected` that still preserves the succeeded run's
  provider/model/token data — do **not** reuse `failedFormatterRun`, which zeroes
  those) or a dedicated `formatter_output_rejected` telemetry event with
  `{reason, lane}`. Telemetry event names are a **two-repo allowlist contract**
  (`docs/telemetry.md` + website `ALLOWED_EVENTS`); that cross-repo step is why
  this is deferred, not bundled. Track as its own plan.
- **Transforms guardrails are a separate problem.** If Transforms / Spoken
  Transforms ever want a safety net, it is NOT this validator (overlap/length
  guards reject legitimate rewrites). That needs a different mechanism
  (structured output, diff preview, constrained generation) — out of scope here
  by design.
- **Meeting lane.** Meeting transcripts are raw/verbatim by default today, so the
  immediate impact is the file/URL transcription lane; the guard is already in
  place for whenever meeting AI formatting routes through `TranscriptFormatter`.
