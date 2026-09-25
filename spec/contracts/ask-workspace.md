# Ask Workspace Contract

Status: **Accepted; implemented in development; qualification pending**. This
contract defines the shared native and CLI behavior for saved, source-scoped
Ask conversations. [ADR-034](../adr/034-meeting-ask-workspace.md) records the
architecture decision.

## Ownership and persistence

- Ask conversations are independent of Library recordings. Migration
  `v0.49-ask-conversations` adds `ask_conversations`; its UUID-keyed row has a
  bounded Codable JSON payload (8 MiB maximum), integer revision, timestamps,
  and nullable run token/lease columns. There is deliberately no source foreign
  key, so deleting a recording cannot cascade-delete a conversation.
- A conversation has a title, ordered context sections, messages, one draft,
  revision, and timestamps. The current section fixes the source UUIDs used by
  future sends. Each section accepts at most 32 unique sources. Starting with
  no sources is valid; sending without a source is not.
- Writes use compare-and-swap: callers supply the revision they read and a
  successful save increments it. A live run owns a database lease bounded to
  45 seconds, renewed every 15 seconds. App and CLI writes during an active
  lease fail instead of racing the answer. A deleted conversation cannot be
  recreated by a late save.
- Removing a source changes the current section and appends a new section. It
  does not erase earlier messages, evidence references, or the Library record.
  Deleting an Ask conversation removes only that conversation. Deleting a
  Library source leaves its historical conversation intact; its evidence then
  resolves as unavailable.

## Source scope and evidence

- The picker lists completed Library transcriptions using title/file-name text,
  source type, date bounds, and existing labels. Label filters match any
  selected label. Picker search is metadata search; transcript search happens
  only inside a run's selected source snapshot.
- Before a run, the service snapshots every selected source's current canonical
  passage list and revision. Reads and searches are restricted to those UUIDs
  and reject missing, unavailable, out-of-scope, or changed sources.
- Evidence is derived from current effective transcript text and speaker
  corrections. Legacy whole-transcript edits use untimed text chunks because
  their old word timings no longer align. Long passages are split into bounded
  chunks; split chunks do not claim the original passage's timing.
- Search is lexical: every whitespace-delimited query word must occur in a
  passage. It is bounded retrieval, not semantic ranking or an exhaustive
  completeness proof. Multi-source results are interleaved round-robin across
  selected sources; an optional `sourceID` narrows retrieval. Search responses
  expose a bounded result limit and `hasMore`. `read` walks canonical passage
  indices. The only agent tools are `list_sources`, `search`, `read`, and
  `get_summary`.
- `get_summary` returns only fresh, linked result-category summaries for the
  current transcript revision. A summary can orient research; transcript
  passages are the evidence for factual claims. The service revalidates every
  summary receipt used by a run in the final database transaction before
  accepting its answer.
- A citation resolves to source UUID, source revision, and zero-based canonical
  passage index, with optional source title and recorded date snapshots for
  historical display. It stores no copied quotation. On inspection, Ask
  re-reads the passage if the source revision still matches; otherwise it
  reports stale, unavailable, out-of-scope, or invalid evidence. If no valid
  passage citation resolves, an answer cannot be marked complete. The evidence
  panel can open the Library source and show a timecode when available; users
  can use the Library's existing playback controls. Ask does not seek audio
  programmatically.
- Final completion revalidates every selected source revision inside the same
  SQLite write transaction that saves the completed answer. If a transcript
  changes during generation, the answer cannot be committed as current.

## Context, runs, and privacy

- A send includes only completed user-question/assistant-answer pairs from the
  active section whose stored source-revision map equals the current run
  snapshot, plus the new question. A stopped or otherwise incomplete question
  is excluded along with its answer placeholder. Earlier sections,
  failed/cancelled answers, stale answers, and citations are not replayed as
  evidence in a later run. Older conversation text is not treated as source
  evidence.
- Before model work starts, Ask durably appends the user question and an
  assistant placeholder with `incomplete` status. The placeholder remains
  distinguishable if the process exits before terminal persistence. Completed,
  failed, and cancelled assistant messages have separate statuses; failure
  text is sanitized so provider errors cannot leak request credentials.
- The selected analysis provider is frozen for a run. In-process/Apple
  Intelligence and Ollama/LM Studio loopback routes need no remote consent.
  Other endpoints require explicit approval for the exact provider identity;
  a generic OpenAI-compatible loopback endpoint is not presumed local. Ask
  rejects the Local CLI provider. The GUI identifies the provider and context
  categories, and CLI callers pass `--allow-remote`. Selection alone sends no
  transcript content. Failure never silently switches providers.
- Pi runs in one private Node helper process per request over versioned JSONL
  pipes. The helper receives no provider credentials. Swift remains responsible
  for model calls, source access, evidence validation, durable state, and
  cancellation. The helper can request only the four tools above. Current
  helper limits include 12 turns, a 180-second deadline, bounded model input,
  evidence, output, and IPC frames.
- The helper uses Pi agent-core `runAgentLoop` with a one-action-per-turn
  structured JSON decision bridge and a genuine final text stream through the
  configured client. This is not provider-native function calling. Providers
  with native JSON-schema response format use it for the decision object;
  otherwise Swift validates the JSON response before allowing a tool call.
  A valid final answer must cite at least one tool-returned evidence marker;
  uncited responses remain `incomplete` and are identified as unverified.
  Malformed, unknown, or fabricated evidence markers fail validation.

## Native and CLI surface

The native Ask destination creates, resumes, renames, and deletes conversations;
curates up to 32 sources; autosaves a draft; shows provider disclosure and
remote consent; streams activity and answer text; supports Stop; and opens
revision-checked passage evidence. Source-picker selections persist while
filters change and are applied as one new context section.

`macparakeet-cli ask` exposes `list`, `new`, `show`, `rename`, `delete`,
`sources`, `select`, `draft`, `send`, and `evidence`. These commands emit JSON
by default, use complete UUIDs and ISO-8601 dates, and expose conversation and
source revisions. Mutating commands use the expected `--revision`. `send` uses
an explicit inline provider configuration; endpoints that require remote
consent also require `--allow-remote`. Ask rejects Local CLI provider routes.
`send --stream` emits NDJSON activity and text events followed by a final
conversation record.

The CLI surface is additive at version 4.7.0 in this development source. That
version does not qualify or update the stable MacParakeet.app release.

## Deferred

This contract does not include whole-Library implicit search, embeddings,
semantic ranking, calendar-series grouping, `@` mentions, a REPL, arbitrary
code execution, recursive model calls, graph views, or external actions.
