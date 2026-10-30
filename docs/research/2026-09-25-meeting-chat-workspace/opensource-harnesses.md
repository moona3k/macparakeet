# Open-source harnesses for the meeting workspace

Date: 2026-09-25. Status: source research and proposed experiment; no runtime adopted.

## Recommendation

**Evaluate Pi first, using its reusable agent core inside a small MacParakeet-owned helper.** Keep Swift responsible for the native workspace, selected-source authority, transcript retrieval, citations, and user data. Pi is a credible way to reuse the model/tool loop without adopting a coding assistant's complete application. Model independence should be an explicit adapter contract, with supported capabilities tested per model.

This refines the earlier “small purpose-built harness” proposal: the small part we own can be the product adapter, rather than a newly written orchestration engine. If the Pi integration proves more difficult to maintain than a bounded Swift loop, retain the same domain tools and replace the runtime. Language alone is insufficient reason to reject reuse.

This report inspects three repositories at pinned commits, including executable source, manifests, and licenses. It does not establish published-package availability, measured performance, packaged-app compatibility, or answer quality. No upstream code was installed or executed; no private transcripts were sent anywhere.

## Source snapshots

| Project | Inspected commit | License and runtime evidence | Role in this evaluation |
| --- | --- | --- | --- |
| Pi | `d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31` | [MIT](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/LICENSE); [agent manifest](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/package.json) declares Node ≥22.19.0 | First reuse experiment |
| OpenCode | `adee738d1e4597a2d0d317ca61a1625eff289efa` | [MIT](https://github.com/anomalyco/opencode/blob/adee738d1e4597a2d0d317ca61a1625eff289efa/LICENSE); [core manifest](https://github.com/anomalyco/opencode/blob/adee738d1e4597a2d0d317ca61a1625eff289efa/packages/core/package.json) is private | Alternative managed process; broader coding product |
| Pydantic AI | `d0ea063717d88ef48c854d282bbb51c12a53065f` | [MIT](https://github.com/pydantic/pydantic-ai/blob/d0ea063717d88ef48c854d282bbb51c12a53065f/LICENSE); [manifest](https://github.com/pydantic/pydantic-ai/blob/d0ea063717d88ef48c854d282bbb51c12a53065f/pyproject.toml) declares Python ≥3.10 | Strong reference for typed models, tools, and limits |

The old `badlogic/pi-mono` repository URL currently redirects to `earendil-works/pi`. The inspected source manifests name `@earendil-works/pi-agent-core` and `@earendil-works/pi-ai`, both version `0.87.1`. These are source-manifest facts, not a verified npm release recommendation. Pin the actual package/revision selected for a prototype instead of copying older package names or examples. [Agent manifest](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/package.json), [AI manifest](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/ai/package.json).

## Pi: distinguish the layers

| Layer | What inspected source provides | Proposed MacParakeet use |
| --- | --- | --- |
| `pi-ai` | Model/provider collection and normalized streaming types | Optional network-provider implementation, or types used by a custom provider bridge |
| `pi-agent-core` / `Agent` | Stateful adaptive tool loop, events, queues, injectable streaming, context hooks | Start here with a narrow application adapter |
| `pi-agent-core` / `AgentHarness` | Durable session/lane operations, retry and compaction configuration | Evaluate separately if durable runtime state is needed |
| `pi-coding-agent` / RPC | Full coding application exposed as a JSONL subprocess protocol | Useful protocol reference; avoid making the whole coding product our initial dependency |

These are separate interfaces, not interchangeable names for one API. The current lightweight `AgentOptions` accepts `streamFn`; the higher-level `AgentHarnessOptions` accepts `Models`, a session, tool/resource configuration, retry, and compaction settings. Do not attribute the durable harness's behavior to a bare `Agent`. [Agent constructor](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/src/agent.ts#L112-L141), [durable harness interface](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/src/harness/agent-harness.ts#L518-L623).

### Loop, tools, and events

The core loop obtains a streamed assistant response, executes tool calls, appends tool results, and requests another response. It includes sequential/parallel execution policies, argument validation, pre/post tool hooks, turn hooks, steering, and follow-up queues. Truncated assistant output does not execute potentially incomplete tool arguments. This is already the central behavior required for searching, reading, and revisiting meeting evidence. It does not require a REPL. [Loop implementation](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/src/agent-loop.ts).

Tool execution receives a cancellation signal and can emit partial progress. Events distinguish agent, turn, message, and tool lifecycles. A source-search tool can therefore report visible progress independently of answer text. The event protocol is useful plumbing; citations and coverage still need domain-specific fields and validation. [Tool and event types](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/src/types.ts#L442-L500).

`Agent.abort()` signals its controller. Cancellation remains cooperative across the model stream, custom tools, hooks, and any IPC bridge. The app must await settlement, reject late results from an older run, and own helper shutdown/restart. `AgentOptions` has no explicit total-turn or total-token run limit: proposed MacParakeet policy should use request/turn hooks plus a deadline and byte/token accounting, rather than assuming the runtime prevents endless investigation. [Agent implementation](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/src/agent.ts).

### Model independence and the Swift bridge

`StreamFn` is an intentional replacement point. It receives the normalized transcript and model/options, then returns typed assistant stream events. Failures must appear as protocol events and a final error/aborted message. System prompts and tool declarations are carried in transcript system messages in this revision. A Swift bridge is therefore feasible by interface design, but unimplemented: forwarding today's text-only chat stream would be insufficient. [Stream contract](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/src/types.ts#L19-L37).

There are two plausible provider paths:

1. **Swift-owned providers:** Pi's `streamFn` sends normalized requests to MacParakeet, which uses its selected provider or local engine and returns normalized events. This preserves one authority for credentials, endpoint selection, and provider disclosure. It requires typed tool requests/results, usage, stop reasons, and cancellation throughout the Swift adapter.
2. **Pi-owned network providers:** `pi-ai` handles configured cloud/OpenAI-compatible endpoints directly. This reuses more provider code, but requires deliberate reconciliation with MacParakeet's settings, Keychain access, and local inference. It does not automatically call an in-process Swift model.

The second path is supported by Pi's provider collection and per-provider implementations; the first is our architectural inference from the injected stream contract. A provider object and its wire API are distinct abstractions. Pi also exposes compatibility fields for strict schemas, reasoning controls, mid-conversation tools, and other API differences. A unified API does not erase those differences. [Provider/model implementation](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/ai/src/models.ts), [compatibility/model types](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/ai/src/types.ts).

### History and source removal

Pi separates application messages from provider messages via `convertToLlm`, with `transformContext` before conversion. These are useful projection boundaries for a meeting application. The durable harness additionally offers session/lane state, compaction, and navigation. None of these mechanisms, by themselves, proves excluded meetings cannot survive inside old answers or compacted summaries. [Context projection](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/src/agent-loop.ts#L379-L409), [compaction source](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/src/harness/compaction/compaction.ts).

Proposed rule: freeze selected source IDs and revisions for a request; enforce them in Swift on every read. After removing sources, create a fresh model-context section and exclude prior derived answers/compaction from the active context. Keep the historical conversation visible with its original scope. Cancel or finish the old request before activating the new source set. These are MacParakeet requirements, not Pi guarantees.

### Native integration cost

For a prototype, use a managed local JavaScript helper over a small versioned IPC protocol. Register only domain tools such as searching selected sources, reading passage ranges, and obtaining metadata. Swift retains database access; helper tool handlers call back into that scoped service. Do not expose arbitrary files or shell tools merely because a framework offers them.

Pi's own RPC documents JSONL framing, backpressure, responses, events, and orderly shutdown. Its coding-agent handler also exposes a `bash` command and broader session/application operations. That is a useful transport reference, but a subprocess boundary alone does not sandbox an application. [RPC protocol](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/coding-agent/docs/rpc.md), [RPC command handler](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/coding-agent/src/modes/rpc/rpc-mode.ts).

The package manifests include Node requirements, provider SDKs, telemetry libraries, and other dependencies. No assertion is made that telemetry is enabled or exported by default; runtime configuration and data egress need inspection before adoption. Measure packaged size, cold start, memory, signing/notarization, shutdown, and upgrade behavior. No bundling strategy or JavaScriptCore compatibility was tested. [Agent dependencies](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/agent/package.json), [AI dependencies](https://github.com/earendil-works/pi/blob/d6af72e1857cfb10b41d8ff8e69f0d72b4cf6d31/packages/ai/package.json).

## OpenCode: existing server, larger application contract

OpenCode offers a ready headless server with sessions, events, and abort endpoints. Its JavaScript SDK launches the executable; it is not an in-process Swift orchestration library. [Server documentation](https://opencode.ai/docs/server/), [SDK launcher](https://github.com/anomalyco/opencode/blob/adee738d1e4597a2d0d317ca61a1625eff289efa/packages/sdk/js/src/server.ts).

The inspected runner separates a provider turn from tool execution and continuation, persists tool outcomes, handles interruption, applies configured step limits, and invokes compaction. Those are useful patterns for our own lifecycle contract. The current source also contains explicit TODOs, so this is evidence of implementation structure rather than a complete reliability qualification. [Runner](https://github.com/anomalyco/opencode/blob/adee738d1e4597a2d0d317ca61a1625eff289efa/packages/core/src/session/runner/llm.ts), [compaction](https://github.com/anomalyco/opencode/blob/adee738d1e4597a2d0d317ca61a1625eff289efa/packages/core/src/session/compaction.ts).

Its security document explicitly says permissions are not sandbox isolation. A constrained product integration would still need to control tool exposure, configuration, authentication, data retention, and subprocess lifecycle. [Security model](https://github.com/anomalyco/opencode/blob/adee738d1e4597a2d0d317ca61a1625eff289efa/SECURITY.md).

**Assessment:** retain as an alternative if a ready server and its broader session features materially reduce work. Pi's reusable `Agent` interface is a more direct initial fit for a native meeting product with app-owned tools. This is an architectural judgment, not a speed or quality benchmark.

## Pydantic AI: useful typed-contract and budget reference

Pydantic AI separates its agent graph from a `Model` abstraction with request/stream methods and model capability profiles. The inspected graph handles model requests, tool processing, retries, cancellation, and history. This is another concrete example of an agent runtime being independent of a particular provider. [Model abstraction](https://github.com/pydantic/pydantic-ai/blob/d0ea063717d88ef48c854d282bbb51c12a53065f/pydantic_ai_slim/pydantic_ai/models/__init__.py), [agent graph](https://github.com/pydantic/pydantic-ai/blob/d0ea063717d88ef48c854d282bbb51c12a53065f/pydantic_ai_slim/pydantic_ai/_agent_graph.py).

`UsageLimits` distinguishes requests, successful tool calls, cumulative input/output tokens, per-request context, and cost. Request limits are checked before requests; token limits normally use returned usage, while optional pre-request counting adds overhead and depends on the adapter. A token threshold is not automatically a hard preflight spending cap. Borrow these distinctions rather than adding one vague “max iterations” control. [Usage implementation](https://github.com/pydantic/pydantic-ai/blob/d0ea063717d88ef48c854d282bbb51c12a53065f/pydantic_ai_slim/pydantic_ai/usage.py#L453-L610).

History can be loaded and processed independently of the UI, but changing model/provider can impose compatibility constraints. History projection still needs to preserve valid request/tool-result structure. [History documentation](https://pydantic.dev/docs/ai/core-concepts/message-history/).

**Assessment:** a credible alternative if Python becomes an accepted runtime dependency. For this app, borrowing its explicit capability and budget design is immediately useful; adding a second alternative helper implementation before the Pi experiment would disperse effort.

## What “model agnostic” should mean here

Proposed product contract:

- The selected model is replaceable through a normalized request/event interface; no meeting tool depends on one vendor's message IDs or SDK types.
- The tool registry, source allowlist, source revisions, citation identities, and retention rules belong to MacParakeet.
- Capability profiles cover tool calling, schema fidelity, streaming, cancellation, context size, and usage reporting. Validate the chosen model/endpoint before enabling the agentic mode.
- Models that cannot reliably drive tools get an explicit supported fallback or an unavailable-state explanation. Never silently switch a local user to cloud inference.
- Switching providers does not replay opaque reasoning state blindly. Rebuild compatible history and preserve source boundaries.
- Equal answer quality, token accounting, or feature support across models is not promised.

These requirements follow from the adapter differences visible in Pi and Pydantic AI; they are proposed MacParakeet behavior, not existing guarantees.

## Smallest useful Pi experiment

1. Use synthetic meeting fixtures with repeated titles, missing summaries, corrections, conflicting decisions, and one excluded meeting containing a tempting answer.
2. Connect native source selection to a Pi `Agent` through the proposed helper. Provide search, bounded passage reads, metadata, and evidence references only.
3. Exercise two genuinely different providers and a local tool-capable model when available. Assess tool-call validity, grounded answers, coverage, latency, and usage independently.
4. Test stop during a model request and a tool read, helper failure, repeated tool calls, source removal, provider switching, and resumable historical display. Verify no stale result can mutate a newer run.
5. Compare the amount of adapter code and runtime overhead with a minimal Swift-loop baseline only where needed to resolve an actual adoption concern.

Adopt Pi if the experiment demonstrates a maintainable bridge, reliable source boundaries and cancellation, useful answers across the intended providers, and acceptable macOS packaging. Otherwise keep the domain contract and replace the loop. General code execution, recursive submodels, filesystem mounts, and autonomous external actions remain separate decisions.
