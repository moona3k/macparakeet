# Meeting Chat Workspace research

Date: 2026-09-25. Status: product direction endorsed by the user; architecture research captured before implementation. The focused Ask workspace and private Pi helper are now implemented in this development branch. This research does not establish full verification, live-model qualification, or stable release adoption.

## Agreed direction

Build **Ask**, a native full-page workspace for investigating a user-selected set of meetings and imported transcripts. Provide saved conversations, a roomy searchable source picker, existing label/date filters, and answers with inspectable passage citations. Use summaries for orientation and corrected transcripts for evidence. Keep source scope explicit across follow-ups and source changes.

**Use Pi's agent core as the reusable harness for the focused implementation.** The implementation pins Pi 0.87.1 and calls its `runAgentLoop` from a private Node helper. This adopts the agent-core library only, not the Pi coding-agent CLI. Runtime qualification remains separate from this architectural choice; OpenCode is not part of the current implementation.

| Boundary | Responsibility |
| --- | --- |
| Pi agent core | Adaptive model/tool loop and structured execution events |
| MacParakeet | Native workspace, selected-source enforcement, local retrieval, evidence and citations, durable conversations, run limits, and privacy |
| Model adapter | Translate model requests, tool calls/results, streaming, errors, usage, and cancellation for each qualified provider |

The implementation uses Pi's reusable agent core and app-supplied tools. Its full coding-agent application and durable harness are separate integration options, with different APIs; neither is included. The [source comparison](opensource-harnesses.md#pi-distinguish-the-layers) records those distinctions.

The selected design is **model agnostic, with capability checks**. Changing a model should not change which meetings it may read or how citations work. Each model still needs qualification for tool use, context limits, cancellation, and answer quality. The bridge uses MacParakeet's configured provider client; existing string-only chat events were not sufficient for an agent runtime.

Start with read-only research tools. Code Mode, a REPL, and recursive model calls remain experiments for harder questions. Recurring-meeting selection and cited timelines fit the product direction; a knowledge graph is outside the current scope.

## Reading guide

| Document | Purpose |
| --- | --- |
| [Product proposal](../../plans/2026-09-25-1308-feat-meeting-chat-workspace-plan.md) | Native workspace, source picker, conversation behavior, proposed requirements and UX questions |
| [Model-agnostic design](model-agnostic-design.md) | Ownership boundaries, Pi integration options, model capabilities, scope and lifecycle rules, evaluation gates |
| [Open-source harnesses](opensource-harnesses.md) | Source-level Pi, OpenCode, and Pydantic AI comparison with pinned revisions |
| [Retrieval and RLM implementations](opensource-retrieval-and-rlm.md) | Onyx, AnythingLLM, and RLM patterns for scope, evidence, long transcripts, and programmable context |
| [Circleback and Wispr Flow evidence](competitor-evidence.md) | Earlier current-client/local-binary investigation, precise source identities, and backend unknowns |

## What the open-source investigation changes

These are design conclusions from the linked source inspections, not measured performance rankings:

| Project | What matters for Ask | Recommendation |
| --- | --- | --- |
| Pi | Separation of model streaming, agent tools, and loop events; a lighter layer than its coding-agent product | Chosen for the focused implementation as agent-core only, with app-supplied tools |
| OpenCode | Headless server and broad coding-agent lifecycle, plus a larger configuration/process surface | Retain as an alternative if its additional runtime features become useful |
| Pydantic AI | Typed model/tool boundaries and explicit run limits | Borrow contract and budget ideas; a Python runtime is not required for this Swift app |
| Onyx | Explicit source selection, search scope, citation identities | Borrow scope semantics and evidence flow; avoid importing its server/search architecture wholesale |
| AnythingLLM | Workspace retrieval, long-document processing, and model-dependent tool paths | Borrow useful retrieval and capability patterns; audit subtree licenses before reuse |
| RLM | External programmable context and model subcalls | Evaluate only when simpler tool use misses important tasks; its local REPL is not a production isolation boundary |

Upstream repository/package names and development APIs can change. The detailed reports pin inspected commits and distinguish them from release qualification. Root licenses do not automatically cover all subdirectories or dependencies.

## Implementation boundary

The implementation keeps source ownership, lexical retrieval, citation
validation, conversation persistence, and provider calls in Swift. The helper
uses a structured one-action JSON bridge for decisions and streams the final
answer through the configured client; this is not provider-native function
calling. Its only source tools are `list_sources`, `search`, `read`, and
`get_summary`. The Ask contract and [ADR-034](../../../spec/adr/034-meeting-ask-workspace.md)
now describe these accepted boundaries. Tool behavior or this source record
does not qualify model quality, signed distribution, or stable release.

The implementation defines the initial picker and source-change section behavior
in the Ask contract and ADR. Native visual assessment, initial qualified models,
and any later expansion of resource limits remain separate qualification work.
Documentation approval is not approval to publish, release, or send private
recordings to external models.

## Evidence boundary

The original reports inspect primary upstream sources and the then-current
MacParakeet working tree. The competitor report additionally records previously
inspected public client bundles and installed Wispr files. No user transcripts
were used and no Jev inference was invoked during that research. Later
implementation activity is documented separately in the plan; runtime quality,
reliability, and distribution compatibility must be judged from its current
verification record, not inferred from this research.

## Verification

See [verification and open qualification issues](verification.md) for builds, tests, native screenshots, packaged CLI evidence, and the unresolved keyboard-freeze and real-model failures. This is an implemented candidate, not a runtime-qualified release.
