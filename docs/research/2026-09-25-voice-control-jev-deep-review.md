# Voice Control and Jev: deep review

Date: 2026-09-25. Scope: the experimental Voice Control subsystem (voice-driven
computer control) behind `--enable-voice-control` (DEBUG only), and how it uses
Jev (`jev-1.13.0`, `POST https://api.typesafe.ai/v1/systemone`). Code at `main`
`779e9b30f` plus the fixes listed in [What changed](#what-changed-in-this-review).

Governing sources read: `Sources/MacParakeetCore/Services/VoiceControl/` (25
files, about 6,000 lines), `Sources/MacParakeet/App/VoiceControlCoordinator.swift`,
the [contract](../../spec/contracts/voice-control.md), ADR-033, the
[research folder](2026-09-19-jev-voice-control/README.md), both active plans,
the [TCU review](2026-09-20-typesafe-computer-use/README.md), the Jev API docs
(local mirror plus live `docs.typesafe.ai/models.md`), and the `typesafe-ai`
skill.

## Verdict

The safety core is good and should be kept: revocable `ActionAuthority`,
consume-once observations, receipts that separate verified effects from
observed transitions, no automatic replay of uncertain effects, a local
pay/delete/send floor that a model label cannot lower, and strict Jev response
validation. That core is more careful than every reference implementation in
`references/`.

The weak part is everything that decides *which route* a command takes. It is
a long ordered if-chain of substring heuristics that runs before the page's own
controls, and a growing set of site-specific macros (Google Flights, YouTube,
Gmail, Maps, Wikipedia, Google Search) whose heuristics leak into generic
legality. That layer produced every confirmed bug below. It is also the part
the repo's own guidance says should be a Jev decision (AGENTS.md: "Prefer Jev
for semantic classification, filtering, routing").

The feature has never been exercised live on this machine: there is no Voice
Control log directory (`~/Library/Logs/MacParakeet/voice-control` does not
exist), native Google Flights results are still unrecorded, and the integrated
microphone path is unqualified. Every quality claim so far is fixture evidence.

## How Jev is used today

Each turn: observe Accessibility (and optional on-device OCR), then route.

```
committed transcript
  -> coordinator grammar (stop / cancel / typing mode / yes-no confirmation)
  -> VoiceControlTurnRunner loop: observe -> decide -> policy -> execute -> receipt
       decide = VoiceControlCommandRouter:
         help, type, replace, reserved key, web destination, Flights plan,
         site query, Gmail compose, switch to browser, open app, undo, scroll,
         rewrite, named press, competing picker rows   (all local, in this order)
         -> Jev `outcome` Choice when several legal events compete
         -> Jev unconstrained request otherwise
```

Two Jev request shapes (`JevDecisionClient.swift`):

| Shape | Questions | Gate |
|---|---|---|
| `outcome` | one Choice over host-enumerated events, plus `insufficient_evidence` and `clarify` | confidence >= 0.5 |
| unconstrained | `kind` (press / fill / scroll / finished / none), `target` (<= 200 legal controls), `value` (focused field only; exact spans of the user's words), advisory `consequence`, `direction` when scrollable. A fill into an unfocused field costs a second `value` request. | `min(kind, target)` >= 0.5; `finished` / `none` on `kind` alone |

Against the Jev docs and the `typesafe-ai` skill this is mostly idiomatic:
pinned model (still the only release; `jev-latest` points at it), speculative
fan-out in one request, select-not-generate for values, a 0.5 floor, and strict
validation. The mismatches:

1. **No retry on 429/529.** The API asks direct HTTP callers to retry with
   exponential backoff; every sibling client in `references/` does. A rate limit
   surfaced as "Jev is unavailable". *Fixed.*
2. **`usage` discarded.** Token accounting for a paid dependency was dropped.
   *Fixed: recorded as `input_tokens` in the decision trace.*
3. **Targets sent twice.** Each control is in `state.observation.targets` as
   JSON and again as a criteria sentence. The API allows `null` criteria when
   the state already describes an option (`jev-voice-browser` does this to halve
   input tokens). *Not changed; see [recommendations](#recommendations-not-implemented).*
4. **Executed history leaked stale ids.** History carried walk-position ids
   (`n:4`) from older observations. The current snapshot can reuse `n:4` for a
   different control, so the model could read "already pressed" against the
   wrong control. It also carried model ids, scores and postconditions. *Fixed.*
5. **Consequence is one five-way Choice.** Per-hazard Nouls (payment?
   destructive? external?) are the better primitive per the model docs. This is
   low risk today because local policy treats any non-ordinary argmax as needing
   confirmation. *Not changed.*

## Confirmed findings

Each bug below was reproduced with a probe test against unmodified `main`
before fixing. Regression tests now cover them
(`VoiceControlIntentAnchoringTests`, `JevClientTransportTests`).

| # | Severity | Finding | Evidence on `main` | Status |
|---|---|---|---|---|
| 1 | High | Web destinations matched by substring anywhere in the command, before page controls. The adapter injects all six destinations into every browser snapshot. | On a shop page in Chrome: `search for headphones` -> google.com; `click the youtube link` -> YouTube; `reply to the email about my flight` and `open the flight confirmation` -> Google Flights. `browserForWebGoal` would also pull Mail users into Chrome for any mail mentioning a flight. | Fixed |
| 2 | High | Site query filling treated any leftover text as a query. | `like this video on YouTube` on YouTube would type "like this video" into the search box. | Fixed: needs a query verb |
| 3 | Medium-high | Google Flights date-picker heuristic in generic legality: any pressable label containing "departure date" made the page a `datePicker`, and legality then hid every other control from Jev. | `Change departure date` + `Add to cart` -> only the date button offered. The repo's own `flight-fixture.html` has a closed `Choose departure date` button. | Fixed: a day must parse as a date |
| 4 | Medium-high | Value spans were capped at 12 words and enumerated shortest-first up to 250, so long values were unreachable. Jev picks the closest shorter span, so a message is silently entered truncated. | A 17-word message: full text not offered, longest candidate 12 words; a 35-token goal capped at 9 words. | Fixed: utterance tails first |
| 5 | Medium | Amended goals mixed runner scaffolding ("Continue this task using the latest corrections...") and manually entered field values into value candidates, crowding out the user's words and offering text the user never said. | Code read in `VoiceControlTurnRunner.effectiveGoal` / `sourceSpans`. | Fixed: `VoiceControlGoalText.userSegments` |
| 6 | Medium | After a one-shot named press moved the screen, the loop could fall through to an unconstrained Jev request with the goal `click Save`. That is an extra cloud call that can choose an action the user never asked for. | `Save` pressed, dialog gone: router delegated to the model instead of finishing. | Fixed |
| 7 | Medium | 429/529 and dropped connections failed the turn. | Code read; Jev docs `api.md` error table. | Fixed |
| 8 | Low | Destructive/payment keyword floor missed `discard`, `uninstall`, `donate`. `submit` was deliberately left to the model (`Submit search` is ordinary by an existing test). | Code read. | Fixed |
| 9 | Low (doc/privacy) | `product.md` claimed field values never reach Jev. They do (visible values of offered fields, plus the window text summary), under the general context consent, as the contract already says. | `JevDecisionClient.wireSnapshot`. | Fixed |

## Other findings (not fixed)

- **`press return` in a chat composer sends without confirmation.** Decided
  2026-09-25: this is intended. Saying `press return` already carries the intent
  to send, so it never asks. Recorded in the contract.
- **Site macros live in core.** `VoiceControlFlightPlan` (319 lines),
  `VoiceControlWebQuery`, `VoiceControlNamedPageAction` (Gmail Compose only) and
  the Flights strings in `VoiceControlSituation` ("Where else", "Airport",
  "departure", "dates") are demo-shaped. They do not generalize, and each new
  site adds another ordered branch to the router.
- **The router is an ordered if-chain.** Behavior depends on branch order
  (when System Settings is running, `open settings` activates it before the
  current app's own Settings control is considered). There is no single place that lists routes and their
  preconditions, which is why the hijacks were easy to miss.
- **A per-step classifier is being used as a planner.** Open-ended goals run as
  repeated single-step Choices with no plan state beyond history. That is why
  Flights needed a hand-written plan. It will need one per site.
- **Target ids are walk positions.** Most of the stale-id machinery (rebinding
  by label, confirmation-stale pauses, the history leak above) exists because
  `n:<index>` is not stable across observations. A fingerprint-derived id
  (role, label, frame bucket, parent path) would remove a class of bugs.
- **Observation cost is unmeasured live.** A 1,200-node walk with 150 ms AX
  messaging timeouts; Finder-class lists already exceed the 2 s budget. There is
  no end-to-end voice-to-action latency number; only synthetic Jev calls
  (about 240 to 300 ms).
- **Evaluation gates are defined but none has passed** (`evaluation.md`). The
  decision corpus is 24 goals.
- **Doc sprawl.** 17 documents in the research folder plus a 45 KB proposal
  plan that is mostly unbuilt vision. The TCU review's promised six-document
  consolidation did not happen. `pr-description-draft.md` links to a
  nonexistent `jev-decision-architecture.md`. The active docs are consistent
  with each other on the load-bearing claims.
- **Local build environment.** The shared `.build` has a stale clang module
  cache (`MPKCrashMetadata` not found in `CrashReporter.swift`), so `swift build`
  fails in this checkout while a clean scratch build succeeds. This is not a
  code problem; clearing `.build/arm64-apple-macosx/debug/ModuleCache` should fix
  it. I did not touch it.

## Ground-up design: what I would change

The current design tries to be two products at once.

**A. Command and control with semantic targeting.** One utterance, one effect:
"click Save", "the second one", "open Safari", "type hello", "scroll down",
"press the blue submit thing", "select the Friday row". This is where Jev fits
exactly: a bounded Choice over what is on screen, answered in about 250 ms, with
local verification of the effect. It needs no site knowledge, generalizes to
every app with Accessibility, and is what macOS Voice Control does poorly
(exact names, numbered overlays). It is also the part that is closest to working.

**B. Goal pursuit.** "Find a one-way flight from Zurich to London on September
20." This is planning. A per-step classifier plus hand-written site plans does
not generalize, and each new site adds brittle code to the core.

Recommendation:

1. **Ship A first and make it the product.** Qualify it live (microphone to
   verified effect) on a fixed set of apps: Finder, Mail, Safari/Chrome,
   Notes, System Settings, Slack. Measure p50/p95 voice-to-effect latency and
   wrong-target rate.
2. **Make routing a Jev decision, not a substring chain.** Keep a small exact
   grammar first for zero-latency forms (stop, cancel, typing mode, numbers,
   yes/no, `press <key>`, `type <text>`, an exact unique control name). For
   everything else, send one fan-out request with a `route` head
   (press / fill / key / scroll / open app / open site / type / help / none),
   the existing `target` head, and `value` spans. Jev is the classifier the repo
   already pays for; substring routing is exactly the "keyword soup" `product.md`
   says not to build.
3. **Move site knowledge out of generic legality.** If Flights stays, make it a
   self-contained "site skill" (page detection, situation, plan) that activates
   only when its page is detected. `VoiceControlSituation` should know nothing
   about "Where else" or "departure date".
4. **Treat B as either explicit chains or delegation.** Support spoken chains
   ("open Safari, then new tab, then type ...") as a sequence of A-steps. For
   real goals, expose the observe/act/verify tools to the user's agent (CLI or
   MCP, per the ADR-027 north star) instead of growing a planner in core.
5. **Stable target identity.** Derive ids from the AX fingerprint so an id
   means the same control across observations, then delete the rebinding
   special cases it makes unnecessary.
6. **Cut request cost after measuring.** Send targets once (`null` criteria,
   compact state lines) and replace the consequence Choice with per-hazard
   Nouls. Do both only behind the replay corpus with a live Jev key, because
   they change model behavior.
7. **Consolidate docs** to product, architecture, contract, evidence and later.
   Archive the 45 KB plan as historical.

## Recommendations not implemented

These change model inputs or product behavior and need a live Jev key and the
replay corpus, or a product decision:

- Dedupe targets on the wire (`null` criteria) and compact the state.
- Per-hazard Noul heads for consequence.

  Both change what the model reads, and the current 0.5 gates were tuned
  against today's request shape. Do them as one experiment: replay the saved
  observation corpus against live Jev before and after, compare decision
  agreement, wrong-target rate, `input_tokens` (now recorded) and latency, and
  ship only if quality holds.
- A Jev `route` head replacing the substring router.
- Stable fingerprint ids.
- Moving Flights into a site skill (a larger refactor; its tests are about half
  of the router suite).

## What changed in this review

Code (all in `Sources/MacParakeetCore/Services/VoiceControl/`):

- `VoiceControlWebDestination.swift`: anchored `matchingGoal` (names in a
  navigation or search frame, intent phrases, a search verb whose object is
  flights; control commands and flight phrases in a goal about an email,
  message, confirmation or itinerary never route). `goalHints` became `names` plus `intentPhrases`.
  `search for` no longer means Google; `navigate to` no longer means Maps.
- `VoiceControlWebQuery.swift`: a site query needs a query verb.
- `VoiceControlCommandRouter.swift`: `browserForWebGoal` uses the anchored
  matcher; a one-shot named press that verified or moved the interface finishes.
- `VoiceControlLocalTools.swift`: `alreadyPressedByName` (verified or
  transition; includes `click Search` bound to `Search flights`).
- `VoiceControlMachine.swift`: a calendar day's label must parse as a date.
- `VoiceControlFlightPlan.swift`: parses the original goal only, and only while
  every amendment is a clarification. On `main` a correction such as `Actually Paris` was sliced
  together with the runner's scaffold into the destination field; now a
  correction, hand-edited field or uncertain effect hands the turn to Jev.
- `VoiceControlTypes.swift`: `VoiceControlGoalText` (scaffold strings and
  `userSegments`), shared by the runner and the Jev client.
- `VoiceControlTurnRunner.swift`: uses `VoiceControlGoalText`; no behavior change.
- `JevDecisionClient.swift`: `sourceSpans` from user segments, tails first
  (cue tails such as the text after `write` first, because all tails of a long
  message are quadratic in size and cannot fit any budget), within 250 spans
  and 24 KB, keeping 50 slots and 4 KB for short spans;
  label-based `Executed` history on both request shapes; retry on
  429/503/529 and dropped connections (at most 2, 150/300 ms, short
  `Retry-After` honored, a longer one fails without retry, consent rechecked, Stop cancels); `usage` decoded.
- `VoiceControlDiagnostics.swift`: `VoiceControlDecisionTrace.inputTokens` and
  `retries` (decoding stays backward compatible); keyword floor adds
  `donate`, `discard`, `uninstall`.
- `VoiceControlTraceStore.swift`: `input_tokens` / `retries` in `events.jsonl`
  and the `latest.md` Jev line.

Tests: new `VoiceControlIntentAnchoringTests` (8) and `JevClientTransportTests`
(9). Docs: subsystem README, `spec/contracts/voice-control.md`, `product.md`.

## Verification

- Focused suites (`VoiceControl|JevLean|JevClient|AXTreeWalk|ScreenTextSource|SpokenDateParser|NativeVoiceControl`,
  which includes the CLI `voice-control replay` tests): 232 tests, 0 failures,
  1 skipped (the opt-in live E2E, `MACPARAKEET_NATIVE_VOICE_CONTROL_E2E=1`).
  Run from a clean scratch build path because the shared `.build` cache is stale.
- Every fixed bug was first reproduced against unmodified `main` with a probe
  test.
- Swift 6 language-mode gate (the CI command, `MACPARAKEET_SKIP_WHISPERKIT=1
  swift build -Xswiftc -swift-version -Xswiftc 6`, in a scratch path): passes.
  It rewrites `Package.resolved`; the file was restored.
- An independent read-only review of the diff found no significant issues. Its
  one design note: a one-shot named press now finishes on an observed interface
  transition, not only a verified effect. That is intended (the single command
  is done), but if a transition ever fires on an intermediate loading state, the
  turn ends without a confirming look at the result page.
- Not run: the full `swift test` suite, any live Jev request, any microphone or
  GUI run. The fixes do not touch shared code outside the Voice Control
  directory.
- Jev usage in this review: none. Classification of findings was done by
  reading code and running local tests; no request was sent to Jev.
