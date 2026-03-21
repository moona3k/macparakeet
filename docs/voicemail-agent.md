# Voicemail Agent

> Status: **PROPOSAL** — Exploring concept, not yet specced

## Core Concept

MacParakeet is the **voice input to your personal AI agent.**

You speak. MacParakeet captures and transcribes it locally. Then it delivers the message to your agent — whatever that agent is. The agent processes it and sends results back.

It's a voicemail. Everyone knows what a voicemail is. You speak, hang up, and someone gets back to you.

## The Insight

Every person will eventually have a personal AI agent. The agent needs a voice. MacParakeet is already the best system-wide voice capture on Mac — always on, never steals focus, fast local transcription. The leap from "paste text into apps" to "send text to your agent" is tiny.

MacParakeet doesn't need to **be** the agent. It needs to be the best **mic** for your agent.

```
Dictation  → voice → text → paste into app      (immediate)
Voicemail  → voice → text → send to agent → result (async)
```

Same capture UX, different destination.

## Architecture: Separation of Concerns

```
┌─────────────────────────────────────────────┐
│  MacParakeet (Capture Layer)                │
│                                             │
│  - System-wide hotkey                       │
│  - Local transcription (Parakeet/ANE)       │
│  - Voicemail inbox UI                       │
│  - Audio never leaves device                │
│                                             │
│  Delivers transcribed text via:             │
│  ┌───────────────────────────────────────┐  │
│  │  Agent Protocol (pluggable)           │  │
│  │  send(message) → async response       │  │
│  └───────────────────────────────────────┘  │
└──────────────────┬──────────────────────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
   ┌────▼─────┐        ┌─────▼─────┐
   │ Built-in │        │ External  │
   │ Agent    │        │ Agents    │
   │          │        │           │
   │ Fast/Pro │        │ OpenClaw  │
   │ tiers    │        │ Custom    │
   │ (LLM     │        │ API       │
   │  calls)  │        │ Webhooks  │
   └──────────┘        └───────────┘
```

**MacParakeet owns:** capture, transcription, inbox UI, delivery protocol.
**The agent owns:** processing, reasoning, research, tools, actions.

This means MacParakeet ships with a built-in agent (using configured LLM providers) but the protocol is open — plug in your own agent when personal AI agents become a thing.

## Why This Is Defensible

Agents come and go. The voice capture layer is hard to build well:
- System-wide hotkey that works everywhere
- Non-activating overlay that never steals focus
- Fast local transcription on the Neural Engine
- Audio that never leaves the device

If you're the best mic, every agent needs you.

## User Mental Model

"I have a thought. I press a key, speak it, and my agent handles it."

Use cases:
- **Questions**: "What are the trade-offs of server-side rendering vs static generation for SEO?"
- **Research tasks**: "Research the top 5 competitors in the Mac automation space and compare pricing"
- **Ideas to revisit**: "I think we should add keyboard shortcuts for export formats — think about this"
- **Reminders**: "Follow up with the designer about the icon refresh on Monday"
- **To-dos**: "Write a blog post comparing Parakeet vs Whisper accuracy benchmarks"

The user doesn't categorize. They just speak. The agent figures out what to do — or just holds onto it.

## Two Tiers (Built-in Agent)

| Tier | Models | Speed | Use Case |
|------|--------|-------|----------|
| **Fast** | Sonnet, Flash, GPT mini | Seconds | Quick answers, simple lookups, summaries |
| **Pro** | Opus, GPT 5.4 Pro, Gemini Pro | Minutes | Deep research, multi-source synthesis, complex analysis |

Fast is the default. Pro is opt-in (button on the voicemail card).

Pro fans out to multiple frontier models in parallel, then synthesizes results. The user sees per-model status and a final merged answer.

## Capture UX

### How do you leave a voicemail?

**Dedicated hotkey** — separate from dictation. Press, speak, release. No ambiguity.

- Dictation hotkey → text goes to cursor
- Voicemail hotkey → text goes to agent

### Overlay

Visually distinct from dictation pill — different accent color, icon, or label so you know you're sending to your agent, not typing into a text field.

### Length

No limit. Quick question? 5 seconds. Brain dump? 5 minutes. The agent handles whatever you give it.

## The Inbox

New sidebar tab — working name "Voicemails" or "Agent" or "Inbox."

Each voicemail is a card:
- **Your message** — transcribed text (expandable if long)
- **Status** — pending / thinking / done
- **Agent response** — appears when ready (markdown, expandable)
- **Timestamp** — when you left it
- **Audio** — optional playback of original recording
- **Actions** — copy response, upgrade to Pro, delete, re-ask

### Ordering

- Reverse chronological (newest first)
- Badge count on sidebar tab for new results
- Date grouping (Today, Yesterday, etc.)

### Separate from Dictation History

- **Dictation history** = text you pasted into apps. Record of output.
- **Voicemails** = messages to your agent. Inbox of pending/completed items.

Different table, different sidebar tab, different purpose.

## Agent Protocol

The key design decision: MacParakeet defines a **protocol** for agent communication, not just a hardcoded LLM pipeline.

```swift
protocol VoicemailAgent {
    func process(message: String, tier: AgentTier) async throws -> AgentResponse
    var supportsStreaming: Bool { get }
    var supportedTiers: [AgentTier] { get }
}

enum AgentTier {
    case fast
    case pro
}

struct AgentResponse {
    let content: String          // Markdown response
    let modelResponses: [ModelResponse]?  // Per-model for Pro tier
    let metadata: [String: String]?
}
```

Built-in agent implements this using configured LLM providers. External agents implement it via API/webhook. Users choose which agent handles their voicemails in settings.

## Multi-Model Research (Pro Tier)

When Pro is triggered:
1. Query sent to all configured frontier models in parallel
2. Each model's response streams in (visible per-model status)
3. Synthesis step merges results into a unified answer
4. User can expand to see individual model responses
5. Agreement indicator — did models converge or diverge?

## Data Model

New table: `voicemails`

```
id              UUID (primary key)
message         TEXT (transcribed user message)
response        TEXT (agent response, nullable — markdown)
status          TEXT (pending / processing / completed / noted)
tier            TEXT (fast / pro, nullable)
agent           TEXT (which agent processed it, nullable)
audio_path      TEXT (path to audio file, nullable)
created_at      DATETIME
completed_at    DATETIME (nullable)
```

For Pro tier, per-model responses:

```
voicemail_responses
  id              UUID
  voicemail_id    UUID (FK)
  model           TEXT (e.g. "opus-4.6", "gpt-5.4-pro")
  response        TEXT
  completed_at    DATETIME
```

## Open Questions

### Identity
- [ ] What do we call this? Voicemail? Agent Inbox? Voice Notes?
- [ ] Is "voicemail" the right metaphor? It's catchy and instantly understood.
- [ ] Sidebar tab name and icon?

### Agent Protocol
- [ ] How do external agents connect? API endpoint? Webhook URL? Local socket?
- [ ] Auth for external agents?
- [ ] Do we ship the protocol as open spec for others to build on?

### Capture
- [ ] Which hotkey for voicemail? (Configurable, but what default?)
- [ ] Overlay color/icon for voicemail mode?
- [ ] Keep audio by default? (Storage implications)

### Processing
- [ ] v1: built-in agent only, or protocol + external from day one?
- [ ] "No LLM configured" — feature hidden? Capture-only mode?
- [ ] Cost awareness — show estimated cost before Pro?
- [ ] Can the agent use web search, or just LLM knowledge?

### UX
- [ ] Notification when result is ready? (Badge, sound, system notification?)
- [ ] Follow-up / conversation on a voicemail? Or one-shot?
- [ ] Copy/paste agent response into apps?
- [ ] Bulk actions — clear all, mark all read?

### Scope & Positioning
- [ ] Is this v0.5?
- [ ] MVP: capture + fast tier only?
- [ ] Does this change the tagline? "Fast private voice app" → "Voice input for your AI agent"?
- [ ] Pricing implications? Still $49 one-time with agent features?

## Competitive Landscape

Nobody does this. Adjacent products:

| Product | What They Do | How We're Different |
|---------|-------------|-------------------|
| VoiceInk / Voibe | "Command Mode" — trigger Shortcuts, open apps | We send to an AI agent, not app automation |
| Apple Voice Memos | Record + transcribe | No agent, just storage |
| ChatGPT Voice | Conversational AI | Synchronous — you wait. We're async. |
| Google NotebookLM | Research + audio | Not voice-triggered, not system-wide |
| Siri | Voice assistant | Shallow answers, no deep research |

**Our unique angle:** System-wide voice capture → async agent delivery → results when ready. No app to open, no chat window to wait in. Just speak and move on.

## Next Steps

1. Settle on naming
2. Decide v1 scope (built-in agent only? protocol from day one?)
3. Design the capture flow and overlay
4. Sketch the inbox UI
5. Define the agent protocol
6. Spec the data model
7. Build it
