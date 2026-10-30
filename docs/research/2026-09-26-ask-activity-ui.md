# Native Ask activity UI: focused OSS research

Reviewed 2026-09-26 PDT (2026-09-27 UTC). Primary source inspection only; no dependencies adopted, app execution, or visual/runtime claims. Recommendations below are SwiftUI adaptations, not claims these projects use SwiftUI.

## Popular sample, not a ranking

GitHub repository API `stargazers_count` verified during this review:

| Project | Stars | Pinned revision |
| --- | ---: | --- |
| [Open WebUI](https://api.github.com/repos/open-webui/open-webui) | 153,271 | `8bd8b4fac5e059578ac0c74b3c18d11139f88b7d` |
| [LobeHub](https://api.github.com/repos/lobehub/lobehub) | 82,838 | `f1c5847ff16299efe438b929b01c766c7e5d3ba3` (canary) |
| [LibreChat](https://api.github.com/repos/LibreChat-AI/LibreChat) | 44,981 | `7b2362d7a7c6148b84850924dc7fa5fc43307923` |
| [assistant-ui](https://api.github.com/repos/assistant-ui/assistant-ui) | 12,317 | `19eb2eb3fa94248c40f1945ec7a5fe6ae3a27d60` |

These are an intentionally selected popular sample, not evidence of the four most popular or best designs. LibreChat now redirects from danny-avila to LibreChat-AI.

## Five concrete patterns

### 1. One compact activity disclosure per answer

Open WebUI places the latest status on the disclosure button, with an optional connected history underneath and an accessible expanded state. LibreChat groups tool activity and defaults completed groups to collapsed, including single-call groups; it retains explicit user expansion overrides. assistant-ui provides a controlled/uncontrolled collapsed tool group and locks scroll during its expansion transition.

Native adaptation: put a quiet `Searching meetings…` / `Read 8 passages across 3 meetings` row above the answer; disclosure reveals a concise list of steps. Keep stable identities per run and step. User expansion always wins; never repeatedly auto-expand as tokens arrive. Prefer a minimal native DisclosureGroup or button with proper accessibility over a stack of decorated cards. Avoid showing raw JSON arguments or model reasoning.

Sources: [Open WebUI status history](https://github.com/open-webui/open-webui/blob/8bd8b4fac5e059578ac0c74b3c18d11139f88b7d/src/lib/components/chat/Messages/ResponseMessage/StatusHistory.svelte#L30-L73), [LibreChat settled groups and overrides](https://github.com/LibreChat-AI/LibreChat/blob/7b2362d7a7c6148b84850924dc7fa5fc43307923/client/src/components/Chat/Messages/Content/ToolCallGroup.tsx#L261-L283), [assistant-ui expansion](https://github.com/assistant-ui/assistant-ui/blob/19eb2eb3fa94248c40f1945ec7a5fe6ae3a27d60/packages/ui/src/components/react/assistant-ui/elements/tool-group.aui.tsx#L44-L90).

### 2. One authoritative phase drives every presentation

LibreChat centralizes running/completed/cancelled/failed into one resolver used by labels, icon, shimmer, duration, and announcements. Explicit terminal status wins; cancellation is not inferred from animation lag. LobeHub treats a completed empty result as complete and distinguishes skipped/aborted, error, pending intervention, and success.

Native adaptation: use a typed phase and host-authored labels (`Finding sources`, `Searching`, `Reading`, `Writing answer`). Completion, stop, failure, and incomplete evidence must settle the spinner and accessibility state together. A user Stop is neutral `Stopped`, not a red error or `Complete`. “No matches” is a successful search result, not a run failure. Do not invent percentage progress for unknown-duration model work. Gate completion on actual run outcome, not whether the text animation caught up.

Sources: [LibreChat phase resolver](https://github.com/LibreChat-AI/LibreChat/blob/7b2362d7a7c6148b84850924dc7fa5fc43307923/client/src/utils/toolCallPhase.ts#L1-L88), [LobeHub status semantics](https://github.com/lobehub/lobehub/blob/f1c5847ff16299efe438b929b01c766c7e5d3ba3/src/features/Conversation/Messages/AssistantGroup/Tool/Inspector/StatusIndicator.tsx#L43-L84).

### 3. The reader owns scrolling

assistant-ui follows newly growing content only while the viewport is following the bottom. A deliberate upward gesture cancels pending bottom intent. A jump-to-bottom event resumes it. It distinguishes downward smooth-scroll intermediate events from user navigation and uses immediate scrolling for ongoing content growth instead of stacking smooth animations. LobeHub additionally exposes streaming auto-scroll settings.

Native adaptation: follow while already near the bottom; suspend immediately when the user scrolls up. Offer a small `Latest` button to resume. New tool rows, opening a disclosure, and selecting text must not pull the user away. Explicit navigation can animate; streaming follow should be coalesced and immediate. Keep scroll state scoped to the conversation so switching threads cannot inherit the prior thread's pending jump.

Sources: [assistant-ui scroll ownership](https://github.com/assistant-ui/assistant-ui/blob/19eb2eb3fa94248c40f1945ec7a5fe6ae3a27d60/packages/react/src/primitives/thread/useThreadViewportAutoScroll.ts#L144-L220), [gesture cancellation](https://github.com/assistant-ui/assistant-ui/blob/19eb2eb3fa94248c40f1945ec7a5fe6ae3a27d60/packages/react/src/primitives/thread/useThreadViewportAutoScroll.ts#L224-L284), [LobeHub setting](https://github.com/lobehub/lobehub/blob/f1c5847ff16299efe438b929b01c766c7e5d3ba3/src/features/Conversation/ChatList/components/AutoScroll/useAutoScrollEnabled.ts#L7-L26).

### 4. Smooth rendering with authoritative final text

assistant-ui bounds characters revealed per frame and can throttle text commits; it preserves a final commit and handles streams that finish before the first animation frame. Both assistant-ui and LibreChat disable smoothing under reduced motion. These are useful implementation precedents, not a reason to add an artificial typewriter delay.

Native adaptation: keep canonical received text separate from rendered presentation. Coalesce small deltas before updating Markdown; preserve stable message identity and flush the exact latest text on completion, stop, failure, or thread switch. Avoid reparsing every token if the existing streaming renderer already supports bounded updates. Respect Reduce Motion for disclosure transitions and shimmer; don't animate the entire Markdown body. Never announce individual tokens to VoiceOver.

Sources: [assistant-ui smooth commit contract](https://github.com/assistant-ui/assistant-ui/blob/19eb2eb3fa94248c40f1945ec7a5fe6ae3a27d60/packages/react/src/utils/smooth/useSmooth.ts#L28-L45), [completion/reduced motion](https://github.com/assistant-ui/assistant-ui/blob/19eb2eb3fa94248c40f1945ec7a5fe6ae3a27d60/packages/react/src/utils/smooth/useSmooth.ts#L133-L161), [LibreChat motion setting](https://github.com/LibreChat-AI/LibreChat/blob/7b2362d7a7c6148b84850924dc7fa5fc43307923/client/src/hooks/Messages/useSmoothStreaming.ts#L1-L16).

### 5. Settle into an honest, compact receipt

Open WebUI's status history and LibreChat's settled activity groups retain inspectable work while reducing visual prominence. assistant-ui explicitly groups consecutive tool calls and supports separate sources/citation UI. None of these generic components establishes complete corpus coverage or the truth of an answer.

Native adaptation: settle the live row into a receipt such as `3 meetings · 8 passages read`, with available source links and a bounded list of observed steps. Count only successful host-validated observations; keep searched sources distinct from sources actually read/cited. Retain `Stopped` or the sanitized failure reason for incomplete runs. Do not claim `All meetings checked`, `Verified answer`, or exhaustive coverage from a partial search. If adding persistence is outside the current scope, render the live receipt honestly without implying it survives reopening.

Sources: [Open WebUI status disclosure](https://github.com/open-webui/open-webui/blob/8bd8b4fac5e059578ac0c74b3c18d11139f88b7d/src/lib/components/chat/Messages/ResponseMessage/StatusHistory.svelte#L30-L73), [LibreChat completed grouping](https://github.com/LibreChat-AI/LibreChat/blob/7b2362d7a7c6148b84850924dc7fa5fc43307923/client/src/components/Chat/Messages/Content/ToolCallGroup.tsx#L261-L283), [assistant-ui thread anatomy and grouped slots](https://www.assistant-ui.com/elements/thread).

## Recommended visual direction

A native transcript layout with generous reading width, restrained secondary typography, one small phase indicator, and a thin connected activity list inside a disclosure. Let the answer and citation chips dominate; keep Stop easy to find. Reuse MacParakeet's existing palette, spacing, button treatment, Markdown component, and evidence navigation. Translate interaction contracts, not web styling or dependencies.

Minimum checks: streaming while at bottom; scroll up while streaming; Latest resumes; expand/collapse mid-run; stop before first token; stop after partial answer; empty search result; tool failure; completed reopening if persisted; thread switch during streaming; VoiceOver labels; Reduce Motion. Test state transitions and user scroll ownership rather than screenshot-only polish.

## Implemented scope and verification

The native Ask workspace now renders host-authored activity with stable step IDs,
returned-result counts, explicit planning/writing/validation phases, and distinct
terminal outcomes. Activity is saved with the terminal answer; legacy messages
continue to decode without it. Disclosure state stays under the reader's control.
Streaming text updates are coalesced at 33 ms, with the saved service response
remaining authoritative. Small upward scrolls suspend following immediately;
Latest resumes it. The CLI exposes the same additive phase and step events.

Focused service, view-model, CLI, Pi helper, scroll-policy, and AppKit-hosted UI
checks passed. The actual published Pi loop was exercised with a scripted model.
Native activity snapshots cover narrow/wide widths, light/dark appearance, and
terminal states; whole-workspace fixtures cover saved and streaming answers.
Those fixtures use synthetic content and are not full-application or real-model
qualification. Ask's existing feature flag and provider/source boundaries remain
unchanged. Independent correctness, SwiftUI, and Claude reviews found a small
upward-scroll regression, now fixed and covered for 2, 10, and 30 point gestures.
