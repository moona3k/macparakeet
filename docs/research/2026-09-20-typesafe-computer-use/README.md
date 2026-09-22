# typesafe-computer-use vs. MacParakeet Voice Control (PR #1104)

**Date:** 2026-09-20. **Kind:** source review and design comparison. No reference code was executed; no production code was changed.

- Reference: [awlevin/typesafe-computer-use](https://github.com/awlevin/typesafe-computer-use), local checkout `references/typesafe-computer-use/` (gitignored), commit `cc7b5066ae1a07b5e3182e8f87a9b5b6dfdcffc1` (2026-09-18), MIT, Python 3.12, ~2,450 source lines, 139 tests.
- Ours: [PR #1104 "Add experimental Voice Control: Jev judges landings, MacParakeet acts"](https://github.com/moona3k/macparakeet/pull/1104), reviewed at pushed head `1ebe572b` on `feat/jev-voice-control`. ~4,600 Swift lines in `Sources/MacParakeetCore/Services/VoiceControl/` + `VoiceControlCoordinator.swift`, 136 focused tests (PR description). Hosted `swift-test` passed on the head (51m47s); CodeRabbit passed. The local worktree `macparakeet-jev-voice-control` is two commits ahead (`bfee6d6c` numbered picks, `1cc0aeb8` local tools) with an uncommitted docs consolidation that removes ~4,600 lines of research notes. Those unpushed changes are noted where they matter but were not the review target.

## Verdict

**Do not revamp. Transplant four subsystems.**

`typesafe-computer-use` (TCU) is an autonomous, typed-goal, screen-driving CLI. It has no revocable authority, no confirmation for consequential actions, no receipts for presses, and it sends the final screenshot to a frontier model. Adopting its loop wholesale would delete everything ADR-033 exists to guarantee. Our runner (`ActionAuthority`, consume-once, receipts, no-replay of uncertain effects, pay/delete/send gate, consent, correction) is stronger than TCU and stronger than every other reference we have reviewed.

What TCU does better is everything *around* the decision:

| Area | TCU | PR #1104 | Adopt? |
|---|---|---|---|
| Perception sources | Vision OCR + AX, merged; off-screen pressables offered separately | AX only; visible-only | **Yes**: AX walk design now; local OCR as secondary source later |
| AX walk | Pure BFS over injected callables; 297 lines of tests against dict trees; 4,000 nodes / 0.6 s | DFS inlined in a 160-line `observe()`; 62 lines of adapter tests; 600–800 nodes / 2.0 s | **Yes** |
| Decision payload | 3–4 mutually exclusive Choices, one `item` head, `where`/`role`/`when` hints per option | Unconstrained path: `operation` + one `target_*` head per operation + one `value_*` head per editable target (≤24 × ≤250 spans) + `consequence` + `direction` + `key` | **Yes**, for the unconstrained leftover only |
| Confidence gate | `min(kind, item)` only when a target is named; 0.4; recoverable heads excluded | 0.5 per head independently; 0.8 for consequence | Partially |
| Free text | Writer LLM composes field values; Noul verifies; clear on <0.5 | Exact utterance spans only; rewrites via consented Transforms provider with preview | **No**, keep ours |
| URLs | Catalog + writer-proposed `https` URL, validated | Allowlist only; Jev never sees `role=url` | **No**, keep ours |
| Execution verification | Text: AX readback → keystroke fallback. Press: none. | Fingerprint, foreground, window identity, readback, postconditions, transition evidence, four receipt states | Keep ours |
| Authority / safety | Dry-run default, mouse-corner abort, passwords never typed | Revocable authority, consume-once, no-replay, confirmation, secure-field exclusion, manual-takeover detection | Keep ours; adopt **dry-run** |
| Observability | Per-step raw + annotated capture, exact payload, every probability, per-phase timing with mean/max, `--image` replay, `clicker-inspect` | `latest.md` wide event, `latest.json`, `events.jsonl`, per-stage durations; no probabilities, no replay, no per-turn timing summary | **Yes**, minus screenshot persistence |
| Dates | Deterministic parser; "dated 2026-10-13 (in 27 days)" hints on items and neighbours | Token match of the utterance against calendar-day labels | **Yes** |
| Budget overflow | Drop faintest OCR-only items first; never drop a control; cap 255 | Throw `contextTooLarge` at 200 targets, 24 editable | **Yes** |
| Loop stop rules | `done`/`none`, confidence, 2 no-ops, step limit, then writer answer | `finished`/`clarify`, budget, 2 no-progress, receipts, confirmation expiry | Ours is a superset; skip the writer answer |
| Module shape | 12 files, one responsibility each, platform adapter isolated in `macos.py` | Adapter 700 lines (walk + policy + 5 executors + verification); runner 570; coordinator 730; router 300-line if-chain | Decompose, not rewrite |

The rest of this document explains each row and ends with a sized adoption plan.

## 1. What typesafe-computer-use is

`clicker "<goal>" --act` runs up to 100 steps. Each step:

```
screencapture → Vision OCR (cropped to frontmost window + menu strip; only changed 256 px tiles re-read)
AX walk       → labelled on-screen controls + labelled off-screen pressables
merge         → one numbered item list in reading order, each tagged ocr | ax | ax+ocr
focused field, frontmost app + pid, browser tab URL, clock, date hints
      ↓
one System One request: Choice kind · Choice item · Choice site · [Choice offscreen]
      ↓
deterministic handler → history line → sleep → next step
```

Anchors (all in `typesafe_computer_use/`):

- `runner.py:135–182` step; `runner.py:184–223` stop rules (`done`/`none`, confidence < 0.4, two consecutive no-ops or repeats, step limit).
- `decide.py:152–192` the request; `decide.py:112–149` `Decision.confidence` = `min(kind, item)` only when a target is named, with the comment that a split on `site` "must not stop the run" because every browser page is recoverable.
- `perception.py:75–106` merge of OCR blocks and AX controls; `perception.py:133–197` the tile-diff OCR cache; `perception.py:489–520` `merge_with_origins` keeps the AX handle through renumbering.
- `macos.py:359–432` `walk_actionable`: BFS over four callables (`children`, `attrs`, `actions`, `clock`), so pruning is platform-free and tested against plain dicts (`tests/test_ax.py`, 297 lines).
- `actions.py:48–61` `click_item`: `AXPress` first, pixel click at the box centre as fallback; `actions.py:79–95` `fill_field`: `AXValue` set with readback, keystrokes as fallback.
- `writer.py` the only generation: field text (`{fill, text}`), URL for `site: other` (`{ok, url}`, must be clean `https`), and the final answer from a screenshot + OCR text using a stronger model.
- `report.py` annotated PNG, exact payload dump; `timing.py` phase stopwatches; `runner.py:225–247` `answers.json` with every probability.

Author's own caveats (README "Why" and "Known limits"): "Every piece of reasoning the frontier model does for free has to be rebuilt here as deterministic state"; two identical labels split the vote; icon-only buttons in canvases/terminals/Spotify reach neither source; "using the machine during an `--act` run fights it for focus and the cursor."

## 2. What PR #1104 is

Speech-first, native, bounded, consented. The pipeline (`VoiceControlCoordinator` → `VoiceControlTurnRunner` → `VoiceControlCommandRouter` → `JevDecisionClient` → `NativeVoiceControlAdapter`):

```
local STT → committed transcript
  → router: exact grammar · allowlisted sites · Flights plan · web query · named page action · app activation
     → unique compiled action           → execute locally
     → several enabled events           → one Jev `outcome` Choice over those ids (+ insufficient_evidence, clarify)
     → nothing compiles                 → unconstrained Jev on legality-filtered targets
  → runner policy (budget, duplicate identity, uncertain effects, consequence → confirmation)
  → adapter: revalidate snapshot id / window / foreground / fingerprint → act once → receipt
  → re-observe
```

Strengths TCU does not have, with anchors at the pushed head:

- `VoiceControlTypes.swift:68–81` `ActionAuthority` with synchronous `perform`; `VoiceControlTurnRunner.swift:550–571` the gate that revokes in-flight observation/decision tasks.
- `VoiceControlTurnRunner.swift:453–503` consume-once dispatch, `EffectIdentity` / `DispatchIdentity` over semantic pre-state (role, label, value, focus), `uncertainEffects` never replayed, `transitionObserved` on a consequential control pauses instead of continuing.
- `NativeVoiceControlAdapter.swift:219–440` execution with `observationExpired` (20 s), `windowChanged`, `targetChanged` (fingerprint), AX readback for text (6 × 60 ms), postconditions for checkbox/radio/menu, transition evidence for generic presses, marked `CGEvent`s posted to the pid.
- `JevDecisionClient.swift:292–300` strict response validation (offered keys, probability keys, argmax, sum ≈ 1); fail open on anything else.
- Consent checked before and after the request; no audio, screenshot, field values or remote bodies in traces; Keychain key; secure fields excluded at observation (`isSecure`).
- Correction (`revise`, `clarify`, "the other one"), manual takeover (`absorbManualChanges`), confirmation with 20 s expiry.

## 3. Where TCU's design is better, and what to take

### 3.1 Perception: make the walk pure, then widen it

**Problem in ours.** `NativeVoiceControlAdapter.observe()` (`NativeVoiceControlAdapter.swift:56–217`) interleaves AX IPC, pruning policy, target construction, browser heuristics and app/URL injection in one method. It cannot be unit-tested without a live app, which is why `NativeVoiceControlAdapterTests.swift` is 62 lines of static-helper tests while the walk itself is untested. Per node it issues roughly fifteen `AXUIElementCopyAttributeValue` round trips (role, hidden, title, description, help, position, size, value, enabled, action names, two `IsAttributeSettable`, subrole, selected text, URL, children) and `isVisible` calls `CGGetActiveDisplayList` for every node (`NativeVoiceControlAdapter.swift:664–667`). The deadline is 2.0 s at 600–800 nodes; TCU walks Chrome's 172 controls in 0.59 s at a 4,000-node cap.

**TCU's shape.** `walk_actionable(root, children, attrs, actions, w, h, node_cap, time_cap, offscreen_cap, clock)` returns `(found, offscreen, capped)`. Rules, each with a test:

1. Prune any subtree whose real frame is wholly off the display (Notes rows "200 screens down", Chrome nodes parked above the viewport). Zero-size frames are containers and are never pruned.
2. Drop nodes under 4 pt on a side (Chromium slivers for scrolled-out nodes).
3. Skip `AXMenu` subtrees (thousands of zero-size items behind a closed menu).
4. Skip nameless `AXGroup` even when pressable (Chromium layout boxes).
5. Label recovery: a bare child (usually a decorative `AXImage`) borrows its parent control's label; `AXCell`/`AXRow` take the first shallow `AXStaticText`. Emit once per label so a parent and its decorative child are not two options.
6. Dedupe by `(role, label, rounded frame)` and by element identity, so an app that lists a control twice is walked once.
7. Keep labelled, `AXPress`-able nodes that failed 1–2 in a separate `offscreen` list (cap 120). `AXPress` does not need visibility; Notes rows, Dock items and scrolled-out links accept it.
8. Stop at node or time cap and say so.

**Adopt.** Extract an `AXTreeWalk` (pure struct or free function) in `MacParakeetCore` over an injectable source:

```swift
struct AXNodeFacts { let role: String; let label: String; let frame: CGRect?; let actions: Set<String> }
protocol AXTreeSource { func children(of: Node) -> [Node]; func facts(of: Node) -> AXNodeFacts }
```

`NativeVoiceControlAdapter.observe()` becomes: acquire process → `AXTreeWalk.run(source: LiveAXSource(app), display: …, caps: …)` → `TargetBuilder` (our existing role/operation/secure/browser rules) → inject apps and destinations. Port rules 1–8 and their tests (`test_ax.py` maps almost one-to-one onto a Swift fake tree). Read expensive attributes (`settable`, `selectedText`, `URL`, `subrole`) only for roles that can use them; read display bounds and the window frame once per observe. Consider `AXUIElementCopyMultipleAttributeValues` for the hot set. This is the "batched AX reads" item already listed in the branch's next-steps note, with a concrete design.

**Then widen.** Offer `offscreen` controls as targets with a distinct operation or flag so the router can compile "click Note 900" without scrolling, and so Jev can be offered them as a separate head, never mixed with visible items (TCU's reason: nothing on screen points at them and a pixel click would land elsewhere). Our receipts and `isVisible` guard in `execute` need a matching "offscreen press is verified only by postcondition" rule.

### 3.2 Perception: local Vision OCR as a secondary item source (later, flagged)

TCU's biggest capability gap over us: it can act on text no accessibility tree exposes (terminal rows, Spotify's CEF shell, canvases, apps with sparse AX). Its OCR is Apple Vision on-device, cropped to the frontmost window plus the menu strip, and re-read only where 256 px tiles changed (`perception.py:133–197`, `tests/test_ocr_cache.py`, 320 lines). It merges an OCR block into an AX control when the boxes overlap ≥ 50 % of the smaller box and the texts match (`box_overlap`, `texts_match`), so the same thing is one option with source `ax+ocr` and the AX handle is kept for the press.

This is compatible with our privacy posture: pixels never leave the Mac; only the resulting text labels would go to Jev under the existing consent, exactly as AX labels do now. What is *not* compatible is TCU's persistence of raw and annotated screenshots to `runs/` and its final-answer call that uploads the capture to Anthropic. Adopt the source, not the storage or the answer phase.

Recommended shape: `OCRItemSource` behind a DEBUG flag, producing `VoiceControlTarget`s with `role: "text"`, `operations: [.press]`, and an adapter-private pixel centre. `execute(.press)` on an OCR-only target posts a marked click at that point and returns `.unknown` unless transition evidence changes, which is already how generic presses are received. Merge with AX by TCU's overlap rule. Keep it off the Flights acceptance path; the payoff is native apps with weak AX and "read the number on screen" style utterances.

**Decision (owner, 2026-09-20): adopt.** And widen the framing: OCR is a second source of *state*, not only of clickable text. Prices, dates, counts, status lines, result rows and list contents are frequently absent from AX, truncated, or exposed as unlabeled static text. Window-scoped OCR text in reading order (with TCU's date hints applied) should feed the snapshot `summary` under the existing cloud-context consent, so Tier 2/3 Jev questions and local matchers see what the user sees. Two outputs from one pass: text-only targets (pixel-click fallback, `unknown` receipt unless transition evidence changes) and screen text as state.

This needs an ADR-033 amendment: `later.md` on the branch lists "OCR recovery" as later and "OCR as a primary grounder" as out of scope. Proposed wording: "AX first; on-device Vision OCR may add text-only targets and window-scoped screen text to the observation; pixel click only as fallback; OCR text goes to Jev only under the existing cloud-context consent; no image is persisted or transmitted by default." Redaction for OCR text: same word filter as secure labels, drop lines inside secure/excluded element frames, keep the 4,000-char summary cap, local session log only, never in shareable diagnostics.

### 3.3 Decision payload: mutually exclusive heads for the unconstrained leftover

**Problem in ours.** `JevDecisionClient.decide(goal:snapshot:history:)` (`JevDecisionClient.swift:39–187`) builds, for the no-machine case: an `operation` head, one `target_<op>` head per operation present, one `value_<targetID>` head for every editable target (up to 24) each offering up to 250 utterance spans, plus `consequence`, `direction`, and `key`. A twelve-word utterance on a page with ten text fields sends ~30 questions and several thousand criteria strings; the 120 KB cap (`JevDecisionClient.swift:134`) will trip on ordinary forms. `setValue` vs `insertText`, `press` vs `select`, and `finished` vs `clarify` vs per-head `none` have overlapping descriptions. TCU's README states the lesson plainly: "Every stall found while building this came from two options that meant the same thing. Confidence measures concentration, so overlapping options always read as doubt. Keep the action set mutually exclusive."

**TCU's shape** (`decide.py:22–86`): `kind` over a fixed vocabulary (`click_item`, `press_offscreen`, `use_browser`, `type_text`, `press_enter`, `press_escape`, `scroll_down`, `scroll_up`, `wait`, `done`, `none`); one `item` head over all items with criteria like `button 'Share' (top-right)`; `site`; optional `offscreen`. The state carries the same items with `where`, `role`, `when` hints and the last eight history lines. Values, when needed, are a second small call.

**Adopt** for the unconstrained path only (the `outcome` Choice over enabled events is already right and should not change):

- `kind`: `press`, `fill`, `scroll`, `key`, `activate`, `finished`, `none`. Merge `select` into `press` and `insertText` into `fill` at the wire; keep them distinct in `VoiceControlOperation` and let the router/adapter pick the concrete operation from the target's capabilities.
- `target`: one head over all legality-filtered targets, criteria `"<role word> '<label>' (<region>[, focused][, has value][, dated …])"`. Region from the AX frame the adapter already has (`top-left` … `bottom-right`). This directly addresses TCU's and our shared "two identical labels" weakness.
- `value_<id>`: only for the focused editable target, or none if no editable target is focused; otherwise a second request after `kind == fill` chooses the target. Two ~250 ms calls beat one 120 KB call that fails validation.
- Confidence gate: `min(kind, target)` when `kind` names a target; `kind` alone otherwise. Do not gate on `consequence` confidence. Today a `consequence` answer under 0.8 becomes `.unknown` (`JevDecisionClient.swift:185`); policy returns `.ordinary` for presses regardless (`VoiceControlDiagnostics.swift:241–244`) but an unconstrained Return key outside a search field still reaches "Allow this action with an unverified consequence" (`VoiceControlDiagnostics.swift:240, 247`). Local policy already decides pay/delete/send; the model head is advisory and should not add a prompt.
- Factor the shared request/validate/decode block out of `decide` and `choose` (`JevDecisionClient.swift:128–156` and `210–235` are the same ~30 lines).

Measure before/after on saved snapshots (see 3.5): payload bytes, latency, `invalidResponse`/`contextTooLarge` rate, and clarify rate.

### 3.4 Deterministic dates

`dates.py` parses `Oct 13`, `13 Oct 2026`, `2026-10-13`, `10/13/2026` and ranges, assumes current-or-next year, and attaches `dated 2026-10-13 (in 27 days)` to any item containing a date and `near a line dated …` to items on the same row (`date_hints`, 45 lines of tests). Jev then compares offsets instead of doing calendar arithmetic, which the PR description itself lists as a Jev weakness.

Ours: `VoiceControlFlightPlan.bestDateSuggestion` (`VoiceControlFlightPlan.swift:270–281`) requires every utterance token to appear in the calendar button's label, so "next Friday" or "the 20th" cannot match, and "20" matching "2026" is called out in the findings note as a known trap.

**Adopt** a `SpokenDateParser` in Core using `NSDataDetector(types: .date)` plus a small relative-phrase table (`today`, `tomorrow`, `next <weekday>`, `the <ordinal>`), resolving to an ISO date. Annotate calendar-day targets with `dated <iso> (in N days)` in both local matching and Jev criteria. This also serves Calendar/Reminders and is testable in isolation.

### 3.5 Observability, replay and dry-run

TCU writes per step: the raw capture, an annotated capture (blue OCR, orange AX, red chosen, green focused field), `step-NNN-payload.txt` with the exact `state` and every criteria dict, and `step-NNN-answers.json` with every probability, the off-screen list, and `timing` per phase. `run.json` ends with mean/max per phase. `--image runs/<ts>/step-003-raw.png --app … --url …` replays a saved capture through the live decision path without touching the screen; `clicker-inspect` does a 3-2-1 countdown, captures, and opens the annotated screen plus the payload. `--act` is opt-in; the default is a one-step dry run that prints "would do".

Ours records `VoiceControlTraceRecord`s with stage, outcome, duration, candidate count, `decisionScore` (the winning confidence only), target id, clipped label and key name (`VoiceControlTurnRunner.swift:183–205`); `latest.md`/`latest.json`/`events.jsonl` via `VoiceControlTraceStore`. There is no probability distribution, no request payload, no replay, no per-turn timing summary, and no way to run observe → route → decide without executing.

**Adopt**, within our redaction rules (no audio, screenshots, field values, credentials, remote bodies; labels allowed locally, stripped from Copy diagnostics):

1. Record the full `probabilities` map per head and the offered criteria keys in the local session log. This is what turns "Jev picked London, Ontario" into a diagnosable event.
2. Persist a redacted snapshot fixture per observation in the session folder: `id`, `contextID`, `applicationName`, `targets[]` with `id/role/label/operations/isFocused/valueIsComplete/isNavigation` and value **omitted**, `summary` clipped. `latest.json` already carries labels, so this widens nothing.
3. `swift run macparakeet-cli voice-control replay <snapshot.json> --goal "<text>" [--history …]` runs `VoiceControlCommandRouter` + `JevDecisionClient` and prints the compiled action or Jev distribution. This is the offline repro path for the Flights overlay stall, and the eval workbench `later.md` wants without shelling a key into a Unix filter.
4. `--dry-run` on the inbox `command.json` and the panel: observe, route, decide, report "would do: press 'Search flights'" with actor and route, execute nothing. Same code path with a `NoopAdapter.execute`.
5. Per-turn timing line in `latest.md`: `observe 0.41s  route 0.00s  jev 0.24s  execute 0.13s  verify 0.36s  total 1.14s`, plus mean/max over the session. Stage durations already exist; only the summary is missing.

The annotated-screenshot artefact is the one piece worth doing only behind an explicit local-debug switch, written to the ignored `diagnostics/` path and never referenced from Copy diagnostics.

### 3.6 Budget overflow

TCU trims to the 255-option ceiling by dropping the faintest OCR-only items first and never drops a control (`kept_by_budget`). We throw `contextTooLarge` at 200 targets or 24 editable targets, ending the turn with "Narrow the task or focus a smaller window." Prefer prioritised truncation: keep focused, editable and pressable-with-label targets; drop duplicates by `(role, label)`, then static text, then the farthest-from-focus. Report `truncated: true` in the snapshot and trace so Jev's `insufficient_evidence` is interpretable.

## 4. Where ours is better, and why it stays

- **Generated values and URLs.** TCU's writer composes field text from the goal and nearby screen text, and proposes URLs for unknown sites. In a voice product the user has said the words; exact source spans preserve spelling, punctuation and intent, and never leak screen content into a generation prompt. Keep spans; keep the allowlist; keep rewrites in the consented Transforms path with preview.
- **Receipts.** TCU's press has no postcondition; a click on "Buy" is a history line. Our `verified` / `transitionObserved` / `unknown` / `failed` with consume-once and no-replay is the contract that makes a voice loop safe to run against a real browser.
- **Authority.** TCU cannot be stopped mid-action except by Ctrl-C or the mouse corner, and "using the machine fights it". `ActionAuthority`, `pauseForManualInput`, `absorbManualChanges` and the `GUIMutationArbiter` lease are the correct model.
- **Consequence policy.** TCU has none; it relies on the writer refusing credentials. Our pay/delete/send gate with local evidence that a model cannot lower is right.
- **Situation + enabled events.** TCU asks the model "which kind of action" every step. Our "code lists legal events; unique executes; several become one `outcome` Choice" removes the model from most steps and makes the recorded stalls illegal rather than unlikely. Keep it; make the Flights strings a domain plugin rather than the body of a generic `VoiceControlSituation`.

## 5. PR #1104 review notes

Independent of the comparison, findings from reading the pushed head:

**Blocking for merge**

- The branch carries ~90 research documents (+15,008 lines total). The worktree already deletes most of them uncommitted (75 files, −4,605). Commit and push that consolidation before merge so the PR reflects the six-document structure (`product`, `architecture`, `tools`, `evidence`, `later`, `references`).
- Worktree commits `bfee6d6c` (numbered picks) and `1cc0aeb8` (local tools) change router and adapter behaviour and are not on the remote. Push, then re-run hosted CI; the current green run is for `1ebe572b`.

**Should fix on this branch or immediately after**

- `NativeVoiceControlAdapter.isVisible` calls `CGGetActiveDisplayList` per node and re-reads the window frame per node. Hoist both to once per observe. Cheap, and directly shortens the 2 s observation ceiling.
- `JevDecisionClient`: duplicated request/validate/decode block; per-target `value_*` heads multiply payload size (3.3). Extract `send(state:questions:)`.
- `VoiceControlCommandRouter.decide` is a ~200-line if-chain with route-specific completion rules (`result(_:)`, `isDirectCommand`). The worktree's `VoiceControlLocalTools` is the right direction; finish it so each tool is `match(goal, snapshot) -> compiled action?` and the router is a table.
- Observe path worst case: 6 × 180 ms acquisition retries + Chromium handshake up to 8 × 150 ms + 2 s walk ≈ 4.3 s before a decision. Measure with the timing line (3.5) before tuning.
- `VoiceControlSituation.classify` hard-codes `"Where else"`, `"departure date"`, `"Airport"`. Correct for the acceptance path, misnamed as a generic type. Move the predicates into `VoiceControlFlightPlan` or a `DomainSituationProvider` so a second site does not edit the core enum.
- Adapter walk is untestable (3.1). The single highest-leverage refactor on the branch.

**Good, keep**

- `ActionAuthority.perform` and the gate; consume-once before dispatch; `uncertainEffects`; strict Choice validation; consent checked twice; selected text stripped from the Jev wire; local-only logs with a content-minimised shareable copy; `.selectedLabel` postconditions promoting a transition to a receipt.
- Honest evidence table in the PR body: live ZRH→LON results and the integrated microphone are stated as not demonstrated.

## 6. Adoption plan, sized

**Status 2026-09-21:** all eight items merged — 1–2 in #1107, 3–4 in #1108, 5–7 in #1109, 8 in #1110 (opt-in second source); region hints (3.3) in #1112; picker-chrome fix in #1111. Live and corpus measurements are recorded in the plan (`plans/active/2026-09-20-voice-control-observability-perception-decision.md`) and in `docs/research/2026-09-19-jev-voice-control/evidence.md`.

Ordered by value over cost. Each item is independent; none requires the others, and none changes the enabled-events doctrine.

| # | Item | Size | Where | Verifies |
|---|---|---|---|---|
| 1 | Probabilities + offered keys in local trace; per-turn timing line; redacted snapshot fixture per observation | S (~150 lines) | `VoiceControlTraceStore`, `VoiceControlTurnRunner.record`, `JevDecisionClient` | `VoiceControlTraceStoreTests`; shareable copy still omits labels |
| 2 | `replay` CLI subcommand and `--dry-run` through a `NoopAdapter` | S–M (~250 lines) | `Sources/CLI`, `VoiceControlCoordinator.handleInbox` | Replay of the recorded overlay stall reproduces `duplicate_blocked` offline |
| 3 | Pure `AXTreeWalk` over `AXTreeSource`; port TCU pruning rules 1–8 and tests; hoist display/window reads; batch hot attributes | M (~400 lines + ~300 test) | `NativeVoiceControlAdapter` split into `AXTreeWalk`, `LiveAXSource`, `TargetBuilder` | Fake-tree tests; observe time on Chrome/Finder/Notes recorded in the timing line |
| 4 | Off-screen pressables as targets with postcondition-only receipts | S (~120 lines) after 3 | walk + adapter `execute(.press)` | Notes row / Dock item press in a fixture app |
| 5 | Unconstrained request in TCU shape: `kind` / `target` / focused `value`; `min(kind, target)` gate; no consequence-confidence prompt; shared `send` | M (~250 lines net negative) | `JevDecisionClient` | Replay corpus from 2 shows payload bytes, latency, clarify rate before/after |
| 6 | `SpokenDateParser` + `dated … (in N days)` hints on calendar targets | S (~150 lines) | new Core type; `VoiceControlFlightPlan`, criteria builder | Unit tests; "next Friday" resolves on a Flights calendar fixture |
| 7 | Prioritised target truncation instead of `contextTooLarge` | S (~80 lines) | `JevDecisionClient`, snapshot `truncated` flag | Fixture with 300 targets decides instead of failing |
| 8 | **Decided.** `OCRItemSource` (Vision, window-cropped, tile-cached): text-only targets with pixel-click fallback **and** window-scoped screen text into the snapshot `summary`; ADR-033 amendment; OCR redaction rules | L (~700 lines + tests) after 3 | new Core service; `TargetBuilder` merge; summary builder; adapter press fallback | Terminal/Spotify fixture yields targets AX does not; Flights results fixture shows prices/dates in `summary`; no image persisted by default; shareable diagnostics unchanged |

Items 1–2 are the multiplier: every later change becomes measurable on saved snapshots instead of live Flights runs. Item 3 is the structural fix the PR most needs. Items 5–7 are decision quality. Item 8 is the only one that extends scope, and it is the one capability TCU has that we structurally lack.

## 7. Things not to take

- The writer-in-the-loop for field values and URLs.
- Screenshot persistence by default, and any screenshot leaving the Mac.
- The final "answer" phase that uploads the capture to a frontier model. A local templated status line (`later.md`, `AVSpeechSynthesizer`) is the equivalent for us.
- `done`/`none` from the classifier as a stop signal without a receipt. Ours already refuses this.
- The mouse-corner abort and Ctrl-C as the only stop. Ours has authority revocation and Stop.
- Python/pyobjc packaging; nothing here needs a second runtime.

## 8. Method

Read every module of `typesafe-computer-use` at the pinned commit and its test files; read the PR's core Swift sources, ADR-033, the contract, the decision-architecture and native-direction notes, and the worktree's in-progress `architecture.md`, `tools.md`, `references.md`, `later.md`. Pulled PR metadata, checks and review state with `gh`. Counted tests with `rg`. No models, apps, or accessibility APIs were invoked; latency and cost figures are quoted from each project's own notes and are not independently reproduced. Jev was not used for any step of this review.
