# Plan: Context Engine for Library and Agent Tools

> **Experimental / tentative note**: This has not gone through deep design
> review yet. It is a parking lot for the Context Engine direction and naming
> discussion, not an approved architecture or committed build plan.
>
> **Executor instructions**: Treat this as a proposal and naming record, not an
> implementation ticket. Before building, reconcile it with
> `plans/active/2026-06-19-meetings-workspace-productization.md`,
> `spec/contracts/meeting-artifacts-v1.md`, and the current `macparakeet-cli`
> command surface. The first valid implementation slice is read-only context
> retrieval with JSON output and citations.

## Status

- **Priority**: P2
- **Effort**: M/L
- **Risk**: MED
- **Status**: PROPOSED
- **Category**: library / meetings / CLI / agents
- **Planned at**: 2026-07-04
- **Related**:
  - `plans/active/2026-06-19-meetings-workspace-productization.md`
  - `spec/contracts/meeting-artifacts-v1.md`
  - `integrations/README.md`
  - `docs/research/2026-07-04-open-source-meeting-recorder-review.md`

## Summary

Build a `ContextEngine`-shaped module that turns MacParakeet's local Library
into structured, cited, budget-aware context for UI, CLI, and external agents.

The important product idea is not "add a chatbot." It is to make
MacParakeet's transcript, meeting, notes, prompt-result, calendar, speaker, and
artifact data easy for agents and scripts to inspect without learning the
database schema or filesystem conventions.

The preferred user-facing name for the idea is **Context Engine**. In code, the
first module can use a narrower name such as `LibraryContextEngine` if the
bare `ContextEngine` would collide with selected-text, app-context, or LLM
window-budget concepts.

## Why this matters

MacParakeet already has the hard local substrate:

- persisted transcripts and meeting rows
- source-separated meeting artifacts
- `manifest.json`, `transcript.json`, `notes.md`, and prompt-result artifacts
- a first-class CLI automation surface
- live meeting Ask and saved-transcript chat
- prompt library and provider-routing infrastructure

What is missing is one stable interface that answers a simpler question:

> "Given a task or query, what local MacParakeet context should an agent,
> command, or UI flow use, and how do we cite it?"

Without this seam, each future feature is tempted to reimplement lookup,
truncation, citation formatting, privacy rules, and artifact/database
resolution. That makes cross-meeting Ask, local agent tools, MCP, and CLI
automation harder to keep consistent.

## Design direction

The durable module should be **context-first, tool-friendly, and read-only at
the start**.

```
Mac app Ask / Library UI
macparakeet-cli
future local agent or MCP server
LLM tool-calling loop
        |
        v
Library tools
        |
        v
ContextEngine / LibraryContextEngine
        |
        v
GRDB repositories + MeetingArtifactStore + transcript.json + notes.md
```

The `ContextEngine` should not own chat UX, provider selection, or free-form
agent actions. It should build grounded context bundles that other modules can
use.

## Proposed module names

Use these names unless a future implementation pass finds a stronger local
convention:

- **Concept / product direction**: Context Engine
- **Core module**: `LibraryContext`
- **Core interface**: `LibraryContextEngine`
- **CLI/tool wrapper**: `LibraryTools`
- **Tool registry**: `LibraryToolRegistry`
- **Question-answering consumer**: `LibraryQueryEngine`
- **User-facing feature**: Ask Library

The name `ContextEngine` resonates because this is fundamentally about the
context around a transcription: transcript text, timestamps, speakers,
calendar metadata, notes, prompt results, artifact paths, source quality, and
provenance.

Keep the code-level name scoped unless the implementation truly becomes the
single app-wide context interface.

## Proposed core interface

The exact Swift names can change, but the seam should look like this:

```swift
public protocol LibraryContextEngine: Sendable {
    func buildContext(
        for request: LibraryContextRequest
    ) async throws -> LibraryContextBundle
}
```

The request should describe:

- query text or task intent
- scope, such as current transcript, selected meetings, date range, source
  type, or whole Library
- budget, such as max excerpts, max words/tokens, max meetings, or max age
- output purpose, such as search, ask, summarize, compare, export, or agent
  handoff
- provider locality preference when context may be sent to an LLM

The bundle should include:

- ranked context excerpts
- citations
- omitted or truncated sources
- query diagnostics
- source metadata needed by UI, CLI, and agents
- a stable JSON representation

## Proposed tools

Expose the engine through deterministic tools before building a polished Ask
experience.

### `list_meetings`

Return meeting IDs and lightweight metadata.

Fields should include title, date, duration, source type, status, whether notes
exist, whether prompt results exist, artifact folder availability, and whether
retained audio still exists.

### `search_library`

Search local transcript, notes, prompt results, and meeting metadata. Return
ranked hits with stable meeting IDs, snippets, timestamps where available, and
source kind.

Start with the existing repository/search behavior or SQLite FTS if that work
has landed. Do not send a whole Library to an LLM to perform search.

### `read_transcript`

Return bounded transcript excerpts. Support meeting ID plus range selection by
timestamp, segment ID, or search hit. Default to bounded excerpts rather than a
full transcript dump.

### `read_notes`

Return user notes and generated note artifacts for a meeting when present.

### `read_prompt_results`

Return prompt-result summaries and markdown bodies for a meeting. Preserve
prompt names, generated timestamps, and source meeting IDs.

### `build_context`

Given a query and scope, assemble a `LibraryContextBundle` from the tools
above. This is the primary agent/CLI primitive.

### `ask`

Optional convenience command layered above `build_context`. It can call
`LLMService` with the bundle and stream an answer, but it should not be the
foundation. The tool surface must remain useful without an LLM.

## CLI shape

Prefer a `library` namespace if it can be added without conflicting with the
current CLI vocabulary:

```bash
macparakeet-cli library list --since 7d --json
macparakeet-cli library search "pricing Sarah" --json
macparakeet-cli library read-transcript <meeting-id> --around 00:14:20 --json
macparakeet-cli library read-notes <meeting-id> --json
macparakeet-cli library prompt-results <meeting-id> --json
macparakeet-cli library context "what did I promise Sarah?" --since 30d --json
macparakeet-cli library ask "what did I promise Sarah?" --since 30d --json
```

If `meetings` remains the better namespace for the first slice, keep the JSON
shape compatible with a future `library` namespace.

## JSON contract sketch

`build_context` should emit JSON that agents can use directly:

```json
{
  "schema": "com.macparakeet.library-context",
  "schemaVersion": 1,
  "query": "what did I promise Sarah?",
  "scope": {
    "kind": "library",
    "since": "2026-06-04"
  },
  "context": [
    {
      "id": "ctx_001",
      "kind": "transcript_excerpt",
      "meetingID": "00000000-0000-0000-0000-000000000000",
      "title": "Sarah sync",
      "text": "I'll send the pricing draft tomorrow.",
      "citationIDs": ["cit_001"]
    }
  ],
  "citations": [
    {
      "id": "cit_001",
      "meetingID": "00000000-0000-0000-0000-000000000000",
      "title": "Sarah sync",
      "timestampSeconds": 842.5,
      "speaker": "Dylan",
      "sourceKind": "transcript",
      "artifactPath": "meeting.md",
      "excerpt": "I'll send the pricing draft tomorrow."
    }
  ],
  "omissions": [
    {
      "kind": "budget",
      "message": "2 matching meetings were omitted because the context budget was full."
    }
  ]
}
```

The exact fields should be pinned in a contract doc before release.

## Privacy and locality rules

- Context building is local and deterministic.
- The first slice is read-only.
- Remote LLM providers receive only bounded snippets selected by the local
  context engine.
- Audio is never sent to a provider through this path.
- Artifact folders are readable views, not canonical mutable state.
- Citations should use stable meeting IDs and typed local references first;
  paths and markdown line numbers are secondary presentation details.
- Tool output must keep CLI stdout JSON clean. Progress and diagnostics belong
  on stderr.

## Non-goals

- Do not replace the existing meeting recording pipeline.
- Do not make filesystem artifacts the source of truth for meeting metadata.
- Do not implement a broad autonomous agent that edits notes, deletes files, or
  runs app actions.
- Do not add a People/CRM graph in the first slice.
- Do not perform cross-meeting Ask by sending full transcript history to an
  LLM.
- Do not make MCP the first implementation. Design the CLI/tool contract so MCP
  can wrap it later.

## Suggested staged build

### Phase 0: Design and contract

- Audit current `history`, `meetings`, prompt-result, and artifact CLI output.
- Choose `library` vs `meetings` namespace for the first command.
- Draft `spec/contracts/library-context-v1.md`.
- Define citation IDs, meeting references, excerpt ranges, and omission
  reporting.

### Phase 1: Read-only local tools

- Add `LibraryContext` core types.
- Add `LibraryContextEngine` backed by repositories and `MeetingArtifactStore`.
- Add tests with fake repositories covering citation formation, budget
  truncation, empty results, retained-out audio, and notes/prompt-result
  inclusion.
- Add CLI `context` output behind `--json`.

### Phase 2: Search depth

- Add or reuse a local index over transcript text, notes, prompt results, and
  selected meeting metadata.
- Add rebuild and corruption recovery.
- Keep result ranking explainable enough for support and tests.

### Phase 3: Ask Library

- Add `LibraryQueryEngine` as a consumer of `LibraryContextEngine`.
- Route through `LLMService` only after context selection is complete.
- Show citations and omissions in the UI.
- Persist conversation history only after the product rule is explicit.

### Phase 4: Agent/MCP wrapper

- Wrap the same tools for local agent frameworks or MCP if demand is clear.
- Keep the CLI as the stable contract and MCP as an adapter, not a parallel
  implementation.

## Open questions

- Should the first public namespace be `library` or should the first slice live
  under existing `meetings` commands?
- Should `ContextEngine` be a product/marketing name only, while code uses
  `LibraryContextEngine`?
- What is the minimum citation unit: transcript segment, timestamp window,
  markdown line, prompt result ID, or all of the above?
- Should user notes be searched by default, or should agent use of notes have a
  separate privacy affordance?
- How should context bundles represent confidence or degraded capture quality?
- Should local search/indexing include dictations and file/media
  transcriptions from day one, or start with meetings?

## Revisit criteria

Revisit this when one of these becomes the next active product slice:

- Cross-meeting Ask
- Library search/indexing
- CLI meeting artifact expansion
- Local agent/MCP access
- Meeting workspace productization
- Transcript replay/evaluation tooling

At that point, decide whether this stays a plan, becomes a contract spec, or is
folded into the meetings workspace productization plan.
