# Jev open-source ecosystem refresh (2026-10-09)

Scope: public repos and docs that use Jev (TypeSafe AI's System One model, `jev-1.13.0`) or its wire format, found with `gh search repos`, `gh search code`, curated "awesome" lists, web search, and the TypeSafe GitHub org. This report follows the 2026-09-19/20 survey in [`../2026-09-19-jev-voice-control/references.md`](../2026-09-19-jev-voice-control/references.md) and covers what is new since then.

Method and trust notes:

- New repos were shallow-cloned under `macparakeet/references/` (gitignored). Updated versions of previously surveyed repos were cloned next to the old snapshots as `<name>-2026-10-09`, so the 09-20 snapshots stay as they were. Nothing from any repo was run, built or installed. Instructions inside repos were treated as data.
- Every latency, cost and accuracy figure below is **author-reported** unless marked otherwise. None was reproduced here.
- Star counts and dates come from `gh api` on 2026-10-09. Several projects have star counts that look implausibly high for their age (for example Laya at about 32k stars in three weeks). Read stars as noise, not as evidence of quality.
- No Jev calls were made for this research. All classification and ranking of repos was done by hand.

## Summary: the most important new patterns

1. **The ecosystem is large now, but the shared design has converged.** One `gh search repos` sweep found about 300 Jev-related repos created after 2026-09-15. At least 10 awesome-lists index 500 to 1,200 entries each. Among computer-use and voice repos, most independently reached the same loop MacParakeet already uses: AX tree, then a closed Choice over operation and target, then a host action, then verification. What has changed since the last survey is the *guard rails* around that loop.
2. **Veto Nouls asked in the same request as the action.** These are the clearest new pattern:
   - `goal_reached` / `goal_done`
   - `stuck`
   - `wrong_surface`
   - `needs_text`
   - `is_destructive`
   - a `holds` plus `contradicted` pair for completion claims

   A model-chosen DONE is accepted only when an independent Noul agrees. Examples: jev-for-chrome vetoes DONE when `goal_done` is below 0.5; Sedum passes a claim only at `holds` ≥ 0.75 with `contradicted` < 0.5; chris-wozniczek/jev-voice-control requires `goal_reached` ≥ 0.7. After a veto, DONE is removed from the next request and Jev is told why.
3. **"Already tried on this screen" as state, not just a replay block.** typesafe-computer-use now puts the actions already tried on the current screen signature into the state. Both its `kind` and `item` instructions say to avoid them. This steers the model away from a failed target, which MacParakeet's no-replay rule alone does not do.
4. **Richer stall detection.** The updated repos now look for patterns beyond two unchanged observations in a row:
   - cumulative revisits of the same state (A→B→A)
   - the same action three times in the last six steps even when the screen changed (menu toggling)
   - ambient-change filters that ignore clocks, progress bars and sliders
   - fingerprints over every control, not only the ones sent to Jev
5. **Margins against an explicit `none`, and measured thresholds.** Several projects calibrated thresholds on real cases and published the trade-off:
   - **dwim:** 0.5 alone ran 65/72 intents with 3 misses; 0.70 plus a 0.15 lead ran 47/72 with none.
   - **jevcast:** gates on a lead over `no_match`.
   - **mikakostoev:** accepts lower confidence when P(none) ≤ 0.1.
   - **hermes-jev-skills:** calibrated a 0.65 floor on trap cases.

   TypeSafe's own WorkflowEvals code uses named threshold profiles ("balanced" and "cautious") and cumulative Score probabilities.
6. **Ways around the candidate cap.** Several repos stop truncating to N controls:
   - narrowing in stages: category, then group, then item (jev-cua, jevcast)
   - top-3 finalists from each split, re-asked (computah)
   - group-of-30-then-element above 240 options (fastbrowse)
   - per-control relevance Nouls (fastbrowse)

   The official "skill suggestion" cookbook shows the same pattern: rank the whole set with one Choice, then re-check a shortlist of 3 with richer text.
7. **Speech timing.** Several voice repos commit early only under strict conditions:
   - only closed-set commands
   - tool probability ≥ 0.9 and argument probability ≥ 0.85
   - the same answer on two consecutive partials
   - `cut_off` below 0.7

   Free text never fires early. One controlled study (Veris) found that semantic end-of-turn detection cut interruptions from 52% to 11%, but median reply latency rose from 2.1 s to 4.6 s. Hold-to-talk does not need it.
8. **Local servers that speak the `/v1/systemone` format are now real but uneven.**
   - **Kev** (Qwen-based, Apache-2.0): Kev-4B is close to Jev on its author's index. It takes about 720 ms on a new state on an M5 and 8.4 GB of memory.
   - **Laya** (ModernBERT, 421M): very fast (7 to 13 ms on MLX), but weak with more than about 20 options.
   - **Native Swift options** (coreai-kit, peterfriese/system-one-foundation-models) need macOS 27.
   - **Qualm** ships Kev-4B as the local default and Jev as an explicit opt-in that is "never a fallback".

   A user-configurable base URL with thresholds stored per backend is now a credible local-first path. A bundled local decider is not, yet.
9. **Official TypeSafe changes that matter to MacParakeet.**
   - **Option order.** The jaggedness page, revised 2026-10-02, now warns that Choice option order can bias `jev-1.13` toward the first option, and advises reordering to check consistency. A third-party benchmark (arXiv 2609.37647, via a secondary summary, not verified) reports that rotating options did not change accuracy on classification sets. MacParakeet orders targets with focused and editable controls first, so the warning is directly relevant.
   - **Rate limits** changed from 250k tokens/s and 1,200 requests/min to 100k tokens/s and 80 requests/s.
   - **API reference:** a Choice now allows at most 255 options, and `instructions` and `criteria` may be structured objects.
   - **Python SDK** went from 0.6.0 to 0.7.4: a pydantic `response_model`, an `http2` extra, and connection-pool keep-alive guidance.
   - **New repos:** `typesafe-ai/typesafe-public-examples` (cookbook data, 2026-10-05) and `typesafe-ai/WorkflowEvals` (2026-09-28).
   - `jev-latest` still points to `jev-1.13.0`.

## Repo table

"New" means created after the 09-20 survey, or not covered by it. "Updated" means the repo was in the 09-20 survey and has commits since then. Dates are created / last push.

### Native macOS voice, accessibility and desktop (most relevant)

| Repo | Status | Created / pushed | Stars | What it is |
|---|---|---|---|---|
| [ronadin2002/jev-cua](https://github.com/ronadin2002/jev-cua) | New | 09-20 / 09-23 | 38 | Swift floating bar, on-device SFSpeech, AX breadth-first walk, a single `next_action` Choice narrowed in stages, three-step span typing |
| [musubipapi/computah](https://github.com/musubipapi/computah) | New | 09-25 / 09-25 | 25 | Swift notch UI, Deepgram Flux (cloud speech), eager end-of-turn preparation, `relationship`/`object`/`outcome` questions |
| [chris-wozniczek/jev-voice-control](https://github.com/chris-wozniczek/jev-voice-control) ("Jev Voice") | New | 09-18 / 09-21 | 6 | Swift menu bar, SpeechAnalyzer, clause split by Noul, veto Nouls, wrong-surface recovery, `worked_before` hints |
| [mikakostoev/jev-voice-control](https://github.com/mikakostoev/jev-voice-control) | New | 09-21 / 09-21 | 0 | Swift, always listening, a command catalogue in JSON, speculative decisions on partials, P(none) gate, live eval TSVs |
| [calebvergene/jev-control-mac](https://github.com/calebvergene/jev-control-mac) | New | 09-22 / 09-23 | 0 | Swift + WhisperKit, 18-question fan-out per utterance, pinned model, silence trimmer; no screen observation |
| [kevinbadi/jev-voice](https://github.com/kevinbadi/jev-voice) | New | 09-18 / 09-23 | 111 | Python, whisper.cpp, about 15-question fan-out, multi-step AX port of jev-ultrafast with re-read and hit-test before acting |
| [Aryan-stark/jev-voice](https://github.com/Aryan-stark/jev-voice) | New | 09-26 / 09-26 | 0 | Fork-like copy of kevinbadi plus a local Ollama planner tier and per-risk thresholds |
| [rohit9mehta/dwim](https://github.com/rohit9mehta/dwim) | New | 09-21 / 09-21 | 5 | Swift palette, one Noul per menu-bar item, measured threshold and margin calibration, privacy deny-list |
| [RyanErkal/jevcast](https://github.com/RyanErkal/jevcast) | New | 09-22 / 10-09 | 3 | Swift launcher, menu scanning, margin over `no_match`, strict validation, learned intent memory with undo |
| [dabit3/jev-experiments](https://github.com/dabit3/jev-experiments) | New | 09-17 / 09-21 | 401 | 22 demos; `jev-ax-pilot` (AX loop), `jev-voice-turn` (end-of-turn), `say` (voice computer use), `jev-launcher` |
| [abhitsian/seek](https://github.com/abhitsian/seek) | New | 09-20 / 09-20 | 0 | Swift Spotlight finder; triangulated gate of a Choice, a per-option Noul and an "anything fits" Noul |
| [RoderickQiu/qualm](https://github.com/RoderickQiu/qualm) | New | 09-24 / 09-25 | 4 | macOS screen-time app reading the screen through AX; Kev-4B local by default, Jev opt-in, never a silent fallback |
| [T0mSIlver/localvoxtral](https://github.com/T0mSIlver/localvoxtral) | New (to this survey) | 02-15 / 10-08 | 59 | Local macOS dictation app (a peer to MacParakeet); Jev used only for QuickCapture project routing behind a consent toggle |
| Yappy ([yappy.biz/jev](https://yappy.biz/jev/)) | New | n/a | n/a | Closed-source macOS voice agent; one Choice per step over an AX table, escalates to an LLM on low confidence |
| [silverstein/minutes](https://github.com/silverstein/minutes) | New (to this survey) | 03-18 / 10-08 | 1542 | Local-first meeting app (a competitor); has a Jev qualification plan with synthetic computer-use cases |
| [shhivv/third-hand](https://github.com/shhivv/third-hand) | Updated | — / 10-04 | 343 | Now a chat app: a gpt-6-sol planner plus Jev grounding plus the arc-cua background driver |
| [awlevin/typesafe-computer-use](https://github.com/awlevin/typesafe-computer-use) | Updated | — / 09-29 | 1214 | About 90 commits: OSWorld runner, already-tried steering, popup handling, stall counters, an answer model |
| [kerpopule/hermes-jev-skills](https://github.com/kerpopule/hermes-jev-skills) | Updated | — / 10-09 | 1065 | Decisions as policies measured in shadow first; GUI stall hash; local vision shadow |
| [savka777/jev-use](https://github.com/savka777/jev-use) | Updated | — / 09-21 | 120 | 7 commits: a "Hey Jev" wake phrase, a hands-free widget, renewed clarification |
| [moritzkremb/jev-voice-browser](https://github.com/moritzkremb/jev-voice-browser) | Updated | — / 09-21 | 396 | 1 commit: sends the previous page and recent actions; handles "no, not that one" |

### Browser agents (patterns transfer to AX web areas)

| Repo | Status | Created / pushed | Stars | What it is |
|---|---|---|---|---|
| [chy4pro/jev-for-chrome](https://github.com/chy4pro/jev-for-chrome) | New | 09-18 / 10-01 | 37 | Chrome extension port of jev-ultrafast; `goal_done`/`stuck` veto Nouls; median 331 ms per decision |
| [agent-labs-dev/fastbrowse](https://github.com/agent-labs-dev/fastbrowse) | New | 09-17 / 10-10 | 114 | Jev acts, a Gemini Flash LLM plans; per-requirement `unmet_*` Nouls, claim checks, an irreversible-action Noul |
| [sedum-dev/sedum](https://github.com/sedum-dev/sedum) | New | 09-19 / 10-08 | 11 | Playwright end-to-end tests; strict gate (confidence ≥ 0.3, lead ≥ 0.1), a `holds`/`contradicted` claim pair, wording sensitivity data |
| [lexmount/jev-browser-bridge](https://github.com/lexmount/jev-browser-bridge) | New | 09-21 / 10-06 | 9 | Any CDP browser in a Jev loop; README only |
| [wy-coliney/jev-browser-use](https://github.com/wy-coliney/jev-browser-use) | New | 09-18 / 09-23 | 1039 | Jev clicks, Codex verifies; README only |
| [forvela/jev-agent-browser](https://github.com/forvela/jev-agent-browser) | New | 09-19 / 10-03 | 13 | A parent agent delegates bounded tasks; escalates ambiguity; README only |
| [jkudish/jev-browser](https://github.com/jkudish/jev-browser) | New | 09-17 / 10-08 | 323 | Jev-driven browser; not read |
| [browser-use/jev-ultrafast](https://github.com/browser-use/jev-ultrafast) | Unchanged on main | — / 09-30 | 22480 | No main commits since 09-18. Branches `codex/planner-loop` and `codex/state-action-hillclimb` (09-17 and 09-18) include "Audit proposed completion independently before accepting success"; not read in depth |

### Local and open System One backends

| Repo | Created / pushed | Stars | Note |
|---|---|---|---|
| [jaredpalmer/kev](https://github.com/jaredpalmer/kev) | 09-17 / 10-09 | 8837 | Qwen3.5 LoRA plus pointer head in 0.8B, 4B, 9B and 27B; `/v1/systemone` server; MLX on Apple Silicon; Apache-2.0 |
| [NandhaKishorM/laya](https://github.com/NandhaKishorM/laya) | 09-18 / 10-08 | 31987 | ModernBERT/mmBERT encoders; weak above about 20 options; over-confident as shipped |
| [mizorewww/laya-mlx](https://github.com/mizorewww/laya-mlx), [laya-coreml](https://github.com/mizorewww/laya-coreml) | 09-19 / 10-10 | 6858 / 1567 | MLX 7 to 13 ms; the Core ML ANE bundle is limited to 96 tokens |
| [ollaya-dev/ollaya](https://github.com/ollaya-dev/ollaya) | 09-23 / 10-09 | 1272 | "Ollama for decision models"; `/v1/systemone` |
| [john-rocky/coreai-kit](https://github.com/john-rocky/coreai-kit) | 06-12 / 10-09 | 117 | Swift on Core AI (macOS 27); runs Kev-0.8B/4B; `systemone serve` brew binary |
| [peterfriese/system-one-foundation-models](https://github.com/peterfriese/system-one-foundation-models) | 09-21 / 10-09 | 66 | Swift 6 bridge from Foundation Models `@Generable` to System One questions; macOS 27 |
| [Trans-N-ai/swama](https://github.com/Trans-N-ai/swama) | 2025 / 10-07 | 593 | MLX LLM server reading label-token probabilities; same wire format, uncalibrated |
| [dex0shubham/intern-decision-mlx](https://github.com/dex0shubham/intern-decision-mlx) | 09-27 / 10-01 | 1 | Vision decision model; 0.9 s per screenshot on an 8 GB M2 Air; weak judgement |
| [lexmount/WebJev](https://github.com/lexmount/WebJev) | 09-29 | 3 | 35B-A3B browser decision model; 38.5% vs Jev 16.7% on 125 sites; needs an 80 GB GPU |
| [cua-ai/cua-s1-forms](https://huggingface.co/cua-ai/cua-s1-forms) | 09-18 | n/a | 706k-parameter form-field scorer; 99.7% vs Jev 83.6% on its own synthetic task |

### TypeSafe official (`github.com/typesafe-ai`)

| Repo | Change since 09-15 |
|---|---|
| typesafe-sdk-python | v0.7.0 to v0.7.4: pydantic `response_model`, `http2` extra, early key validation with the key kept out of logs, a pool keep-alive of 30 s |
| typesafe-sdk-js | v0.6.0 (09-15), no change since |
| system-one-adapter-python | v0.2.1 (09-22): a drop-in TypeSafeClient backed by LLM APIs |
| typesafe-public-examples | New 10-05: data files for the cookbooks (function_calling, skill_suggestion, llm_guardrails, and others) |
| WorkflowEvals | New 09-28: reproduces evals.typesafe.ai; workflows split into `state`, `facts`, `questions`, `gates`, `actions` with named threshold profiles |
| n8n-nodes-typesafe-ai | New 09-23 |
| skills | No change since 09-12 |

`github.com/TypeSafeAI` describes itself as an **unofficial** community org. Its jev-harness, typesafe-router and typesafe-ui repos are not TypeSafe's.

### Other notable (less relevant) items

- **Coding agents and routing:** jev-router, JevRouter, Switchboard, skillranker, jev-agent-hooks, Kilo Code auto-routing.
- **Compaction:** fast-jev-compaction (7.5k stars), widely criticized as a design.
- **MCP servers:** at least 20 thin `jev-mcp` wrappers, of which jkudish/jev-mcp (11 tools, fail-closed) is the most complete.
- **Games:** typesafe-mario, jev-plays (Craftax), AI Hold'em, Pac-Man race. They share the same "code lists the legal moves, Jev picks one" pattern.
- **Mobile:** droidrun/mobile-jev (Android), Ryu0118/jev-sim-use (iOS Simulator), jev-chat (an Android accessibility reply drafter; sending stays manual).
- **Other providers serving Jev:** the OpenRouter "Decisions" alpha endpoint (`typesafe/jev-1.13`), Vercel AI Gateway (`typesafe-ai/jev`, `/v1/evaluate`), OpenCode Zen, and BeatAPI. These are other paths to the same model, and each adds another processor of the data.

## Per-repo notes

### awlevin/typesafe-computer-use (updated)
MIT. About 90 commits between 09-20 and 09-29. New docs: `OBSERVATIONS.md`, `VISION.md`, `docs/how-a-step-works.md`, `docs/osworld.md`.

- **Question shape:** still one request per step with `kind`, `site`, `item` and, when off-screen controls exist, `offscreen` Choices. `go_back` is a new kind.
  - The gate is still `min(kind, item)` at 0.4. `site` is left out of the gate on purpose, because a wrong page can be left.
- **Already-tried steering:** the state carries `already_tried_on_this_screen`, keyed by a screen signature: app, URL, focused field, and text lines bucketed into 20 pt rows, with at most 1 line in 10 allowed to differ.
  - The kind instruction: "never one listed as already tried on this screen: each of those led straight back here."
  - The item instruction forbids items an earlier action clicked on that screen.
- **Popups:** a covered control is described as `button 'Organise' (top-right; under 'Restore pages?')`. Choosing it closes the popup first, with its close button or Escape and never its other buttons, then clicks the control.
  - In a replay of 81 popup requests, the wording "covered by" pulled Jev toward Escape and lowered confidence; "under" did neither.
- **Duplicate labels** get row context: `'Buy' (middle-right; in the row of 'Coldplay', 'Oct 2')`, up to 3 neighbours.
- **Stall counters:**
  - `MAX_IDLE=3`: unchanged screens in a row.
  - `MAX_REPEATS=2`: actions already taken on this screen.
  - `MAX_STALLS=3`: stalls with no new page in between end the run as `stuck`. The reason given is that no solved OSWorld run stalled more than twice.
- **Answer model:** at every stop, an LLM returns `{achieved, answer, focus, question}`. It sets `achieved` only "when the screen itself shows the goal reached". A Jev `done` it cannot see on screen is sent back with a `focus`, up to 10 times.
- **Typed-text check:** a Noul asks whether the field "now contain[s] the typed text, and is that text a sensible value". Below 0.5 the old value is restored.
- **Options and size:** options the executor cannot perform are removed, because "an option the loop cannot execute is a guaranteed stall, and it reads as model doubt." A test enforces the request size budget.
- **Numbers (author-reported):**
  - OSWorld, Chrome tasks only: small hand-picked sets of 4/6, 3/4, 4/5 and 6/6. No overall score is published.
  - On the one task with a Luna-only baseline, the LLM was faster (29 s vs 42 to 134 s).
  - Jev "picks the same item for the same request only about 95% of the time."
  - Browser p50 is 302 to 380 ms per step.
- **Conflicting claim:** `docs/how-a-step-works.md` says the `AXManualAccessibility` / `AXEnhancedUserInterface` handshake is "unsupported on this macOS". This contradicts MacParakeet's working Chromium handshake. Not verified either way here.

### shhivv/third-hand (updated)
MIT. 24 commits between 09-28 and 10-04.

- **Architecture change:** planning moved to `gpt-6-sol` through ChatGPT OAuth (`CodexClient.swift`). A Jev router between Luna and Sol was built, then removed: effort made "no measurable difference", and the routing call delayed tasks when Jev was slow.
- **What Jev does now:** only target grounding, after an exact match and then a containment match.
  - One `target` Choice over at most 60 word-overlap candidates, or 254 when all candidates share a label, each described as `label = value [role] (ocr) — in "<row>"`, plus `__none__`.
  - No confidence gate. When Jev answers none among duplicates, the first match in reading order is used.
- **Background driver (arc-cua):** an MCP stdio process that is AX-first and drives hidden windows on a virtual display.
  - Every action carries the id of the snapshot it was decided on, and the driver refuses it if the app changed. The step is then decided again without counting as an attempt.
  - Settling waits for AX notifications to go quiet: a click went from about 1.15 s to 0.55 s.
- **Stall rules** (`RunProgress.swift`): refuses the same action on the same screen, an action that already failed on an unchanged control, a third unverified action in a row, or the same action 3 or more times.
  - Signatures ignore progress bars, sliders and `^\d{1,2}:\d{2}` clock text.
- **Lesson:** the snapshot-stamped refusal, the AX-quiet settle and the ambient filter are worth taking. The cloud planner reading screen text and the ungated first-match fallback are not.

### kerpopule/hermes-jev-skills (updated)
MIT. v0.19 to v0.23.

- **Policies, measured in shadow first** (0.20.0): each decision is a JSON policy containing:
  - batched questions
  - code `pre_rules` that skip Jev entirely
  - first-match-wins rules such as `["next.confidence", ">=", 0.6]`
  - `on_error` set to the old behaviour, and `on_drift` when the model version differs from `tuned_on: "jev-1.13.0"`
  - promotion criteria written before any data is seen (for example "loop-step: min 100 backtest pairs, false_complete_max 0")

  `jev shadow report` grades PASS/FAIL/UNKNOWN with Wilson intervals, kappa, AUC and a threshold sweep.
- **Results (author-reported):** on 18,585 real calls, 8 policies were dropped after about 5 tuning rounds each. Two plausible code shortcuts failed on history: "output unchanged → skip" was wrong 6/6, and "same error twice → hold" was wrong 67/135.
- **GUI stall hash:** SHA-256 over the window title plus every element's (role, label, value, selected, enabled, frame), covering all elements rather than only the 26 shown to Jev. Two unchanged results in a row stop the run before the next Jev call.
- **Chooser floor of 0.65,** calibrated on 31 labelled cases: correct answers scored 0.74 to 0.90, and one trap case never went above 0.58. Run-to-run noise is about ±0.08.
  - Permutation averaging was tried and **rejected**: it pushed the trap's wrong answer to 0.70 to 0.74, high enough to act. This bears on the TypeSafe option-order advice.
- **Question-writing rule:** name the one attribute that decides and label the others as tie-breakers. One case went from 16/44 to 33/44.
- **Local Jev-Omni vision shadow** (not TypeSafe's model; about 13 to 14 GB): only 67% agreement with the reference, so it stays shadow-only.

### chris-wozniczek/jev-voice-control ("Jev Voice")
MIT. Swift menu-bar app; hold ⌥Space to talk; on-device SpeechAnalyzer, Apple Speech or Whisper.

- **Order of work:** a local parser runs first. Multi-command speech is split into clauses, and each split point is confirmed by a Noul (≥ 0.6).
- **Router per clause:** Choices for `action`, `target_app` (up to 254 apps) and `system_action`; Nouls for `mentions_url`, `refers_to_frontmost`, `composes` and `destructive`.
- **Step state:** the last 6 actions, `worked_before` hints from a per-app `HintStore`, `recent_changes` (a diff of the snapshot), and a `matches_request` flag per element.
- **Option text is annotated:** "— creates something new, which the request did not ask for", "— label matches the request", "(worked before…)".
- **Step questions:** a `next_action` Choice plus `goal_reached`, `wrong_surface` and `needs_text` Nouls, all in the same request.
- **Gates:**
  - DONE needs `done` ≥ 0.5 (≥ 0.4 if the screen changed) or `goal_reached` ≥ 0.7, and only after at least one change. If `done` wins but `goal_reached` is below 0.7, it moves to the runner-up.
  - `wrong_surface` ≥ 0.7 triggers Escape, then Cmd-W, at most twice.
  - A click below 0.45 waits 0.7 s and observes again.
  - Below 0.30 it reports uncertain.
  - Back-and-forth between two screen states (A/B/A/B) is detected.
  - A creation control may be used once.
- **Escalation is not local-first:** observation falls back to Vision OCR, Chrome DevTools, and finally a DeepSeek planner given a screenshot (cloud).
- **Latency (author-reported):** Jev calls "~100–300 ms"; the command fires "~50–300 ms after release".

### musubipapi/computah
MIT. Swift, with cloud speech (Deepgram Flux).

- **Speech timing:** on `EagerEndOfTurn` it prepares a decision without sending input. `TurnResumed` discards it, and `EndOfTurn` reuses it only if the transcript is identical.
- **Questions:** Jev requests are documented in `docs/JEV_REQUESTS.md`.
  - A new utterance gets a `relationship` Choice: replace, revise, resume, append, cancel or unclear.
  - Verification asks `outcome` (complete, progress, contradicted, pending) and `object` (same_intended_object, wrong_object, unknown).
  - Spoken URLs and addresses get one Choice per token.
- **Options:** split into parts of 64; the top 3 of each part go to a finalists request; if every part says `none_here` it abstains.
- **Input handling:** a new speech turn revokes the previous command's permission to send input. Clicks are hit-tested so the target's process must own the point. Sliders can be set to a value through AX.

### rohit9mehta/dwim and RyanErkal/jevcast
Both MIT, both Swift.

**dwim** reads the front app's whole menu bar through AX and asks one Noul per item: "Would choosing the menu item X do what they asked for?" Batches of 64 run in parallel.
- It skips personal menus (Open Recent, History, Bookmarks, items named like window titles).
- Destructive-regex items never run on their own.
- Below the threshold it shows the top 5 to choose from.
- Code comment (author-reported): "0.50 alone ran 65/72 with 3 near-synonym misses (all undoable); 0.70 plus a 0.15 lead over the runner-up ran 47/72 with none."

**jevcast** uses one `selection` Choice plus `no_match`.
- Gate: probability ≥ 0.55, confidence ≥ 0.50, and a lead over P(no_match) ≥ 0.10.
- Strict response validation: model id, exact option keys, probabilities summing to 1 ± 0.01, the chosen option being the most probable.
- Learned intent memory: repeats cost zero calls, and ⌘Z undoes the action and forgets the pick.
- A layered "kind, then narrow" re-ask gets past the 120-candidate cap.

### mikakostoev/jev-voice-control and dabit3/jev-experiments
**mikakostoev** uses OpenRouter's alpha Decisions endpoint.
- **Stage 1:** the state includes the first 70 on-screen labels, so speech naming an on-screen item reads as a command rather than chatter. Options are every catalogue command plus `none` ("chatter, a question, thinking aloud, or noise").
- **Gates:** confidence ≥ 0.6, or ≥ 0.4 when P(none) ≤ 0.1. When Stage 1 is torn between commands, a confident on-screen click can rescue the request.
- **Duplicate labels:** picks the element nearest the focused field.
- **Speculative decisions:** runs Stage 1 on partial transcripts and caches the result if the final text is unchanged.
- **Evals:** live-model test files (`Tests/cases.tsv`, `Tests/clicks.tsv`) hold phrases that must trigger, phrases that must stay quiet, and click cases.

**dabit3/jev-experiments:**
- **`jev-ax-pilot`** keeps 60 elements by relevance score (+5 focused, +3 inside a sheet, +2 text input) and passes facts computed in code into the state.
  - It asks `goal_reached` (end at > 0.8, only after step 1) and `is_destructive` (> 0.5 that the goal does not name blocks the run).
  - It races each request against a 900 ms deadline and drops stale answers by sequence number.
  - Numbers (author-reported): Jev p50 about 100 ms; about 2k input tokens per decision; "Jev itself is 10–15% of a step".
- **`jev-voice-turn`** asks a `turn_complete` Noul on every partial transcript: fire at ≥ 0.85 after a 250 ms pause, stretch the silence timeout to 2.5 s below 0.35, otherwise wait for 1 s of silence. It was tested with a simulated microphone only.
- **`say`:** when the choice is `done` or below 0.35, a separate `verified` Noul over {state, proposed action} must reach 0.85 or it says "I'm not sure". It also confirms any input into a terminal app.

### kevinbadi/jev-voice (and Aryan-stark/jev-voice)
**kevinbadi** is the closest analogue to MacParakeet in Python.
- **Pipeline:** energy VAD, whisper.cpp base.en (80 to 130 ms), then one fan-out of about 15 questions (170 to 420 ms on an M4 mini).
- **Text values:** a Choice over regex-cut spans ("select, don't generate").
- **Multi-step mode:**
  - Bounded AX walk: 3,500 nodes, 0.9 s, depth 60, up to 250 candidates.
  - `AXManualAccessibility` is set for Chromium and Electron apps.
  - Before acting it re-reads the target's attributes and the window key and hit-tests the target's centre.
  - Settle waits after each action: 80 to 400 ms depending on the action.
  - Limits: 40 actions and 80 Jev calls; 3 no-effect actions end the run as BLOCKED.
  - "DONE is the model's claim, not proof."
  - Escalates ties to Claude Haiku, then Opus.

**Aryan-stark** adds a local Ollama planner tier. Its motivating failure: a forced Choice turned "mute slack notifications until 3pm" into `system(lock)`. That is the clearest public example of why an explicit "cannot do this" option is needed.

### Browser repos: jev-for-chrome, fastbrowse, Sedum
**jev-for-chrome:**
- **DONE veto:** DONE is vetoed when `goal_done` < 0.5. It is then removed from the next request, with a notice giving the probability. The criterion includes "A filled form that has not been submitted is not achieved."
- **BLOCKED veto:** BLOCKED is vetoed when `stuck` < 0.5 and fewer than 6 actions have run.
- **Stalls:** the same operation and label 3 times in the last 6 actions ends the run even if the page changed. A target that missed twice is hidden while alternatives exist.
- **Gap:** there is no target-confidence gate.

**fastbrowse:**
- **Planning:** an LLM writes checkable requirements from the task text before it sees the page, so page text cannot inject requirements.
- **Done check:** a strict `complete` Noul plus one `unmet_{id}` Noul per requirement. Accept at ≥ 0.85, or at ≥ 0.50 when every requirement scores below 0.30.
- **Irreversible actions:** a separate Noul whose state is only the URL and page title, never page text, so the page cannot talk it out of confirming. Above 0.50 the run stops at `needs_confirmation`.
- **Effect diffs:** after each action, code writes a diff into history ("X value: a -> b; showed …; removed …").
- **Hedged requests:** after 1.5 s without an answer, a duplicate request is sent and the first answer wins.
- **Numbers (author-reported):** a 26k-token request failed through the gateway 5 times in 8. The authors note that a confidently wrong DONE at 0.85 or above skips the screenshot check.

**Sedum:**
- **Gate:** a strict two-part gate (confidence ≥ 0.3 and a lead ≥ 0.1 over the runner-up); otherwise it fails closed with a top-3 trace.
- **Claim check:** `holds` ≥ 0.75 and `contradicted` < 0.5.
- **Wording sensitivity (author-reported):** "Profile saved is visible" scored 0.29, `"Profile saved" is visible` scored 0.81, and `The page displays the confirmation message "Profile saved".` scored 0.90.
- **Freshness:** candidates are collected again before acting, and any mismatch discards the decision; a stale choice is never remapped.
- **Cycles:** a fingerprint seen more than 3 times stops the run with `no_progress`.
- **Do not copy:** its shared instruction treats every step, including placing an order, as expected and safe.

### Speech timing: Giobebbe/jev-voice-agent, gaborishka/jev-canvas, Veris
**Giobebbe** runs two transcribers: a fast local MLX Whisper pass every 200 ms, trusted only for closed-set commands, and ElevenLabs (cloud) for free text.
- **Early fire** is allowed only for open_app, open_website and show_folder, with tool ≥ 0.9, argument ≥ 0.85, and the same answer on two consecutive evaluations.
- **`cut_off` Noul** ("is the last phrase unfinished?"): at ≥ 0.7 it waits, or carries the clause into the next segment for 2.5 s.
- **Results (author-reported):** 27/27 audio actions with 0 false fires; open commands fired a median 0.5 s before the end of speech.

**jev-canvas** time-stamps where the user was pointing at the moment each pointing word was spoken (`SPEECH_LAG_MS=300`), not when the answer arrives. On a partial transcript, a placed action fires only if `where` ≥ 0.6.

**Veris** (blog, 2026-10-05): 600 simulated calls. Semantic turn detection cut interruptions from 52% to 11%, but median reply latency rose from 2.1 s to 4.6 s, and task completion was unchanged (50/300 vs 53/300).

### Local backends: Kev, Laya, Qualm
- **Kev** (author-reported):
  - Held-out index: 23.3 (0.8B), 38.0 (4B), 41.0 (9B), 52.3 (27B), vs Jev 54.0.
  - Share of decisions that can be automated at a 5% error budget: 0.14 (0.8B), 0.52 to 0.69 (4B to 27B), vs Jev 0.70.
  - On an M5 with 32 GB, 5 questions on about 270 tokens: Kev-0.8B 149 ms new / 28 ms repeated; Kev-4B 721 ms new / 136 ms repeated, 8.4 GB.
  - Repeated text is cheaper because the server reuses a prepared state.
- **Laya:** below the majority-class baseline on its typed-decisions benchmark unless fine-tuned. Over-confident as shipped (ECE 0.466). Advises staying under about 20 options.
- **Qualm** uses Kev-4B 8-bit MLX at about 1 s per check with 6 to 7 GB free, vs about 0.2 s for hosted Jev. It states that if the local model is down, it does not quietly switch to the hosted one.
- **Confidence differs by backend:** it is computed differently by Kev, coreai-kit, intern-decision and swama, so thresholds do not transfer between backends.

### minutes (competitor) and localvoxtral (peer)
**minutes** (`docs/plans/jev-evaluation-2026-09-17.md`) ran 7 synthetic cases through Vercel AI Gateway: median 597 ms, maximum 1,365 ms.
- The cases: attendee vs mention, semantic recall, 404 detection, incorrect paste despite API success, stale foreground target, page-content instruction injection, and ambiguous-target clarification.
- Its boundary statement matches MacParakeet's: Jev must not "authorize writes, relax permissions, invent targets, decide that a send is allowed, or substitute for exact readback."
- No runtime integration has shipped.

**localvoxtral** routes captures with top ≥ 0.9 and margin ≥ 0.15, calibrated on a 36-capture replay. It uses Jev only behind a consent toggle.

## Ranked ideas for MacParakeet Voice Control

Ranked by expected reliability gain per unit of complexity, under MacParakeet's constraints: local-first, AX-only adapter, consent-gated text to Jev, and Jev never authorizing effects.

1. **Add independent completion vetoes in the same request.**
   - **What:** when `finished` is offered, also ask a `goal_shown` Noul ("Does the screen itself show …?") and a `contradicted` Noul. Treat `finished` as accepted only when it leads, `goal_shown` ≥ about 0.75, and `contradicted` < 0.5. On a veto, drop `finished` from the next request and add a note to the state saying it was vetoed.
   - **Why:** the contract already calls Jev's `finished` inferred. This gives a second, differently worded signal at zero extra round trips; fan-out is parallel. jev-for-chrome, Sedum, chris-wozniczek and jev-ax-pilot converged on it independently.
   - **How to word it:** quote the expected UI text, since Sedum's data shows wording moved scores from 0.29 to 0.90.
   - **Cost:** a few extra heads per request; thresholds need replay calibration.
2. **Put "already tried on this screen" into the state and instructions.**
   - **What:** key on the existing semantic fingerprint. List the controls already pressed or filled on this screen, and tell the `kind` and `target` heads to avoid them.
   - **Why:** today an identical action cannot dispatch twice, but Jev can still spend the turn choosing it again and then hit the block. Steering is cheaper than blocking.
   - **Source:** typesafe-computer-use; `worked_before` in chris-wozniczek is the positive counterpart.
3. **Detect cycles and ambient changes, not just two identical observations in a row.**
   - **What:** count total visits to each semantic fingerprint per task (stop at 3), and the same operation and label 3 times in the last 6 steps even when the screen changed (catches disclosure and menu toggling).
   - **What to exclude:** leave clock-like text, progress indicators and slider values out of the "unchanged" fingerprint, and hash every kept control rather than only the offered ones.
   - **Source:** sedum, jev-for-chrome, third-hand, hermes. Purely local and testable with fake trees.
4. **Gate on the margin over the runner-up and over `insufficient_evidence`, not only `min(kind, target)`.**
   - **What:** keep the minimum-confidence gate and add a probability lead (for example ≥ 0.10 to 0.15) over the second-best target. Also add a fast-path rule where a low P(`insufficient_evidence`) can permit a moderate pick.
   - **Calibrate it** on recorded `latest.json` decisions with `macparakeet-cli voice-control replay`, including trap screens where the right answer is to not act (the hermes method).
   - **Source:** dwim has published data on the trade-off; jevcast, sedum and localvoxtral use margins too.
5. **Check option-order sensitivity on thin margins.**
   - **What:** when the target margin is thin, re-ask once with the target options in a different order (for example reversed) and act only if the argmax is stable. Otherwise use numbered disambiguation.
   - **Why:** TypeSafe's 2026-10-02 jaggedness revision now names option-order bias, and MacParakeet's ordering (focused, then editable, then traversal order) puts likely targets first.
   - **Caution:** hermes found that *averaging* permutations made a wrong answer actionable, so use the re-ask as a consistency check, not as an average. It costs one extra request, and only on low-margin turns.
6. **A two-stage shortlist instead of priority truncation above 200 controls.**
   - **What:** first stage, one Choice over compact labels (in groups if needed, staying under the 255-option API limit). Second stage, re-ask over the top 3 to 5 with richer descriptions: row context, enclosing sheet or form, nearby text.
   - **Source:** this is the official skill-suggestion cookbook pattern and what computah, jevcast and fastbrowse do.
   - **Also adopt:** row-context labels for duplicate names ("in the row of 'X'") and "under '<sheet title>'" for covered controls, independently of the shortlist.
7. **Worded effect diffs in executed history.**
   - **What:** extend `{operation, control, value, outcome}` with a short code-written effect summary ("value '' → 'alan turing'; sheet 'Save' appeared; no visible change"), plus the instruction that "no visible change" means trying a different approach.
   - **Source:** fastbrowse, chris-wozniczek's `recent_changes`, and ronadin's "OBSERVED SCREEN UNCHANGED".
   - **Privacy:** it must reuse the existing rule on which field values may reach Jev.
8. **Re-decide on a stale snapshot without counting it against the budget.**
   - **What:** when revalidation before acting finds that the chosen control's fingerprint changed, take a fresh observation and decide again. Do not count this as a dispatched effect or as a replay.
   - **Source:** third-hand's arc-cua and sedum both treat stale choices this way; sedum never remaps a stale choice.
   - **Status:** MacParakeet already revalidates, so this may be partly covered. Check the current runner's accounting before changing anything.
9. **A consequence check that never sees page text.**
   - **What:** for the advisory `consequence` head, consider a separate Noul whose state is only app, window title, control role and label, and the proposed operation, so page text cannot argue it down.
   - **Source:** fastbrowse.
   - **Fit:** this complements, and does not replace, the local consequence policy that a model label cannot downgrade.
10. **Shadow-first rollout for new Jev rules.**
    - **What:** any new head or threshold first logs its would-be decision next to current behaviour in the session log. It is promoted only against criteria written beforehand (for example zero false completions on N replayed sessions).
    - **Why:** hermes found that 8 of 14 plausible policies and two "obvious" code shortcuts failed on history.
    - **Fit:** MacParakeet already has replayable `latest.json` observations, which makes this cheap.
11. **Freeze the context at speech time.**
    - **What:** take the focus and AX snapshot at key-down, or at the first word, and treat a large change by the time the transcript arrives as a reason to observe again.
    - **Source:** jev-canvas `SPEECH_LAG`, kevinbadi's re-read and hit-test before acting.
    - **Why:** it closes a window where the user's deictic "this" refers to what was focused while they spoke.
12. **Early commit for closed-set commands only, with strict conditions.**
    - **What:** if early commit is ever extended beyond today's closed-set rule, use Giobebbe's conditions (probability ≥ 0.9, the same answer on two consecutive partials, `cut_off` < 0.7, allowed command kinds only). Keep free text final-only.
    - **Where checks run:** run partial-transcript checks locally, or behind explicit consent, because streaming partials to the cloud sends text the user may not have meant as a command.
    - **Not for hold-to-talk:** Veris shows semantic end-of-turn detection hurts latency there. It is only worth it for a hands-free mode.
13. **Menu-bar items as action candidates.**
    - **What:** expose the front app's enabled menu items (not descended today, because closed menus are pruned) as a separate candidate source for commands such as "export as PDF" or "show the sidebar". Walk them lazily, use dwim's privacy deny-list, and apply destructive-item rules.
    - **Source:** dwim, jevcast, jev-ax-pilot.
    - **Cost:** moderate; it adds an observation source and its own legality rules.
14. **An optional local decision endpoint (research spike, not product work).**
    - **What:** allow a user-configured `/v1/systemone` base URL (Kev, ollaya, `systemone serve`) as an explicit choice, never a silent fallback, with thresholds stored per backend.
    - **Fit:** this would let Voice Control run with no cloud text at all, which fits ADR-027.
    - **Constraints:** today's options need about 8 GB (Kev-4B) for near-Jev quality, about 720 ms on a new state, a Python runtime or macOS 27, and new calibration. Laya-class encoders are too weak for target selection over many controls; they may suit small yes/no heads only.
    - **Layout to test:** put the AX table in `state` and the utterance in the question instructions, so a prepared state can be reused across retries.
15. **Live-model evaluation fixtures.**
    - **What:** add TSV-style cases that must trigger, must stay quiet, or must click a specific control, run on demand against the live API (opt-in, key from Keychain).
    - **Why:** this catches regressions when `jev-latest` changes; MacParakeet pins `jev-1.13.0`, but a future upgrade needs the suite.
    - **Source:** mikakostoev, and hermes's `on_drift` and `tuned_on` fields.

### Do not adopt

- **Sending screen text to a cloud LLM planner** (third-hand gpt-6-sol), or **screenshots to a cloud model** (chris-wozniczek's DeepSeek escalation). Both conflict with the local-first posture and the text-only Jev boundary.
- **No target gate, or a fallback to the first match** (third-hand, jev-for-chrome, ronadin, computah). MacParakeet's `min(kind, target)` gate plus numbered disambiguation is stronger.
- **Averaging over permutations** to "fix" option-order bias (hermes measured that it made a wrong answer actionable).
- **Treating every goal step as safe**, including placing orders (Sedum's shared instruction).
- **Forced Choices without a "cannot do this" option** (the Aryan-stark lock-screen failure).
- **Silent request shrinking** (third-hand halves options when a request is over 24 KB) and the unpinned `jev-latest` model id. Keep MacParakeet's visible failure on oversize requests and the pinned model.
- **Always-on listening without a wake word** (mikakostoev), and the undocumented OpenRouter alpha Decisions endpoint as a dependency.
- **Large single requests:** fastbrowse saw a 26k-token request fail through the gateway 5 times in 8. The new official rate limit (80 requests/s) is not a constraint for one user, but large fan-outs with retries are.

## Unverified items and gaps

- **Not verified:** all latency, cost, accuracy and benchmark numbers (author-reported); Yappy internals (closed source); Co-Agent internals (only a thin client is in hermes-jev-skills); peterfriese's 15 to 35 ms ANE claim; Laya's comparison figures against Jev (third-party numbers); Kev-9B and 27B on a Mac.
- **Contradictions:**
  - typesafe-computer-use says the `AXManualAccessibility` handshake is unsupported on its macOS, which contradicts MacParakeet's working handshake.
  - The arXiv paper 2609.37647 (Deußer, Sparrenberg, Sifa, 2026-09-29) reportedly finds that rotating options does not change accuracy. This contradicts TypeSafe's own option-order warning. It was read only through a secondary summary (opentrain.ai) and should be checked against the paper itself.
- **Not read in depth:** jkudish/jev-browser, wy-coliney/jev-browser-use, lexmount/jev-browser-bridge, droidrun/mobile-jev, Ryu0118/jev-sim-use, jev-ultrafast's experimental branches, dabit3 jev-shell-guard, and most of the roughly 300 search hits (MCP wrappers, SDK ports, routers, games).
- **Possible omissions:** GitHub code search is rate-limited and shows at most 100 results per query, so Swift and AX projects that do not mention `api.typesafe.ai`, `systemone` or `jev-1.13` in indexed code may be missing.
