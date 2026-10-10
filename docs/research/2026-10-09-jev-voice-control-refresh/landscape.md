# Voice and agentic computer use on macOS: landscape refresh

Date: 2026-10-09. Window: mainly 2026-09-01 to 2026-10-09, with earlier context
where a September item depends on it. This builds on
[references.md](../2026-09-19-jev-voice-control/references.md) and the
[2026-09-25 deep review](../2026-09-25-voice-control-jev-deep-review.md). It does
not repeat them.

Method: web search and fetch, plus `gh api` for repository metadata and READMEs
(stars and push dates as observed on 2026-10-09). No downloaded code was run.
Jev was not used for this report.

Evidence labels used below:

- **[P]**: checked against a primary source, such as vendor docs, release
  notes, an arXiv abstract or paper, a WWDC video page, or a GitHub README or
  release.
- **[S]**: secondary reporting only (press, aggregators, blogs). The claim is
  plausible, but I did not see it in a primary source.
- **[U]**: unverified, conflicting, or inferred by me.

## Summary

1. **Apple now ships "say what you see" Voice Control, but on iPhone and iPad.**
   Voice Control in the 27 releases accepts natural-language descriptions of
   on-screen elements ("tap the purple folder") and helps with unlabeled
   controls. Apple's announcement names iPhone and iPad. Mac support is not
   stated [P]. The feature MacParakeet's command-and-control mode differentiates
   on is now a platform default on iOS, and Mac users will expect it.
2. **Closed-set "decision" models are now a recognized product category.**
   OpenAI announced a Decisions API (GPT-6 Luna) at DevDay on 2026-09-29. It
   picks one answer from a declared set given text or image context, and is
   reported at about 150 ms [S]. Cua published CUA-S1, small open "System 1"
   models that choose from closed (element, action) sets, with a frank failure
   analysis [P]. Jev is no longer the only option, and there is now an open-weight
   local path that fits the local-first posture.
3. **The OSS Mac computer-use stack has converged.** Projects observe
   Accessibility first, use OCR or vision only as fallback, deliver input to the
   target process in the background, show a visible agent cursor, attach a
   snapshot generation to element ids, verify outcomes with a classification,
   and gate destructive actions on the server side. MacParakeet already has most
   of the safety half. It lacks the visible half: on-screen target feedback.
4. **Benchmarks reward slow, long-horizon generalists.** That is the wrong axis
   for voice. OSWorld-Verified is effectively saturated (top scores about 85%)
   [S]. OSWorld 2.0 tasks run about 40 minutes per task for top agents [S].
   Efficiency research finds that planning and reflection account for 76-96% of
   latency, and that a full AX tree can take 3-26 s to generate in heavy apps
   [P]. For voice, the wins are bounded single-step decisions over compact,
   pruned, diffed observations.
5. **Agent-exposure standards matured in a way that suits "observe/act/verify"
   tools.** MCP 2026-07-28 is stateless. It replaces server-initiated
   elicitation with `input_required` multi-round-trip results, a natural fit for
   confirmations [P]. The MCP maintainers say tool annotations are hints, not
   enforcement [P]. Safari 27 ships a local MCP server, but it drives an
   isolated automation window, not the user's signed-in session [P].

## 1. Vendor releases and developer surfaces

| Vendor / product | What changed (date) | Grounding | What developers get | Label |
|---|---|---|---|---|
| Anthropic, Claude API | `computer_toolset_20260801` GA 2026-08-19: 17 member tools, batch actions (several actions per turn, run in order, stop at first failure), `zoom` on by default, per-member `configs`. Required for Opus 5.5 (2026-09-22), Sonnet 5.5 (2026-09-28), Haiku 5.5 (2026-10-07) on the API; the older `computer_20251124` returns 400 there. | Pixels (screenshot + zoom); screenshot classifiers flag prompt injection | Client-executed toolset; docs recommend human confirmation for financial, ToS, cookie and sensitive-file actions | [P] |
| Anthropic, Claude API | `browser_toolset_20260801` launched 2026-08-19: reads the accessibility tree, elements, forms, tabs; element references; form input; downloads; uploads. | Accessibility tree / DOM refs | Client toolset for hosted browsers | [P] |
| Anthropic, Claude in Chrome | GA on all paid plans 2026-08-26. Modes are "Manually approve" (per action) and "Automatically approve" (a safety review per action; pauses to ask). The side panel can show a plan (sites and approach) for approval before work starts. Chrome only. | DOM / AX | End-user product; Compliance API exports sessions (2026-10-08) | [P] release notes; [S] modes |
| Anthropic, Claude Cowork / Claude Code on Mac | Mac computer use research preview since 2026-03-23. It prefers connectors, then the browser, then direct desktop control. Needs Accessibility and Screen Recording, plus per-app access approval. | Screenshots + input | End-user feature; not an SDK | [S] |
| OpenAI, Codex Mac app | Since 2026-04-16: native macOS computer use with its own cursor(s), running in the background without bringing apps forward; parallel agents. MacStories reports it reads the AX tree and calls the virtual cursor's "wiggle while thinking" a UX highlight. Not available in the EU, UK or Switzerland at launch. | AX tree + screenshots | Closed runtime. Community projects (`fitchmultz/macuse`, `wangdada8208/codex-cua-jev`) already wrap the installed private runtime, an unsupported dependency | [P] OpenAI post on X; [S] details |
| OpenAI, ChatGPT desktop | ChatGPT Voice on desktop (2026-07-23), powered by full-duplex GPT-Live (listens while it talks, gives backchannel acknowledgments); controls the computer and steers agents in ChatGPT Work and Codex; Mac "appshots" of the front window. Atlas browser retired 2026-07-09 and stopped working 2026-08-09. | Computer use + appshots | End-user product | [S] |
| OpenAI, DevDay (2026-09-29) | Agents API gains computer use (reported mix of screenshots, accessibility trees and code); "dots" always-on cloud agents; **Decisions API** (Luna, closed answer set, text or image context, about 150 ms reported, limited preview, no public docs as of 2026-09-30). | Mixed | API | [S] |
| Google, Gemini API | Computer use built into Gemini 3.5 Flash (public preview 2026-06-24): browser, mobile, desktop; every function call carries an `intent` string explaining the step; responses can carry `safety_decision: require_confirmation`; optional prompt-injection auto-stop; normalized 0-1000 coordinates. | Pixels only (no AX input documented) | API + reference implementations | [P] |
| Google, Gemini Desktop for Mac | A hidden "Full Access / additional sandbox options" setting was found (2026-10-03): files anywhere plus acting through Mail, Safari and Messages. It confirms before purchases, account creation, legal terms and sensitive changes. Not launched. | Unknown | None yet | [S] |
| Apple, OS 27 (shipped 2026-09-14) | Voice Control natural language ("say what you see"), helps with unlabeled elements, English in US, CA, UK and AU. The newsroom names iPhone and iPad. Mac availability is not stated. | Apple Intelligence; method not disclosed | No new developer API for Voice Control; "be a good VoiceOver citizen" | [P] newsroom; [U] Mac |
| Apple, Siri + App Intents (WWDC26) | Onscreen awareness via `NSUserActivity` and view annotations (`.appEntityIdentifier`, collection and custom-canvas annotations), which tell Siri which entities are on screen and where. App Schemas (`@AppIntent(schema: .messages.sendMessage)`) let Siri act without opening the app. `OwnershipProvidingEntity` lets Siri auto-confirm actions on the user's own entities. Interaction donations. | Developer-declared semantics | First-party Siri only; no third-party assistant access documented | [P] |
| Apple, Safari 27 | Native MCP server (`/usr/bin/safaridriver --mcp`), opt-in under Settings > Developer. DOM, network, screenshots, console. Runs in an isolated automation window with no access to cookies, passwords or history. | DOM | Any MCP client; meant for web-dev testing, not the user's session | [P] via WebKit blog coverage |
| Apple, privacy | 2026-10-02 developer news: Full Disk Access will require "very explicit user action", explicitly because of AI-agent risk. Accessibility and Screen Recording are not mentioned. | n/a | Watch for the same treatment of Accessibility | [P] quote via Help Net Security; [U] scope creep |
| Apple, Xcode 27 | First-class MCP bridge for external coding agents. | n/a | Dev tooling | [S] |
| Microsoft | Copilot Studio computer-using agents GA (2026); Windows 365 for Agents MCP server ("semantic UI inspection"); a separate agent account/workspace on Windows for Copilot Actions. Voice Access gained natural-language command variants, an on-device SLM for fluid dictation, and a **"wait time before acting"** setting. UFO³ (open source) advertises hybrid UIA + vision detection and "speculative multi-action", with 51% fewer LLM calls. | UIA + vision | MCP servers; UFO SDK | [P] UFO README, MS support; [S] rest |
| Perplexity | "Personal Computer" Mac agent available to all Mac users; voice capable; pairs with Comet. | Unknown | End-user product | [S] |

Implications for MacParakeet:

- The frontier vendors expose **pixel tools** (Anthropic, Google) or **closed
  runtimes** (OpenAI Codex). The vendor that reads the AX tree (OpenAI) does not
  expose it. None ships a local, private, voice-first, one-step command layer.
  That niche is still open on the Mac, but Apple has shown it intends to fill it
  on iOS.
- Gemini's per-action `intent` string and `safety_decision` field are the
  closest vendor analog to MacParakeet's "show what will happen, confirm only
  hazards" design.

## 2. Open-source macOS computer use and voice projects

Repository facts from `gh api` on 2026-10-09 [P].

| Project | Stars / last push | What it is | Notable technique |
|---|---|---|---|
| [trycua/cua](https://github.com/trycua/cua) | 29.2k / 2026-10-10 | Cua Spaces (agent desktops in local macOS VMs), **Cua Driver** (macOS/Windows/Linux, MCP/CLI/SDK), Lume VMs, Cua Bench, **CUA-S1** decision models | Driver returns AX tree + screenshot together; `element_token` actions via `AXPerformAction`; only element actions report `confirmed`, others report `unverifiable` / `suspected_noop`; background delivery with its own cursor overlay. Notes "off-Space SwiftUI windows lose their tree". |
| CUA-S1 ([model card](https://github.com/trycua/cua/blob/main/libs/cua-s1/MODEL_CARD.md)) | same repo | "System 1" closed-set chooser. `cua-s1-4b` is a LoRA on Qwen3.5-4B with text (AX) and multimodal adapters; one forward pass, softmax over option-letter tokens | **Failure lesson:** the forms checkpoint returns a *high-confidence `skip`* on out-of-vocabulary labels (29.3% accuracy on held-out forms, 36 of 41 predictions `skip`, mean confidence 0.974). A confident "nothing to do" is not evidence of done. |
| [openclaw/Peekaboo](https://github.com/openclaw/Peekaboo) (formerly steipete) | 5.3k / 2026-10-08; v4.9.0 2026-10-07 | macOS CLI + MCP: `see --app X --json` returns a UI map with opaque element ids; snapshots; agent mode | App/PID-scoped menu-extra clicks with revalidation; file dialogs bound to the parent window; receipts that keep "unverified / indeterminate / retry-unsafe" separate from success; visualizer overlays from a hidden companion app. |
| [minghinmatthewlam/computer-use-mcp](https://github.com/minghinmatthewlam/computer-use-mcp) | 47 / 2026-08-17 | Signed Swift MCP server, background-safe | **Delivery ladder** AX action, then per-window event, then per-pid event, then opt-in global cursor; `_meta` delivery tier + `fallback_reasons`; **outcome classes** `success` / `unsupported` / `effect_not_verified` (with `failure_domain` transport vs verification) / `verifier_ambiguous`; ids carry a snapshot generation; diffs after actions; `skeleton: true` + `scope_element_id`; **dense-collection viewport windowing** using visible-rows attributes; server-side confirm for Delete/Erase/Reset, secure fields and URL policies; yields when real hardware input is seen. |
| [iamngoni/mac-computer-use](https://github.com/iamngoni/mac-computer-use) | 2 / 2026-10-02 | Native Swift MCP server | Automation cursor that flies to the target and *lands before* acting; badges for typing, keys and scroll; shake on failure; **2-second countdown ring before Send/Delete/Buy**; Esc pauses all agents; agents wait while the user is active in the same app; `point_at`, `annotate`, `ask_user`, `pick_element` (user points back); overlays excluded from agent screenshots; pointing fails closed when the target window is covered. |
| [Anionex/dsh-computer-use](https://github.com/Anionex/dsh-computer-use) | 52 / 2026-10-08 | AX-first plugin for DeepSeek Harness | Stale-state rejection; actions tied to an unexpired observation; opaque `targetHandle` with explicit, unique-identity rebinding only; pid/window-routed SkyLight input; software cursor that waits for arrival before clicking. |
| [Sur-Cai/macos-computer-use-kit](https://github.com/Sur-Cai/macos-computer-use-kit) | 5 / 2026-10-03 | AX-first MCP + CLI, optional Jev guards | Stable `#ref`, diff re-observation, `action_sent` vs `verified`, retry advice (`retry` / `reobserve` / `never`), secure-field refusal, set-of-marks screenshots and Vision OCR only as fallbacks. |
| [bgivenb/flick-computer-use](https://github.com/bgivenb/flick-computer-use), [paulsmith/computer-use-jev](https://github.com/paulsmith/computer-use-jev) | 25 and 6 | Jev-driven goal runners (MCP / Go) | Jev batch of typed questions per step (action, target token, satisfied?, needs text?); stop and report the distribution below threshold; an LLM splits compound goals once, then Jev executes. |
| [sam-siavoshian/agent-notch](https://github.com/sam-siavoshian/agent-notch) | 20 / 2026-09-22 | Voice agent in the notch: long-press the cursor (~300 ms), talk, Claude computer use | Local `IntentRouter` fast paths before the model; live tool calls shown in the notch; kill-switch shortcut; cloud STT/TTS (the opposite of MacParakeet's posture). |
| [microsoft/UFO](https://github.com/microsoft/UFO) | 10.0k / 2026-10-07 | UFO³ multi-device agent framework | Hybrid UIA + visual control detection; speculative multi-action; MCP-based device agents. |
| [simular-ai/Agent-S](https://github.com/simular-ai/Agent-S) | 12.6k / 2026-10-08 | Open agentic framework; Simular Sai is 2nd on OSWorld 2.0 (73.0%) [S] | Generalist planner + grounding model. |
| [bytedance/UI-TARS-desktop](https://github.com/bytedance/UI-TARS-desktop), [microsoft/OmniParser](https://github.com/microsoft/OmniParser) | 39.2k, 25.5k | Vision-first agent stack; pure-vision screen parser | Vision grounding when AX is absent. |
| [cursorless-dev/cursorless](https://github.com/cursorless-dev/cursorless), [david-tejada/rango](https://github.com/david-tejada/rango) | pushes 2026-10-06 / 2026-10-05; Rango last release v0.8.7 (2026-03-09) | Voice code editing; browser hints | Steady maintenance, no major September release seen. |
| Talon Voice | **Talon 1.0 released 2026-09-20** [P] | Voice control platform | New GPU speech models: **Hum** (streaming dictation), **Song** (command recognition *with rejection*), **Tone** (speaker verification); HUD with floating subtitles; Accessibility Inspector; label/overlay system; CSS-style `axquery` over AX hierarchies. |

Research systems:

- **Tactile** (arXiv 2607.14443, 2026-07-16) [P]. A Swift macOS runtime with
  `ax`, `ax_ocr` and `ax_ocr_visual` modes. It compiles AX, OCR and visual
  evidence into ranked candidates (ranked by visibility, enabled state, name
  quality and action support) and records verification *strength*. It splits
  risky external actions into locate, draft, verify and submit. Codex improved
  from 41.1% to 50.0%, with larger gains on AX-friendly tasks (+10.0 points)
  than limited-AX tasks (+5.6 points).
- **Efficient GUI Agents survey** (arXiv 2609.02309, 2026-09) [P]. AX pruning
  to 2k tokens (FocusAgent cuts more than 50%, often more than 80%), diff-based
  history, set-of-marks, macro skills covering 2-5 steps, and fast/slow modes
  (slow thinking took one system from 2.6 s to 5.4 s per step).
- **OSWorld-Human** (MLSys 2026) [P]. Agents take 2.7-4.3x more steps than
  needed. Planning and reflection dominate latency. A full a11y tree costs 3-26 s
  to generate in element-heavy apps, plus thousands of tokens per step.
- **Screen2AX** (arXiv 2507.16704, 2025) [P]. A vision model that reconstructs
  macOS AX hierarchies (77% F1), motivated by poor AX coverage in real Mac apps.

### Grounding: what the field actually does

- **AX first, everywhere on the Mac.** Every serious 2026 Mac project and
  Codex resolve to an AX element first, then `AXPress` or another advertised
  action, then targeted events, with global pointer input last and opt-in.
  This matches MacParakeet's direction [P].
- **OCR and vision are fallbacks with explicit labels.** Set-of-marks
  screenshots, Vision OCR lines with coordinates, and model vision only for
  canvas or custom-drawn UI (computer-use-mcp, Sur-Cai, Tactile, Cua) [P].
- **Identity is the main source of bugs, and everyone fixes it the same way.**
  Ids carry a snapshot generation, stale ids fail loudly, rebinding happens only
  to a unique identity in the same process and window, and diffs keep surviving
  ids stable. This is the deep review's "fingerprint ids" recommendation, now
  validated by independent implementations.
- **Huge trees: skeleton, scoped drill-in, and visible-rows windowing.** This
  directly addresses the deep review's finding that Finder-class lists blow the
  2 s budget.
- **Outcome classification.** Several projects converged on four or five
  classes: verified, unsupported, dispatched-but-unverified (with a transport vs
  verification domain), and ambiguous. MacParakeet's receipts are already in
  this family.

## 3. UX patterns that make voice computer use feel seamless

| Pattern | Who does it (source) | Why it works | MacParakeet today |
|---|---|---|---|
| **Visible agent cursor that lands before acting** | Codex (wiggle while thinking) [S]; mac-computer-use, DSH, computer-use-mcp, Cua [P] | The user sees *where* before *what*; misfires are noticed immediately | None on screen; the panel only |
| **Target highlight / preview while holding** | MacParakeet storyboard ("Open Pricing beside highlighted link") | Lets the user correct before commit at zero cost | Designed, not built (`later.md`) |
| **Numbered or lettered hints** | Apple Voice Control "show numbers / show names", Windows Voice Access, Rango, Talon label overlays [P] | Fast disambiguation without reading labels | Numbers in the panel list only |
| **Hints refreshed on UI change** | Apple Frameworks Engineer: stale overlay numbers come from a stale AX tree; post layout-changed notifications (dev forums thread 844037) [P] | Wrong number to wrong control is the worst failure | Snapshot-bound ids; no overlay yet |
| **Describe what you see** | Apple OS 27 Voice Control ("purple folder", "guide about best restaurants") [P] | Users do not know labels; color, content and position are natural | Labels and roles only; OCR text for unlabeled UI |
| **Streaming transcript / intent line** | Talon 1.0 HUD with floating subtitles [P]; Gemini per-action `intent` [P]; agent-notch live tool calls [P] | Builds trust; the user sees the system understood | Partial transcript in the panel |
| **Full-duplex / barge-in** | GPT-Live on ChatGPT desktop [S] | Talking over the system to correct is natural | Stop and corrections exist; not duplex |
| **Countdown instead of modal for consequential clicks** | mac-computer-use: 2 s ring before Send/Delete/Buy [P]; Windows "wait time before acting" [P] | A cheap veto that keeps flow for expected actions | Modal-style explicit confirmation (20 s expiry) |
| **Plan preview before multi-step work** | Claude in Chrome plan approval [S]; MacParakeet storyboard task card | Bounds scope up front | Storyboarded |
| **Auto-yield to the human** | computer-use-mcp (hardware input seen); mac-computer-use (waits while you use the app; Esc pauses all) [P] | Takeover without a command | Manual takeover / Stop |
| **Point back / pick element** | mac-computer-use `pick_element`, `ask_user` [P] | Resolves "that one" when words fail | Numbered choices only |
| **Confirm only on hazards, with entity ownership** | Siri `OwnershipProvidingEntity` [P]; Gemini Desktop confirm list [S]; Anthropic docs [P] | Fewer prompts, each meaningful | Pay/delete/send floor (aligned) |
| **Command rejection at the recognizer** | Talon Song "recognition with rejection" [P] | Fewer phantom actions from noise | ASR transcript only |

## 4. Benchmarks and what they imply

| Benchmark | Latest numbers seen | Label | Note |
|---|---|---|---|
| OSWorld-Verified (369 tasks) | Qwen3.8 Max 86.1%, Claude Fable 5 and Mythos 5 85% (as of 2026-09-29) | [S] aggregator | Saturated. Setup-sensitive, per its own caveats. |
| OSWorld 2.0 (108 long-horizon workflows, ~318 tool calls) | Claude Fable 5.1 77.9%, Simular Sai 73.0%, GPT-6 Astra 72.6% (partial credit); best binary completion 32.0%; GPT-6 Astra about 40 min per task | [S] Steel leaderboard | Anthropic cites "OSWorld 2.1" for Sonnet 5.5 (80.1%) and Opus 5.5 (81.8%) [S]; naming is inconsistent [U]. |
| ScreenSpot-Pro (pixel grounding, pro apps) | GPT-6 Astra 92.7%, Claude Opus 4.8 87.9% (as of 2026-10-09); best open: Muse Glimmer 30B 75.4% | [S] aggregator | Vision grounding is now strong for frontier models, but at cloud-model latency and cost. |
| macOSWorld (202 tasks, 5 languages) | Original 2025 paper: Claude CUA 44.4%, OpenAI CUA 39.2%; Arabic 28.8% worse than English | [P] | Mac-native, multilingual. |
| MacArena (2026-06, 421 tasks, 50 apps, ICML workshop) | Rankings *invert* between ported and macOS-native tasks; a leader trails by over 26% on native tasks | [P] abstract | Linux-trained skill does not transfer to Mac UI. |
| MacAgentBench (2026-06, 676 tasks) | Claude Opus 4.6 + OpenClaw 73.7% pass@1; 39.2% as a pure GUI agent; pass@4 85.2% vs all-4 58.6% | [S] | Tools beat pure GUI; reliability gap of about 27 points. |
| OSWorld-Human (efficiency) | 2.7-4.3x excess steps; planning and reflection are 76-96% of latency; a11y tree 3-26 s | [P] | Latency is dominated by deliberation and observation size. |

What this implies for an AX-first, voice-driven design:

1. **Do not chase general-agent benchmarks.** They measure 40-minute tasks.
   Voice needs p95 under about 1.5 s from end of speech to visible effect. The
   relevant metrics are the ones MacParakeet defined but has not yet measured:
   voice-to-effect latency and wrong-target rate.
2. **AX-first is right on the Mac, but the full tree is the latency trap.**
   Gains concentrate where AX is good (Tactile). The cost is tree generation and
   tokens (OSWorld-Human). Prune, window and diff, and keep vision for gaps.
3. **Mac-native behavior differs from Linux-ported tasks** (MacArena). An eval
   corpus has to come from real Mac apps.
4. **Reliability, not peak success, is the gap** (pass@4 vs all-4). Verification
   plus "never replay uncertain effects" is the right design. Keep it.

## 5. Agent-exposure surfaces

- **MCP 2026-07-28** [P]. Stateless (no `initialize`), explicit server-minted
  handles for cross-call state, which suits snapshot ids. Multi-round-trip
  requests return `resultType: "input_required"` with `inputRequests`, and the
  client retries with `inputResponses`, which suits "confirmation required"
  without server-initiated requests. Tasks moved to an extension. Deterministic
  `tools/list` order helps caching. Roots, Sampling and Logging are deprecated.
- **Tool annotations are hints** (MCP blog, 2026-03-16) [P]. A client must not
  trust `readOnlyHint` or `destructiveHint` from untrusted servers. Real safety
  comes from deterministic controls. This matches MacParakeet's "local floor
  the model cannot lower".
- **Server-side gating is the norm in OSS Mac servers** [P]. computer-use-mcp
  returns "Confirmation required" until the caller retries with
  `confirm: true`, plus URL deny and confirm lists. mac-computer-use asks the
  user to approve each client app by code signature, and keeps the TCC grants
  in its own app so clients never receive Accessibility. Cua and Peekaboo
  return receipts that separate dispatch from verified effect.
- **Apple's routes** [P]. App Intents and App Schemas for Siri (first-party
  only); community bridges expose App Intents as MCP tools through Shortcuts
  ([VladUZH/intents-mcp](https://github.com/VladUZH/intents-mcp)). Safari MCP
  is for web-dev testing in an isolated window, so it is not a substitute for AX
  on the user's real tabs.

For MacParakeet (ADR-027): expose Voice Control's observe, act and verify as
`macparakeet-cli` / MCP tools with the same authority, receipt and confirmation
semantics. Use `input_required` for confirmations. Keep TCC permissions in the
app, not in clients. Approve each client by signature. The differentiator is
local speech plus safe AX effects, not another pixel driver.

## 6. Competitive read

- **Apple** covers natural-language targeting on iOS. If it reaches macOS
  (unverified), plain "click the blue button" stops being a differentiator.
  MacParakeet's remaining edges are: works with any app via AX plus local OCR,
  verified receipts and truthful endings, dictation and command in one tool,
  transparent logs, and an agent surface.
- **OpenAI Decisions API and CUA-S1** make the decision-model layer
  substitutable. Keep the client interface closed-set and provider-neutral so
  Jev, Decisions, or a local model can be A/B-tested on the replay corpus.
- **Codex and community servers** set the bar for visible, non-interfering
  action. Users will compare against an agent cursor and target highlight.

## 7. Ranked ideas for MacParakeet Voice Control

Ordered by expected impact on felt quality and grounding, weighted by effort.
Items 1-6 are UI/UX and grounding work that needs no change to model inputs.
Items that change Jev inputs must go through the replay-corpus A/B described in
the deep review.

1. **Pre-action target highlight overlay.** Use a click-through,
   non-activating, all-Spaces `NSPanel` that draws the chosen control's AX frame
   and label. Keep it visible while the user holds the key; flash it for about
   200 ms on one-shot commits. Set `sharingType = .none` so Vision OCR never
   reads it. *Why:* every leading 2026 agent shows where it will act; it is
   already storyboarded; it turns silent misfires into visible, correctable ones.
2. **On-screen numbered badges for disambiguation only.** Draw 1..N next to the
   competing candidates from the same snapshot, and remove them when the snapshot
   changes. *Why:* it is the Apple and Windows pattern, and binding badges to the
   snapshot avoids the stale-number failure Apple's own overlay shows (forum
   844037).
3. **Visible-rows windowing plus skeleton and scoped drill-in in
   `AXTreeWalk`.** Read the visible-rows or visible-children attributes for
   lists, tables and outlines; summarize off-screen counts; drill into one
   container on demand. *Why:* it fixes the known Finder-class over-budget walks
   and is the technique computer-use-mcp and Cua adopted.
4. **Fingerprint (generation-tagged) target ids plus diff observations.** *Why:*
   independent implementations converged on this. It deletes the rebinding
   special cases and the stale-id history leak class of bugs the deep review
   found.
5. **Event-driven freshness via `AXObserver`.** On the frontmost app, subscribe
   to focus, value, layout, created and destroyed notifications. Use them to
   invalidate or patch the snapshot and to confirm postconditions without fixed
   polling. *Why:* it cuts verify latency and is the platform-sanctioned
   freshness signal Apple's engineer points to.
6. **Speculative observation during hold.** Start the AX walk (and OCR, if
   enabled) on key-down. On release, reuse it unless an AX notification fired.
   *Why:* it moves the largest measured cost (observation) off the critical path.
7. **Streaming intent line.** As soon as the local grammar or exact-name
   resolution matches the partial transcript, show `Press "Send" in Mail`, then
   finalize on release; on a Jev decision, show the chosen action phrase. *Why:*
   it is Gemini's `intent` and Talon's HUD subtitles, and it builds trust before
   the effect.
8. **Confirmation card anchored to the target with the compiled effect**
   (recipient, amount, item count), answerable by voice ("yes" / "stop").
   Experiment with a 2 s countdown-to-proceed for **send** only, and keep an
   explicit yes for pay and delete. *Why:* mac-computer-use and Windows show that
   a veto window keeps flow. The send variant is a product decision, so record it
   in the contract if adopted.
9. **Delivery tier and outcome taxonomy in receipts.** Record AX action, then
   pid-routed event, then global; add `fallback_reasons` and a `failure_domain`
   (transport vs verification) to `unknown` receipts. *Why:* it makes live
   qualification logs actionable and matches the converged OSS contract.
10. **Visual descriptors for "say what you see".** Add a coarse dominant-color
    name, icon/OCR text and region ("toolbar", "sidebar", "dialog") to target
    criteria, computed locally from the already-captured window image. *Why:*
    Apple has set the user expectation ("the purple folder"). Region hints are
    already on the roadmap. This changes Jev inputs, so A/B it.
11. **Auto-yield on user input in the target app.** Pause the task when local
    mouse or keyboard events hit the target window during automation; resume
    with a fresh observation. *Why:* takeover without a command is now standard,
    and it reuses the existing pause/continue semantics.
12. **Provider-neutral closed-set decider, evaluated on the replay corpus.**
    Keep `JevDecisionClient` behind an interface, then compare Jev, the OpenAI
    Decisions API (when documented) and a local option (CUA-S1-4B text adapter,
    or Apple Foundation Models) on agreement, wrong-target rate, latency and
    `insufficient_evidence` rate. *Why:* the category now has competitors, and a
    local fallback serves the local-first posture. CUA-S1's confident-`skip`
    failure says "none/finished" must never count as proof.
13. **Expose observe/act/verify as MCP / CLI tools** with snapshot handles,
    `input_required` confirmations, per-client approval by code signature, and
    the same local consequence floor. *Why:* it is the ADR-027 agent surface and
    turns goal pursuit into delegation instead of site macros in core.
14. **Recognizer-level command rejection.** Use ASR token confidences, or a
    short-utterance rejection pass, to drop low-confidence closed-set commands
    before routing. *Why:* Talon 1.0 made rejection a first-class model feature,
    and phantom commands erode trust faster than misses.
15. **"Show names" / "What can I say here?" overlay on demand.** Briefly label
    the top actionable controls with their spoken names. *Why:* it teaches
    vocabulary without a manual, using the same overlay as items 1-2 at low
    marginal cost.

Not recommended:

- Building on the Codex private runtime (unsupported).
- Building on Safari MCP for the user's session (isolated window).
- Pixel-only vendor computer-use tools as the primary grounder (slow, and send
  screenshots off-device).

## Sources

Vendors:

- Claude Platform release notes (2026-08-19 to 2026-10-09):
  https://platform.claude.com/docs/en/release-notes/overview
- Claude computer use tool docs (`computer_toolset_20260801`):
  https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool
- Claude in Chrome permissions guide: https://support.claude.com/en/articles/12902446
- 9to5Mac, Claude Mac computer use (2026-03-23):
  https://9to5mac.com/2026/03/23/anthropic-is-giving-claude-the-ability-to-use-your-mac-for-you/
- OpenAI on X, Codex computer use on macOS (2026-04):
  https://x.com/OpenAI/status/2044827932145897652
- MacStories, Codex computer use (2026-04-17):
  https://www.macstories.net/notes/openais-new-codex-app-has-the-best-computer-use-feature-ive-ever-tested/
- Decrypt, DevDay 2026 (2026-09-29):
  https://decrypt.co/379584/openai-ai-agents-computers-devday-2026-everything-announced
- InfoQ, DevDay 2026 (2026-10-02): https://infoq.com/news/2026/10/openai-devday-2026
- AlphaSignal, Decisions API:
  https://alphasignal.ai/news/openai-s-decisions-api-gives-developers-a-constrained-gpt-6-luna-router
- ChatGPT Voice on desktop (2026-07-23):
  https://www.androidauthority.com/openai-chatgpt-voice-desktop-rollout-3691031/ and
  https://www.voiceos.com/blog/chatgpt-voice-desktop-control-your-computer
  (a competitor's blog; treat as secondary)
- ChatGPT Atlas retirement: https://en.wikipedia.org/wiki/ChatGPT_Atlas
- Google, computer use in Gemini 3.5 Flash (2026-06-24):
  https://blog.google/innovation-and-ai/models-and-research/gemini-models/introducing-computer-use-gemini-3-5-flash/
- Gemini API computer use docs: https://ai.google.dev/gemini-api/docs/computer-use
- BleepingComputer, Gemini Desktop Full Access (2026-10-03):
  https://bleepingcomputer.com/news/google/google-gemini-could-soon-get-full-access-to-your-macs-files-apps-and-the-web
- Apple newsroom, accessibility features (2026-05-19):
  https://www.apple.com/newsroom/2026/05/apple-unveils-new-accessibility-features-and-updates-with-apple-intelligence/
- MacRumors, accessibility preview (2026-05-19):
  https://www.macrumors.com/2026/05/19/new-accessibility-features-with-apple-intelligence/
- The Register, Voice Control (2026-05-21):
  https://www.theregister.com/ai-ml/2026/05/21/apple-adds-ai-smarts-to-voice-control-voiceover-and-magnifier-ahead-of-accessibility-day/5243594
- 9to5Mac, macOS 27 available (2026-09-14):
  https://9to5mac.com/2026/09/14/macos-27-golden-gate-now-available-here-is-everything-new/
- WWDC26 "Explore advanced App Intents features":
  https://developer.apple.com/videos/play/wwdc2026/343/
- WWDC26 "Build intelligent Siri experiences with App Schemas":
  https://developer.apple.com/videos/play/wwdc2026/240/
- Apple Developer Forums, Voice Control overlay out of sync:
  https://developer.apple.com/forums/thread/844037
- 9to5Mac, Safari 27 MCP (2026-09-17):
  https://9to5mac.com/2026/09/17/webkit-blog-breaks-down-whats-new-with-safari-27-for-developers-including-mcp-support/
  and WebKit, Safari 27.0 features: https://webkit.org/blog/18325/webkit-features-for-safari-27-0/
- Forkast, Safari MCP enterprise controls:
  https://forkast.news/safari-27-ships-a-native-mcp-server-and-apple-gave-enterprises-no-way-to-turn-it-off/
- Help Net Security, Full Disk Access (2026-10-05):
  https://www.helpnetsecurity.com/2026/10/05/macos-full-disk-access-updates/
  (Apple news: https://developer.apple.com/news/?id=p6zjojqw)
- Microsoft Voice Access history:
  https://support.microsoft.com/en-gb/accessibility/windows/voice-access/history-of-voice-access-updates
- Copilot Studio computer-using agents GA:
  https://techcommunity.microsoft.com/blog/copilot-studio-blog/computer-using-agents-in-microsoft-copilot-studio-are-now-generally-available/4519427
- Windows 365 for Agents MCP:
  https://learn.microsoft.com/en-us/microsoft-copilot-studio/mcp-windows-365-agents
- Perplexity Personal Computer on Mac:
  https://hothardware.com/news/perplexity-personal-computer-ai-mac

Open source and research (GitHub metadata observed 2026-10-09):

- https://github.com/trycua/cua (Cua Driver concepts:
  https://cua.ai/docs/cua-driver/concepts/how-cua-driver-works; CUA-S1 model card:
  https://github.com/trycua/cua/blob/main/libs/cua-s1/MODEL_CARD.md)
- https://github.com/openclaw/Peekaboo (v4.9.0, 2026-10-07)
- https://github.com/minghinmatthewlam/computer-use-mcp
- https://github.com/iamngoni/mac-computer-use
- https://github.com/Anionex/dsh-computer-use
- https://github.com/Sur-Cai/macos-computer-use-kit
- https://github.com/bgivenb/flick-computer-use
- https://github.com/paulsmith/computer-use-jev
- https://github.com/sam-siavoshian/agent-notch
- https://github.com/fitchmultz/macuse
- https://github.com/microsoft/UFO
- https://github.com/simular-ai/Agent-S
- https://github.com/bytedance/UI-TARS-desktop
- https://github.com/microsoft/OmniParser
- https://github.com/cursorless-dev/cursorless
- https://github.com/david-tejada/rango
- Talon changelog (1.0, 2026-09-20): https://talonvoice.com/dl/latest/changelog.html
- Tactile (2026-07-16): https://arxiv.org/html/2607.14443v1
- Efficient GUI Agents survey (2026-09): https://arxiv.org/html/2609.02309v1
- OSWorld-Human (MLSys 2026): https://arxiv.org/html/2506.16042
- Screen2AX: https://arxiv.org/html/2507.16704v1
- macOSWorld: https://arxiv.org/abs/2506.04135
- MacArena (2026-06-04): https://arxiv.org/abs/2606.06560
- MacAgentBench summary: https://jarvis.ceo/mac-agent-benchmark-gap

Benchmarks (aggregators, secondary):

- https://benchlm.ai/benchmarks/osworld-verified
- https://leaderboard.steel.dev/leaderboards/osworld-2/
- https://benchlm.ai/benchmarks/screenspot-pro

MCP:

- Spec 2026-07-28 changelog:
  https://modelcontextprotocol.io/specification/2026-07-28/changelog
- Tool annotations post (2026-03-16):
  https://blog.modelcontextprotocol.io/posts/2026-03-16-tool-annotations/
