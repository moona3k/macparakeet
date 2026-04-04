# 13 - Agent Workflows, Voice Control & External Automation

> Status: **PROPOSAL** — Exploratory, not yet authoritative
> Related: [spec/12-processing-layer.md](12-processing-layer.md) (implemented prompt library + multi-summary), [spec/11-llm-integration.md](11-llm-integration.md) (provider architecture), [ADR-011](adr/011-llm-cloud-and-local-providers.md) (cloud + local providers), [ADR-013](adr/013-prompt-library-multi-summary.md) (prompt library foundation)

This document captures the future design space that was split out of `spec/12`: typed actions, workflows, agent profiles, voice control, and Apple Shortcuts / App Intents integration. It is a roadmap and architecture exploration, not a locked implementation contract.

---

## Purpose

The Prompt Library established in [spec/12-processing-layer.md](12-processing-layer.md) is the foundation for a broader processing layer. The likely next frontier is not "more summary presets," but programmable transcript processing and lightweight desktop automation.

This doc exists to:

1. Preserve the design direction without making it look implemented.
2. Separate stable v0.7 behavior from speculative workflow/agent work.
3. Surface the unresolved questions before schema and UX decisions get locked.

## Non-Goals

1. Defining an implementation-ready schema for actions, workflows, or agent profiles.
2. Committing to a shipping order beyond rough sequencing.
3. Claiming that desktop context, voice control, or agent handoff are available today.

---

## Proposed Architecture

### Four Capabilities

The broader processing layer may evolve into four related capabilities:

```
┌─────────────────────────────────────────────────────────────────┐
│                                                                 │
│  ┌─ Prompt Library ──────────────────────────────┐  SHIPPED     │
│  │  Named, reusable instruction templates        │  (spec/12)   │
│  │  Prompt { id, name, content, category, ... }  │             │
│  │  Summary { id, transcriptionId, ... }         │             │
│  └───────────────────────────┬───────────────────┘             │
│                              │                                  │
│               ┌──── snapshot │ FK ────┐                         │
│               ▼              ▼        ▼                         │
│  ┌─ Summaries ─┐  ┌─ Agent Profiles ─┐  ┌─ Workflows ───────┐ │
│  │  Immutable   │  │  prompt + tools  │  │  Ordered steps    │ │
│  │  historical  │  │  + context +     │  │  with triggers    │ │
│  │  outputs     │  │  behavior         │  │  (static chains)  │ │
│  └──────────────┘  └─────────────────┘  └──────────────────┘ │
│                           (future)              (future)       │
│                                                                 │
│  ┌─ Actions ─────────────────────────────────────┐  (future)   │
│  │  .prompt(id) | .cliCommand | .export          │             │
│  │  .webhook | .clipboard | .agentHandoff        │             │
│  │  All receive a ProcessingContext              │             │
│  └───────────────────────────────────────────────┘             │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

The key distinction:

- **Workflows** are static pipelines: step 1, then 2, then 3.
- **Agent Profiles** are dynamic: an LLM receives tools and context, then decides what to do.

Both would build on the Prompt Library, but neither is implemented or fully specified yet.

### Relationship to Prompt Library

The Prompt Library remains the shared instruction foundation:

```
prompts
  │
  ├──snapshot──→ summaries.promptContent
  │
  ├──FK──→ agent_profiles.promptId
  │
  └──FK──→ workflow_steps.promptId
```

Important: only the summary snapshot path is locked today. The foreign-key relationships above are proposed design directions, not accepted schema decisions.

---

## Proposed ProcessingContext

If MacParakeet introduces action execution, each action likely needs a standard input contract.

### Transcript Context

Already available in current models:

```
transcript: String
source: .file | .youtube | .dictation
filename: String?
duration: TimeInterval?
speakers: Int?
language: String?
youtubeURL: URL?
diarizationSegments: [...]?
wordTimestamps: [...]?
```

### Chaining Context

Needed for workflows:

```
previousOutput: String?
```

### Desktop Context

Potential future context for agent handoff or voice-control scenarios:

```
activeApp: String?
activeAppBundleID: String?
browserURL: String?
selectedText: String?
clipboardText: String?
locale: String
```

This section is intentionally provisional. Permission boundaries, collection reliability, app-specific behavior, and privacy expectations are unresolved.

---

## Proposed Action Types

An action would be the atomic execution unit for workflows and agent-assisted processing.

| Action Type | Input | Output | Notes |
|-------------|-------|--------|-------|
| `.prompt(id)` | Transcript text | LLM-generated text | Reuses prompt library |
| `.cliCommand(cmd)` | Env vars + stdin | stdout text | Extends the Local CLI pattern |
| `.export(format)` | Transcript + metadata | File on disk | Wraps `ExportService` behavior |
| `.webhook(url)` | JSON payload | HTTP response | External delivery |
| `.clipboard` | Text | Clipboard contents | In-app / OS bridge |
| `.agentHandoff(cmd)` | Context + stdin | stdout text | Agent-driven interpretation, still unresolved |

### `agentHandoff` vs `cliCommand`

The distinction is about control:

- **`cliCommand`** runs a deterministic command with known arguments and expected behavior.
- **`agentHandoff`** gives a tool broader context and expects it to choose the next action autonomously.

That distinction is conceptually useful, but it still needs explicit safety and UX constraints before it becomes a real feature.

### Possible Environment Variable Contract

If command-backed actions ship, a future contract could map context to `MACPARAKEET_*` environment variables:

- `MACPARAKEET_TRANSCRIPT`
- `MACPARAKEET_SOURCE_TYPE`
- `MACPARAKEET_FILENAME`
- `MACPARAKEET_DURATION`
- `MACPARAKEET_SPEAKER_COUNT`
- `MACPARAKEET_LANGUAGE`
- `MACPARAKEET_YOUTUBE_URL`
- `MACPARAKEET_PREVIOUS_OUTPUT`
- `MACPARAKEET_ACTIVE_APP`
- `MACPARAKEET_ACTIVE_APP_BUNDLE_ID`
- `MACPARAKEET_BROWSER_URL`
- `MACPARAKEET_SELECTED_TEXT`
- `MACPARAKEET_CLIPBOARD_TEXT`
- `MACPARAKEET_LOCALE`

This should be treated as a proposal, not a promise.

---

## Proposed Workflows

A workflow would chain actions into repeatable pipelines.

```
Workflow { name, trigger, steps: [Action], isEnabled }

trigger: .manual | .postTranscription | .postDictation | .contextRule(...)
```

### Example Directions

Content-processing examples:

- Podcast publish: summarize key topics → format as blog post → export markdown → webhook to CMS
- Meeting debrief: meeting notes prompt → extract action items → copy to clipboard
- Study session: transcribe lecture → study notes prompt → export to Notes

Voice-control examples:

- Code assistant: post-dictation in an editor → hand off context to an agent
- Email reply: post-dictation in Mail → draft reply → paste into compose window
- Quick command: dictate intent → agent or command executes a matching action

These examples are intentionally aspirational. They require concrete decisions around triggers, permissions, safety rails, and UI review.

### Workflow Creation

Two creation modes are plausible:

1. **Manual builder**: add, remove, and reorder steps in a simple list editor.
2. **Agent-assisted builder**: user describes a desired automation; an LLM drafts the workflow definition for review and approval.

The agent-assisted builder is a UX hypothesis, not a committed direction.

---

## Apple Shortcuts / App Intents

An alternative or complementary direction is exposing MacParakeet capabilities to Apple Shortcuts through App Intents.

That path would let macOS handle orchestration and triggers while MacParakeet provides building blocks such as:

- Transcribe file
- Summarize with prompt
- Get last transcription

This may be lower-risk than building a full native workflow engine, but it also constrains how much custom state and desktop context MacParakeet can manage itself.

---

## Open Questions

1. Should future prompt categories expand beyond `.summary` and `.transform`, or should agents/workflows use separate models entirely?
2. What desktop context is reliable and privacy-safe to collect on macOS?
3. What permissions and user confirmation are required before an agent can act on other apps?
4. Is `agentHandoff` a distinct action type, or just a constrained flavor of CLI execution?
5. Is Apple Shortcuts the first automation surface, with native workflows deferred?

Until those are answered, this document should guide discussion only.

---

## Rough Sequencing

| Phase | Direction |
|-------|-----------|
| Prompt Library | Already specified in [spec/12-processing-layer.md](12-processing-layer.md) |
| Actions | Define typed action model and execution contract |
| Workflows | Add storage, triggers, and execution engine |
| Agent-assisted builder | Explore natural-language workflow creation |
| Agent handoff | Add safe autonomous tool execution if justified |
| Apple Shortcuts | Can progress independently if App Intents are the better first automation surface |
