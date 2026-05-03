# ADR-018: Live Meeting Ask Tab

> Status: IMPLEMENTED (Ask half — Insights dropped per 2026-04-24 amendment; quick-prompt model unified per 2026-05-03 amendment; pin cap removed per 2026-05-03 amendment)
> Date: 2026-04-19 (proposed) · Amended 2026-04-24, 2026-05-03, 2026-05-03 · Implemented 2026-04-24
> Related: ADR-011 (LLM providers), ADR-013 (prompt library + multi-summary), ADR-014 (meeting recording), ADR-016 (centralized STT runtime), ADR-017 (calendar auto-start)

## Amendment (2026-05-03, later) — Pin cap removed

The `QuickPrompt.pinnedCap = 5` constraint shipped earlier on 2026-05-03 (see
the prior amendment) is **removed**. Pinning is now unbounded; the
after-response strip is a horizontal `ScrollView` with a leading + trailing
edge-fade gradient that makes overflow legible without a visible scrollbar.

**Why the second-second pivot.** The cap's only justification was layout
("must fit visually without wrapping"). Once we accepted scroll as the
overflow mechanism, the cap stopped doing work — it persisted only as a
paternalistic friction surface (the swap-picker `confirmationDialog`) that
forced curation decisions the user did not ask for. A user who pins 12
prompts experiences natural feedback (the strip is now slower to scan than
the sparkle menu) and self-corrects; they do not need a wall.

**What changed concretely.**
- `QuickPrompt.pinnedCap` constant removed.
- `QuickPromptRepository`: `swapPin`, `saveAndPin`, and the
  `SetPinnedResult.capExceeded` case are removed; `setPinned` no longer
  guards on cap; `fetchPinned` no longer applies a `LIMIT`.
- `QuickPromptsViewModel`: `swapRequest`, `confirmSwap`, `cancelSwap`, and
  the `SwapRequest` struct are removed; `togglePin` is now unconditional;
  `visiblePinned` no longer applies a `prefix(...)` cap.
- `AskPromptsSheet`: the swap-picker `confirmationDialog` and `n/cap` count
  display are removed; the header shows just `Pinned · n`.
- CLI: `QuickPromptCLIError.pinCapExceeded` removed; `add --pin` and `pin`
  no longer return cap-exceeded errors.
- View layer: `LiveAskPaneView.followUpRow` keeps its existing
  `ScrollView(.horizontal)` and gains a `.mask(LinearGradient(...))` with
  4% leading and trailing transparent stops — invisible when content fits
  the viewport (overlapping only horizontal padding) and reads as a soft
  horizon when content overflows.

The 5 pinned built-ins still seed by default, providing a strong "here's
what's worth pinning" curation signal. Pin remains an explicit user knob;
nothing has changed about what pinning *means*, only what its upper bound
is.

## Amendment (2026-05-03) — Unified quick-prompt model

The starter / follow-up two-kind split shipped on 2026-05-02 (see Decision §2)
is collapsed into one library with an `isPinned: Bool` flag. Pinned prompts
surface as compact pills in the after-response strip (cap = 5); everything
visible (pinned + unpinned) shows in the empty Ask state and the sparkle
popover, grouped by `groupLabel`. Pin is the single explicit knob users
control to move a prompt between the two render surfaces.

**Why the second pivot.** The categorical split (`kind = .starter | .followUp`)
was load-bearing only for placement, not for semantics — both flavors are
"prebuilt prompts to inspire." The split surfaced as cognitive overhead in
the editor sheet (two sections, two Add affordances, two Reset menus) and in
the CLI (`--kind` on every relevant subcommand) without a corresponding user
benefit. Unifying gives users one mental model, one editor, and one explicit
control (the pin icon) that parallels the existing visibility toggle.

**Pin metaphor.** Pin is universally understood (Notion sidebar, Slack
starred, Linear pinned views, Finder favorites). The pin icon is row-level
and always visible — filled in pinned, outline elsewhere. When pinning would
exceed the cap, a swap-picker confirmationDialog opens listing the current
five pinned; selecting one performs an atomic unpin-then-pin in a single DB
transaction.

**What changed concretely.**
- `QuickPrompt.Kind` removed; `isPinned: Bool` added; `QuickPrompt.pinnedCap = 5`.
- DB migration `v0.10.1-quick-prompts-pin` adds `isPinned`, derives it
  from `kind == 'follow_up'`, drops the legacy index + `kind` column, and
  creates a new `(isPinned, sortOrder)` index. One-way migration.
- `QuickPromptBundle` schema bumped to v2 (`isPinned: Bool` per prompt).
  v1 files still decode — `kind == "follow_up"` maps to `isPinned: true`.
- CLI bumped to 2.0.0 with breaking changes: `--kind` removed from `list /
  add / export / restore-defaults`; `--pinned <true|false>` filters added
  to `list` and `export`; `add --pinned` added for immediate pinning; new
  `pin` and `unpin` subcommands added; the `kind` JSON field is gone.
- `groupLabel` is now valid on every prompt (was previously starter-only).
- New seeds preserve every UUID from the v1 set: 9 unpinned (CATCH UP /
  CAPTURE / CHALLENGE) + 5 pinned (Tell me more, Why?, Give an example,
  Counter-argument?, TL;DR).

The Decision section §2 below describes the v1 (kind-based) shape and is
preserved for historical context. The current implementation matches this
amendment.

## Amendment (2026-04-24)

The original draft of this ADR proposed three live tabs in the meeting panel — **Transcript / Insights / Ask** — with Insights as a debounced, auto-refreshing four-section LLM view of the in-flight meeting. After a design review during implementation, the Insights tab was dropped and the live experience reduced to two tabs: **Transcript / Ask**. This file documents what actually shipped.

**Why the pivot.** Insights would have:
- Auto-fired LLM calls every ~30s for the duration of every recorded meeting (real cost for cloud users, even if the panel was never opened),
- Required a debounce policy, in-flight cancellation, section parsing of free-form LLM output, and a staleness indicator,
- Doubled the live panel's UI surface area for a passive read that the user can pull on demand from Ask anyway.

The framing that won was **"thinking partner, not stenographer."** A curated set of one-tap pills on the Ask tab gives the user the same outputs (summary, what-did-I-miss, action items) on demand — once they actually want them. The cost surface, the parsing brittleness, and the always-on shimmer go away. What remains is one well-designed surface that does one thing well.

The trade-off accepted: the user loses passive-glance value (look up at the panel and see "they just decided to ship Friday" without asking). For long meetings this is real, but the cost of an Insights pane to reclaim it isn't justified by v1 user demand. Re-open if telemetry says otherwise.

## Context

ADR-014 ships live meeting recording with a single-pane panel: a rolling speaker-attributed transcript with Copy/Auto-scroll/Stop in the footer. After the meeting finalizes, the user is routed to `TranscriptResultView`, which already has Transcript / Result / Chat / Speakers tabs (ADR-013).

The user's ask was to bring a subset of that rich experience into the live panel: while the meeting is running, the user can switch between watching the live transcript and asking "what did I miss?" mid-call. When the meeting ends, the live conversation carries over to the post-finalize detail view so nothing is thrown away.

The underlying primitives already existed:

- `LLMService.chatStream(question:transcript:history:)` — AsyncThrowingStream of tokens against a chat-style prompt, with history
- `TranscriptChatViewModel` — already accepts a `transcriptText` parameter and streams responses against it
- Live transcript itself is already yielded continuously via `MeetingRecordingService.transcriptUpdates`

What was missing: a place for chat in the *live* panel, an in-memory mode for the chat VM (no transcriptionId yet), and a clean handoff so the live conversation persists when the meeting finalizes.

## Decision

### 1. Two tabs in the live panel: Transcript / Ask

`MeetingRecordingPanelView` gains a thin tab bar between the header and the content area:

```
┌─────────────────────────────────────┐
│ ● Recording 6:03 · 672 words        │
├─────────────────────────────────────┤
│  Transcript    Ask                  │  ← thin row, accent-capsule underline on active
├─────────────────────────────────────┤
│                                     │
│ content for selected tab            │
│                                     │
└─────────────────────────────────────┘
```

- **Transcript** — unchanged from today; rolling speaker-attributed live transcript with Copy/Auto-scroll/Stop in the footer
- **Ask** — chat UI; user asks questions against the live transcript; supports streaming. Footer (Copy/Auto-scroll/Stop) is hidden entirely on Ask so the chat owns the bottom; the floating recording pill is the canonical Stop control

Default selected tab is `.transcript`. `Cmd+1` / `Cmd+2` switch tabs from the keyboard.

### 2. Thinking-partner pills in two surfaces

Pills are the dominant entry point. They serve two roles, with two distinct visual treatments:

**Empty-state starter pills** (vertical, sparkle icon, called out under a "Quick prompts" label):

| Label | Purpose |
|-------|---------|
| Summarize so far | Re-orient |
| What did I miss? | Catch up |
| What question is worth asking? | Sharpen the user's next move |
| What's worth pushing back on? | Invite scrutiny |
| Where are we going in circles? | Surface drift |
| What's unresolved? | Pull open threads |

**Persistent follow-up pills** (compact horizontal-scroll row above the input, visible whenever a conversation exists):

| Tell me more · Summarize so far · What did I miss? · Why? · Give an example · Counter-argument? · Action items? · TL;DR |
|---|

The follow-up row reuses Summarize and Missed because both stay useful as the transcript grows. The other follow-ups are framed as "drill deeper" actions.

### 3. Pills carry a label and a comprehensive prompt

Each pill is a `LiveAskPrompt(label: String, prompt: String)`. The label is what renders on the chip and in the user's bubble. The `prompt` is sent to the LLM in place of the label so the model gets enough scaffolding to answer well, while the thread reads conversational.

`TranscriptChatViewModel.sendMessage(richPrompt:)` accepts the prompt as an optional override — when supplied (non-empty after trimming), it replaces `inputText` as the `question` to `LLMService.chatStream`. The visible bubble and persisted `chatHistory` continue to record `inputText` (the label).

Example: tapping "Tell me more" sends *"Expand on your previous response. Go deeper with concrete details and any nuances worth knowing."* to the LLM; the bubble and the persisted message both show "Tell me more".

### 4. Live in-memory mode in TranscriptChatViewModel

For Ask to work mid-recording — before any `Transcription` row exists — `TranscriptChatViewModel.sendMessage(...)` skips the lazy `ChatConversation` creation when both `transcriptionId` and `conversationRepo` are `nil`. Messages still accumulate in `messages` and `chatHistory` normally; nothing is persisted until promotion.

The transcript text is fed continuously via a new `updateTranscriptText(_:)` (does not clear history; distinct from the existing `updateTranscript(_:)` which does). `MeetingRecordingPanelViewModel` calls this on every transcript-preview tick with a clean speaker-labeled join (no bracketed timestamps — LLMs do better without them).

### 5. Live → persisted handoff at finalize

When the meeting stops and transcription completes, `MeetingRecordingFlowCoordinator` calls a new `TranscriptChatViewModel.bindPersistedConversation(transcriptionId:transcriptionRepo:conversationRepo:)`. This creates one `ChatConversation` linked to the finalized transcription, writes the entire in-memory `chatHistory` in a single repo call, and pushes it to the front of `conversations`.

The post-finalize `TranscriptResultView` (ADR-013) is unchanged — its existing Chat tab discovers the new conversation through `ChatConversationRepository.fetchAll(transcriptionId:)` and renders it like any other chat thread. No data loss, no duplication, no UI changes to the post-meeting surface.

### 6. Convenience touches

Polish that matters for the daily-driver feel:

- **Auto-focus** the input ~100ms after the Ask pane appears so typing works on tab switch without a click.
- **Field stays enabled while streaming.** SwiftUI strips focus from a field the moment it becomes disabled, and re-focusing inside an `NSPanel` after an enable toggle is unreliable. The input is only disabled when no LLM provider is configured. The `send()` guard prevents double-sends; the user can also queue text mid-stream.
- **Escape** cancels an in-flight assistant response (no button click needed).
- **Cmd+1 / Cmd+2** switch tabs.
- **TypingIndicator** — three accent dots wave gracefully (~1.4s cycle) while the assistant is composing, replacing the placeholder "…".

### 7. No-LLM state is non-blocking

If no LLM provider is configured, the Ask tab renders an empty state:

> *"Ask needs an AI provider. Add one in Settings → AI Providers. Recording works without it."*

with an "Open Settings" button. The recording itself continues uninterrupted; the Transcript tab is unaffected; finalize still works. Users who never configure LLM use MacParakeet's meeting recording exactly as it works today.

### 8. Live Ask does not contend with STT for the scheduler

The `LLMService` calls run against cloud or local LLM providers over HTTP. They do **not** go through `STTScheduler` (ADR-016). There is no contention with dictation or meeting live-chunk transcription: LLM and STT are separate compute paths (LLM = network or local Ollama process; STT = ANE/CoreML).

## Architecture

```
┌──────────────────────────────────────────────────────────┐
│              MeetingRecordingPanelView                   │
│   ┌────────────┐ ┌─────────┐                             │
│   │ Transcript │ │   Ask   │   ← tab bar (Cmd+1/Cmd+2)   │
│   └────────────┘ └─────────┘                             │
│                                                          │
│   ┌──────────────────────────────────────────────────┐   │
│   │ MeetingRecordingPanelViewModel                   │   │
│   │   ├── previewLines            (existing)         │   │
│   │   ├── chatTranscript: String  (computed,         │   │
│   │   │   pushed to chatViewModel each preview tick) │   │
│   │   ├── selectedTab: LivePanelTab                  │   │
│   │   └── chatViewModel: TranscriptChatViewModel     │   │
│   └──────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
                                │
                                ▼
                    ┌──────────────────────────┐
                    │ TranscriptChatViewModel  │
                    │   (existing, extended)   │
                    │                          │
                    │   uses LLMService        │
                    │        .chatStream       │
                    └──────────────────────────┘
                                │
                                ▼
                    ┌──────────────────────────┐
                    │   LLMService             │
                    │   (existing)             │
                    └──────────────────────────┘
```

## Rationale

### Why drop Insights (the headline change in this amendment)

Insights would have made meeting recording reach feature parity with Granola-class tools that show a standing AI view of the call. The cost: an actor with debounce policy + delta gates + cancellation, periodic LLM calls firing whether or not the user looks, free-form section-parsing, a staleness indicator, an extra final-finalize round to persist results, and meaningfully more UI surface.

Pull-on-demand pills in Ask cover the same use cases (summary, what-did-I-miss, action items) at zero idle cost and with deterministic UX. The product stance shifts from "we maintain a view of your meeting" to "we help you think during your meeting." The latter feels more like MacParakeet — a small tool with one clear edge — and less like a feature checklist.

### Why label-vs-prompt instead of bare strings

Sending "Tell me more" to the LLM gives the model essentially no instruction. Sending "Expand on your previous response with concrete details and any nuances worth knowing" gives it scaffolding. But putting that whole sentence in the user's chat bubble breaks the conversational read. The split lets each side win.

### Why "thinking-partner" framing for the pills

Generic chat pills ("Summarize", "Translate", "Bullet points") are useful but interchangeable with every other LLM product. "What question is worth asking?" / "Where are we going in circles?" / "What's worth pushing back on?" are designed to make the *user* sharper in the meeting, not just produce summaries. This is the differentiation lever — pills become product opinion, not chrome.

### Why reuse `TranscriptChatViewModel` instead of writing a live-specific chat VM

The chat VM was already built for streaming messages against a transcript with history. The only thing it didn't know is that the transcript is growing and that there might not be a transcription row to bind to yet. Both gaps are small extensions (`updateTranscriptText`, in-memory mode in `sendMessage`, `bindPersistedConversation`) and keep the live and post-meeting surfaces operating on the same primitive — so a feature added to chat is added to both at once.

### Why ship without follow-ups suggested by the LLM itself

Two ways the follow-up row could be smarter: (a) embed "suggested follow-ups" in the LLM's response and parse them out, (b) fire a separate LLM call after each response. (a) adds parsing brittleness and is visible when it breaks. (b) doubles per-turn cost. Neither earns its keep against a curated static set that's right ~80% of the time and never fails.

## Consequences

### Positive

- Live meeting recording now has a useful chat affordance with one-tap depth.
- Thinking-partner framing differentiates from every other "chat with your meeting" tool on the market.
- Zero idle LLM cost — nothing fires unless the user taps a pill or sends a message.
- No new tables for the chat plumbing: `ChatConversation` is reused for the
  live thread post-finalize. (The 2026-05-03 amendment adds a one-way schema
  migration on `quick_prompts` — see the amendment block above.)
- Live and finalized surfaces share state — no data loss on the meeting → transcription transition.
- No-LLM-key users get the same recording they had before; this is pure addition.

### Negative

- **No passive glance value.** A user who tunes out can no longer look up at the panel and see "they just decided X." They have to tap a pill. For long meetings this is real, but the v1 cost-benefit of an Insights pane to reclaim it doesn't justify it.
- **In-memory chat is lost if transcription fails.** If the user has a substantive Ask conversation and then transcription errors out (rare), the chat is lost along with the transcription. A JSON sidecar persistence layer is sketched as "Future Work" below.
- **English-first pills.** Quick-prompt labels are hardcoded English. Localization deferred until multilingual demand surfaces.

### Neutral

- LLM cost from Ask is bounded by user action — a quiet meeting is free.
- Privacy posture matches the existing post-meeting chat (ADR-011): if a cloud LLM is configured, transcripts are sent on each user-initiated request.

## Implementation

### Core (MacParakeetCore)

For the original Ask shipment: unchanged — no new actors, services, or schema.

For the 2026-05-03 quick-prompt unification (see amendment): adds the
`v0.10.1-quick-prompts-pin` migration to `DatabaseManager`, replaces
`QuickPrompt.Kind` with `isPinned: Bool` plus `QuickPrompt.pinnedCap = 5`,
extends `QuickPromptRepository` with `setPinned`, `swapPin`, `saveAndPin`,
`fetchPinned`, and bucket-scoped `reorder(ids:pinned:)`, and bumps
`QuickPromptBundle` schema to v2 with v1 (`kind`-based) decoder fallback.

### ViewModels (MacParakeetViewModels)

- `MeetingRecordingPanelViewModel` (extended): `LivePanelTab` enum, `selectedTab`, composed `chatViewModel: TranscriptChatViewModel`, `chatTranscript` computed plain-text projection of `previewLines`, push to chat VM on every `updatePreviewLines(...)`.
- `TranscriptChatViewModel` (extended):
  - In-memory mode in `sendMessage(richPrompt:)` when both `transcriptionId` and `conversationRepo` are nil.
  - `updateTranscriptText(_:)` — set transcript text without clearing history.
  - `bindPersistedConversation(transcriptionId:transcriptionRepo:conversationRepo:)` — promote in-memory thread to a `ChatConversation` in one repo write at finalize time.
  - Optional `richPrompt` parameter on `sendMessage(...)` so pills can ship a comprehensive prompt while the bubble shows the short label.

### View layer (MacParakeet)

- `MeetingRecordingPanelView` — tab bar (text + 1pt accent capsule underline, `Cmd+1/2`); `paneContent` switches between Transcript and Ask; footer hidden on Ask.
- `LiveAskPaneView` *(new)* — scrollable message thread, vertical "Quick prompts" stack of starter pills in the empty state, horizontal-scroll follow-up row above the input once messages exist, polished input bar (14pt corners, hairline border), `TypingIndicator` (three accent dots, 1.4s wave), no-LLM empty state with Settings CTA.

### Wiring (MacParakeet App)

- `MeetingRecordingFlowCoordinator` — accepts `transcriptionRepo`, `conversationRepo`, `configStore`, `cliConfigStore`, `llmService?` at init. Configures the panel's chatViewModel for in-memory live mode at `.showRecordingPill`. Calls `bindPersistedConversation(...)` at `.navigateToTranscription` so the live thread carries onto `TranscriptResultView`'s Chat tab. New `updateLLMService(_:)` forwards provider changes.
- `AppEnvironmentConfigurer` — passes the new deps; weak-holds the meeting coordinator so `refreshLLMAvailability(in:)` forwards LLM provider changes to the live chat VM alongside the existing singleton chat VM.

### Pill copy (English-first; hardcoded)

See decision §2 for the full lists.

## Phased Rollout (actual)

1. **Phase A — Tab shell + Transcript extraction** ✅ shipped 2026-04-24 (commit `e574135a`)
2. **Phase B — Live Insights service + pane** — **dropped** per the amendment above
3. **Phase C — Live Ask** ✅ shipped 2026-04-24 (commit `e574135a` + polish in `80317e70`)
4. **Phase D — Convenience polish** — not originally scoped; rolled in as part of Phase C polish: auto-focus on tab switch, ESC cancel, Cmd+1/Cmd+2, label/prompt split for pills, focus-stays-on-Enter fix.

## Future Work

- **Transcription-failure chat recovery.** If transcription fails after stop, the in-memory Ask thread is lost. Sketch: write `chatHistory` to `~/Library/Application Support/MacParakeet/pending-chat-{recordingId}.json` on every send; delete the sidecar on successful finalize; on next launch, surface a "Recover chat" entry if a sidecar is found. ~50 lines, no schema migration. Defer until telemetry or a user complaint says it matters.
- **Localization** of quick-prompt copy.
- **Markdown rendering** in assistant bubbles (bold, lists, code blocks). Currently plain text; would lift the visual quality of long responses without changing the data model.
- **Per-message actions** (copy, regenerate) on hover in the live thread. The post-finalize Chat tab does not have these either; could be added in both surfaces together.
- **Reopen Insights** if telemetry indicates users want passive-glance value enough to justify the LLM cost surface.
