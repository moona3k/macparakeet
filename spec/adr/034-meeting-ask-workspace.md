# ADR-034: Meeting Ask Workspace

**Status:** Accepted  
**Date:** 2026-09-25

## Context

Transcript chat handles a single recording. Users also need to compare a
deliberately chosen set of meetings, inspect the passages behind an answer, and
return to that research later. Reusing the first transcript as owner would
make source deletion erase the conversation, while concatenating every source
into a prompt can hide missed passages. A general coding-agent runtime would
also exceed the required authority.

## Decision

1. Add a top-level Ask workspace with durable conversations independent of
   Library sources. A conversation begins with an empty source section and
   permits at most 32 selected completed transcriptions.
2. Freeze source membership and canonical transcript revisions for each run.
   A source-set change appends a section. Future model context contains only
   complete messages from the active section whose source revision map still
   matches. Prior-section messages remain visible as history but are not
   replayed into later runs.
3. Keep transcript selection, retrieval, and evidence in MacParakeet. Provide
   only `list_sources`, lexical `search`, indexed `read`, and current
   `get_summary` operations to the agent. Summaries orient; corrected transcript
   passages support claims. Persist citation identity (source UUID, revision,
   passage index) and optional display metadata, not duplicate quoted text. An
   answer without a valid evidence citation cannot be marked complete.
   Interleave multi-source search round-robin, with optional per-source
   filtering and explicit continuation offsets. Ranked lexical retrieval uses a
   disposable, selected-scope index over revision-checked canonical passages;
   it does not inherit freshness from the Library derived index. Revalidate all source revisions
   and summary receipts used in the run inside the terminal conversation write
   transaction.
4. Use the pinned Pi agent-core 0.87.1 loop in a short-lived private Node helper.
   Swift adapts the configured model through a validated one-action JSON bridge;
   the helper calls Pi's `runAgentLoop`, while final answer text streams through
   the configured Swift client. This integration does not use
   provider-native function calling or the Pi coding-agent CLI. The helper has
   no credentials and no shell, filesystem, web, plugin, or arbitrary-code
   tools.
5. Use compare-and-swap conversation revisions and a 45-second run lease,
   renewed every 15 seconds, to arbitrate across app and CLI processes. Persist
   an `incomplete` assistant placeholder before starting the helper and retain
   separate complete, failed, and cancelled outcomes.
6. Freeze the selected analysis provider for each run. Ask uses direct model
   providers only and rejects Local CLI. In-process/Apple Intelligence and
   Ollama/LM Studio loopback routes need no remote consent; other endpoints,
   including generic OpenAI-compatible loopback endpoints, require explicit
   approval in both GUI and CLI. No provider fallback occurs. Expose the same
   shared service through additive `macparakeet-cli ask` commands.

## Default-off integration (2026-09-26)

The implementation may land on `main` with `AppFeatures.askWorkspaceEnabled`
set to `false`. Both native entry points and CLI operations are disabled by
this gate. Debug builds require explicit `--enable-ask-workspace` opt-in;
release builds ignore that argument. The disabled native app does not construct
or configure the Ask service, and CLI rejection precedes database access or
model/helper execution. The schema migration remains additive and saved Ask
data is retained.

Model reliability, native interaction, and the earlier freeze report block
**enabling or releasing** Ask. They do not by themselves block integrating
verified dormant code. Existing single-transcript and live meeting chat remain
available. Enabling the flag requires separate qualification and review.

## Consequences

- An explicit source set gives bounded scope and inspectable coverage. Lexical
  retrieval can still miss relevant wording; the model must not claim
  completeness from an incomplete search.
- Legacy whole-transcript edits and long derived passages may have text anchors
  without accurate timing. Citation inspection resolves current text and
  reports source changes. Optional source title/date are display snapshots.
  The evidence panel opens the source in Library and may show its timecode;
  playback remains under existing Library controls. Ask does not programmatically
  seek. These are presentation handoffs, not part of citation identity.
- Conversation persistence is one bounded JSON payload with SQL revision and
  lease columns. It is not indexed as transcripts and is not joined to sources
  by foreign key.
- Node and the private bundled helper add distribution and license-notice
  obligations. The app and standalone CLI must include their exact runtime and
  dependency notices; package installation is a build-time operation.
- Calendar grouping, `@` mentions, embeddings, semantic ranking, a REPL,
  arbitrary code execution, recursive model calls, graph visualization, and
  external actions remain deferred.

## Qualification boundary

This ADR records the accepted architecture, not release qualification. Source
presence does not establish successful builds, focused test results, native UI
quality, live-model answer quality, cancellation under real provider latency,
or signed-app packaging. Record those results only after they are actually
verified.
