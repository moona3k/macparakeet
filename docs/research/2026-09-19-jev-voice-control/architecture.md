# Architecture

Jev is a **judge of a bounded next move**. The host owns policy, permissions, arithmetic, URLs, execution, and the completion receipt. A generative worker, if used at all, writes artifacts (rewrites). Jev does not choose the route or authorize the action. It can choose among observed landings; it does not verify an arbitrary goal.

```
Observe Accessibility
  → Situation (plain / suggestionPicker / datePicker)
    → Compile a host tool if unique
      → several names     → numbered local pick
      → several landings  → one Jev Choice over those ids
      → nothing compiles  → one small question set: kind / target / focused value (no keystrokes)
        → execute once → verify on a fresh snapshot
```

`finished` from Jev is a judgment over the text we sent, not a receipt. “The screen changed” is not “search completed.” Accessibility postconditions are.

## Outcomes, not steps

Jev is strong at picking among named options given evidence. It is weak at simulating a multi-step transition function.

| Ask | What you are really asking |
|---|---|
| “Find flights” as an agent loop | Plan and execute. The host owns this. |
| “Which button to press” | The next micro-step. Still a simulation. Leftover on generic pages only. |
| “Where should this piece land” | An observed landing. The host compiles the press. |
| “Did we win?” | Unbounded completion. If we could compile the goal to a check, we would run the check. Jev picking `finished` over truncated labels is not that check. |

Competing picker rows — London, United Kingdom vs London, Ontario — are landings: *after the host acts, this label is the selected result.* Unique Zürich stays local. Generic footer links are not landings; their post-state is unknown.

Execute one compiled landing, re-observe, offer a new independent Choice. The graph lives in the host.

## Situation and legality

`VoiceControlSituation` is recomputed every snapshot from Accessibility facts: `plain`, `suggestionPicker`, or `datePicker`. Code lists **legal events**. Unique events skip the model. Several become one `outcome` Choice plus `insufficient_evidence` / `clarify`. Zero (no domain machine) is unconstrained Jev on legality-filtered page controls.

Return is not a landing. Escape dismisses an overlay. Return and Search are not enabled while a suggestion or date picker is open. Overlay detection requires the `Where else?` chrome that only the open overlay shows — a focused row with a comma in its label (a Gmail subject, a Finder path) is not a picker, and airport names on a results list are the form, not a picker.

Jev never receives `role=url` destinations. Code owns allowlisted sites.

## Host vs Jev

| Step | Owner |
|---|---|
| Activate a browser for a web goal | host |
| Open an allowlisted site | host |
| Unique named press, type, replace, scroll, keys | host — see [tools](tools.md) |
| Flights fill / unique city / overlay Escape / Search | host `VoiceControlFlightPlan` |
| Competing unfocused city rows | Jev Choice over those events |
| Pay / delete / send | confirm, then host |
| Unfamiliar in-page control | Jev: `kind` (press / fill / scroll / finished / none) + one `target` head over legality-filtered controls + `value` only for a focused field; gate `min(kind, target)`; pages over 200 controls truncated by priority, never failed |

Malformed, timed-out, or low-confidence Jev answers execute nothing. Never substitute the first candidate.

## Identity across observations

An Accessibility id belongs to exactly one snapshot. After model latency or a 20-second observation window, re-observe and rebind by unique role+label. Numbered picks store id **and** label; a reused id with a different label is stale. Confirmation that outlives the snapshot reobserves rather than failing closed on a dead handle.

A stale throw is not a dispatched duplicate. Consume a decision once, before mutation. Do not retry an uncertain effect.

## Types

| Type | Job |
|---|---|
| `AXTreeWalk` / `AXTreeSource` | Pure pruning over an injected tree; fake-tree tests; off-screen pressables kept separately |
| `VoiceControlSituation` | Recomputed from AX facts |
| `VoiceControlEnabledEvent` | One legal action plus criteria |
| `VoiceControlLocalTools` | Compile unique names, keys, skip-if-typed |
| `VoiceControlSpokenPick` | Isolated spoken index into a numbered list |
| `VoiceControlConsequencePolicy` | Pay / delete / send; never lowered by a model |
| `JevDecisionClient` | Strict Choice validation; fail open |

What we did not build: a seven-state universal Mac graph, Score-ranking every widget, a generative worker in the click loop, CDP, or treating Jev `finished` as a receipt.
