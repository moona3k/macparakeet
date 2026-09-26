# Ask Workspace Contract

Status: **Accepted; default-off in development; enablement qualification pending**. This
contract defines the shared native and CLI behavior for saved, source-scoped
Ask conversations. [ADR-034](../adr/034-meeting-ask-workspace.md) records the
architecture decision.

## Availability

`AppFeatures.askWorkspaceEnabled` is false. The native sidebar, Library actions,
and direct navigation are gated; the disabled app does not construct/configure
its Ask service. Every CLI Ask operation rejects before database access or model
work unless enabled. Debug builds accept explicit `--enable-ask-workspace`;
release builds ignore that opt-in. Stored preferences do not enable the feature.
The additive migration and existing saved conversations remain intact.
This gate applies only to the new workspace, not existing transcript/live chat.

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

The in-process local model adapter currently does not report trustworthy
end-of-sequence versus token-limit completion metadata. Ask rejects its actions
and final responses without an explicit successful stop reason, retaining a
safe failure reason instead of accepting a possibly truncated answer. This
restriction does not change existing chat or HTTP provider behavior.

## Source scope and evidence

- The picker lists completed Library transcriptions using title/file-name text,
  source type, date bounds, and existing labels. Label filters match any
  selected label. Picker title search treats `%`, `_`, and `!` literally.
  Availability checks usable stored text, segments, or word timestamps without
  returning transcript bodies; legacy whole-text edits use only edited text.
  Picker search is metadata search; transcript search happens only inside a
  run's selected source snapshot.
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
  current transcript revision. Results are a newest-first prefix of whole
  summary receipts that fits the 32,000-byte serialized tool limit and remaining
  128,000-byte run allowance. An oversized first summary yields an empty list;
  the run can continue using transcript tools. Receipt content is not further
  truncated to fit. A summary can orient research; transcript passages are the
  evidence for factual claims. The service revalidates every
  summary receipt used by a run in the final database transaction before
  accepting its answer.
- A citation resolves to source UUID, source revision, and zero-based canonical
  passage index, with optional source title and recorded date snapshots for
  historical display. It stores no copied quotation. During a run, scope is
  enforced at the tool boundary: `search` and `read` reject a `sourceID`
  outside the run's frozen selected-source snapshot before any evidence
  marker for it can be created, so every marker the model can cite already
  names an in-scope source; final-answer citations are then revalidated for
  freshness and availability against that same snapshot. Standalone evidence
  inspection (`AskWorkspaceService.evidence(_:)`, and the CLI's
  `ask evidence` command) is a deliberately different, narrower operation: an
  explicit local-user Library read, not a re-check of some conversation's
  scope. Given any known source UUID, revision, and passage index, it re-reads
  that passage directly, independent of which conversation (if any) originally
  cited it — the caller already has direct, unscoped Library access to every
  source, so there is no conversation-membership check to perform. It reports
  the passage as stale (revision changed), unavailable (missing source or
  transcript), or invalid (negative or out-of-range index); it has no notion of a
  citing conversation's source set, so it never reports out-of-scope. If no
  valid passage citation resolves during a run, an answer cannot be marked
  complete. The evidence panel can open the Library source and show a
  timecode when available; users can use the Library's existing playback
  controls. Ask does not seek audio programmatically.
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
- Swift defines the helper's context ceilings in serialized UTF-8 JSON bytes
  (including role fields and JSON escaping): 16,000 bytes and 76 messages for
  initial instructions/history/question, and 56,000 bytes per investigation
  request. Swift checks the initial budget before acquiring a lease or saving
  a question/placeholder, leaving 40,000 bytes for tool evidence and action
  history. Oversized initial context leaves the conversation and draft unchanged
  and asks the user to start a new conversation. The helper receives the same
  ceilings in its start frame; it does not insert extra instructions. These are
  application transport ceilings, not model context-window guarantees.
- If evidence/history exceeds the per-request or cumulative investigation
  budget, the run stops with a categorized, sanitized limit message suggesting
  a narrower question or fewer recordings. Partial text stays failed; no history
  or evidence is silently discarded, and no unchecked final answer is produced.
- Model actions use a strict JSON schema with enumerated action/tool names and
  required typed `query`, `sourceID`, `start`, and `limit` fields. The six-field
  envelope is projected onto the selected tool: `list_sources` takes no fields,
  `search` takes `query` plus optional `sourceID` and `limit`, `read` takes
  `sourceID`, `start`, and `limit`, and `get_summary` takes `sourceID`. Unused
  fields must retain their declared types but their values are ignored; empty
  strings and zeros are preferred. For `search`, empty `sourceID` and zero
  `limit` select the defaults. Final actions still require empty `toolName`,
  `query`, and `sourceID`, and zero `start` and `limit`. Arguments are not JSON
  encoded inside a string. The host validates the projected arguments and
  ranges before execution, including the host's 500-character search-query limit;
  source scope remains enforced at the tool boundary.
  A malformed action receives at most one correction request with a constant,
  application-authored reason identifying the invalid envelope, scalar types,
  action/tool name, tool requirements, final fields, or argument size. Feedback
  never replays the invalid response or includes its text. Both attempts undergo
  the same argument validation; repeated invalid actions fail with a sanitized
  model-compatibility message.
  Cancellation, provider errors, and truncated responses are not retried by this
  correction path. Decision and final requests disable local input chunking so
  an agent turn cannot be split into unrelated model calls.
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
  Tool actions replay as the same typed decision
  schema used for the next action, rather than a second prose call syntax.
  A valid final answer must cite at least one tool-returned evidence marker;
  uncited responses remain `incomplete` and are identified as unverified.
  Malformed, unknown, or fabricated evidence markers fail validation.
- Ask decisions and final answers keep each bounded conversation request intact;
  the in-process client's automatic map/reduce summarization is disabled for
  these calls. Other model consumers retain their existing chunking policy.
  Apple Intelligence final answers use its supported output-token ceiling.

## Native and CLI surface

The native Ask destination creates, resumes, renames, and deletes conversations;
curates up to 32 sources; autosaves a draft; shows provider disclosure and
remote consent; streams activity and answer text; supports Stop; and opens
revision-checked passage evidence. Source-picker selections persist while
filters change and are applied as one new context section.

Navigation, source changes, and sending wait for the current draft to save;
a failed save leaves the local draft in place and blocks the action. Edits
made while a destination loads are saved before switching conversations.
If a conversation was already created when a later draft save fails, it
remains reachable in the conversation list while the current draft stays open.

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
