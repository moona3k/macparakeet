# Knowledge-card reliability: diagnosis and bounded repair

Review base: a388b7d449c722875f24e26df35acecf881dd35e (origin/main, fetched
2026-10-30). Related report: [#1277](https://github.com/moona3k/macparakeet/issues/1277).
This is a card-generation/recovery change. Capture, generic formatter behavior,
configuration writes, provider inventory, persistence schema and scheduling stay
outside the change.

## Evidence and confidence

The supplied audit's read-only D1 receipts cover stable 0.8.10, October 23
18:00 UTC through October 30 18:00 UTC. Re-aggregation of its saved
card-failure-tokens.json reproduced the 696 failures. No fresh production query
or causal before/after comparison was performed in this repair session.

| LLM-stage outcome | Count |
| --- | ---: |
| Success | 699 |
| Failure | 696 |
| Unavailable | 282 |
| All observed terminals | 1,677 |

Failure categories: invalid response 482; AI configuration StoreError.busy 98;
provider error 61; rate limited 32; request timed out 22; context too long 1.
The audit reported 288 distinct failure process sessions, not users.
These LLM events precede card persistence, so 699 is not a saved-card count.

**High-confidence source defects:**

- The old card path requested 700 output tokens, ignored finishReason, and
  retried embedded-schema invalid JSON with identical prompt/options. Native
  schema routes had no recovery request. JSON syntax/citation fields and, on
  some models, reasoning consume output beyond the 350-token stored text.
- Exactly 205 invalid-response events reached 700 on one request or 1,400
  across two: OpenAI-compatible 61, Anthropic 58, OpenAI 47, OpenRouter 20,
  LM Studio 12, unknown provider 7. This strongly supports budget exhaustion
  for a subset; saved telemetry contains no finish reason and cannot prove all
  205 individual events were truncated.
- The AI settings store intentionally uses nonblocking flock. Every busy card
  setup read became a terminal failure without waiting. This is contention,
  not evidence of database corruption.
- Ollama's native adapter ignores raw options without inference-resolution
  provenance. Thus the old 700 request did NOT impose a 700-token Ollama
  ceiling. Card context used the generic 80,000-character local allowance
  despite the adapter sending num_ctx=8192. Both are fixed at the card caller
  using existing inference resolution and context reservation.
- LLM validation accepted empty synopsis and boolean citation timestamps that
  the persistence decoder could reject. Recovery now applies the persistence
  decoder and non-empty synopsis check before emitting success.
- Returned usage covered only the last response while telemetry summed them.
  Both now cover all reported responses, with missing usage left unknown.

**Unproven or deliberately unresolved:**

- 133 localCLI invalid responses have no reliable usage evidence. The fix
  changes corrective instructions; it cannot establish what those tools emitted.
- The 79 Ollama invalid responses and #1277 do not prove a thinking-mode defect.
  Current source already sends think=false. The report's opt-in diagnostic
  attachment has no card/provider response evidence. No Gemma model is installed
  here: local /api/tags returned an empty model list.
- Generic provider errors do not expose a reliable typed unsupported-schema
  category here. They remain visible terminal errors. Matching free-form error
  text or blindly stripping schemas could hide unrelated provider faults.
- Timeouts/rate limits do not carry a retry-after policy in this boundary.
  Automatic repeats could double work/spend or immediately hit the same limit.

## Repair and tradeoffs

Preserve the 700-token initial allowance for cloud and other unknown-window
routes, permitting 4,096 only after an explicit length, max_tokens or
max_output_tokens finish. Provider names do not prove capacity: OpenAI routes
also accept manual model IDs and endpoint overrides. A wire fixture demonstrates
a schema-capable endpoint that accepts 700 but rejects a 2,048-token first request.
Native Ollama uses 2,048/4,096 against its configured window; LM Studio uses
1,024/1,536. Custom OpenAI-compatible endpoints use 700/2,048. This preserves
successful first requests; recovery may still fail at an unknown server limit.
It can cost an additional round trip when cloud output reaches 700 tokens.
These are bounded allowances, not a claim that every model can finish within
them. Wire fixtures cover serialization, truncation metadata and cumulative
counters; no real-model quality claim follows.

At most one provider retry changes the prompt; truncation also increases the
allowance. Partial output is neither persisted nor replayed as instructions.
A cancellable setup loop waits 100/300/600 ms only for StoreError.busy.
It cannot retry indefinitely or silently change the configured route.
No new retry framework, provider, model discovery or telemetry payload is added.

Larger recovery allowances permit higher worst-case cost/latency. The card
service makes at most two client requests: up to 4,796 requested output tokens
for clouds, 6,144 for Ollama, 2,560 for LM Studio, and 2,748 for custom endpoints.
LocalCLI has no token contract; the existing developer-only in-process provider
may perform multiple internal generations beneath a client request.
Input reservation can shorten the transcript sent on a retry. The card remains
a routing hint with its existing approximately 350-token persistence budget,
citation resolution and source freshness checks.

## Safety facts and verification

The critical safety facts are (1) generic LLM requests retain their prior wire
behavior, and (2) an unsuccessful or stale generation cannot destroy an old
card or resurrect deleted source data. Tests exercise real request builders and
real in-memory repositories for these boundaries.

Added regressions cover native/embedded response recovery, missing fields,
empty synopsis, boolean timestamps, parseable-but-truncated JSON, timeout/rate
limit/schema rejection, cancellation, bounded lock exhaustion and a real released
file lock, unknown localCLI usage, actual Ollama option serialization, cumulative
OpenAI counters, old-card preservation and source deletion. Existing transcript
mutation, speaker correction, current-card skip and atomic-save tests remain.

Local Swift syntax parsing and diff checks passed. The brief requests GitHub
PR CI instead of local CI/full suites; no local Swift build or suite was run.
no-mistakes and Unblocked executables are unavailable. Independent correctness
and maintainability review converged after correcting assertion-helper visibility
and an Ollama response fixture, sharing the typed validator and separating tests.
Hosted review also prompted preserving the custom-endpoint initial budget and
adding cancellation-after-response and repository-deletion regressions. Local Greptile and
exact-head GitHub CI evidence belong in the PR. No production deployment or
user-data deletion is part of this repair.

The pstack blast-radius guidance informed executable boundary tests:
[skill](https://github.com/cursor/plugins/blob/main/pstack/skills/blast-radius/SKILL.md).
No plugin installation or workflow framework was added. Jev was not used:
the changed decisions are exact protocol/error checks, not semantic judgments.

## Provider sources and release gate

- [Ollama chat API](https://docs.ollama.com/api/chat): native completion reason,
  usage fields and request options.
- [Ollama thinking controls](https://docs.ollama.com/capabilities/thinking):
  controls vary by model; the current false setting is not proof that every
  thinking model can be made non-thinking.

Before claiming #1277 resolved, run a synthetic canary on its actual Ollama/Gemma
version. Record model/version, requested limits, finish reason, usage, attempt
count, validation and saved-card outcome without retaining private transcripts.
After release, compare exact-build card-stage outcomes and distinct process-session
exposure in comparable cohorts. CI and synthetic wire fixtures do not establish
production improvement or native app acceptance.
