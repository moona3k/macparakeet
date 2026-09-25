# Meeting Ask: Circleback and Wispr Flow harness evidence

Date: 2026-09-25. Status: research and architectural recommendation; no implementation decision.

## Finding

Both products support an assistant that investigates meeting material. The strongest implementation evidence comes from **Wispr Flow 1.6.937**: its installed app contains a bounded Notetaker agent loop, virtual-file tools, saved agent trajectories, streamed progress, and a hosted agent endpoint. It also contains a **separate extension mechanism that launches Claude CLI**. Reusing a general agent and owning a product-specific loop are both represented in the same app; they are different call paths.

Circleback's current public client shows structured context selection, meeting/transcript tool-action types, streamed sources/actions, and reconnectable conversations. Its actual reasoning and retrieval implementation is behind a hosted API. Neither inspection establishes that either meeting assistant uses OpenCode, an RLM, or a generated-code REPL.

For MacParakeet, this supports owning the source/evidence contracts and comparing a small native tool loop with an existing runtime. A REPL remains an additional hypothesis to evaluate, not a prerequisite for an agentic meeting assistant. See the [workspace proposal](../../plans/2026-09-25-1308-feat-meeting-chat-workspace-plan.md).

## Scope and evidence quality

- **Observed static implementation:** read installed Wispr bundle metadata, ASAR contents, and shipped migration files without running its code. Read Circleback's public login-page JavaScript without authentication. These establish shipped client behavior, not successful runtime execution.
- **Documented product behavior:** current first-party help articles and release notes, linked below. These are vendor descriptions, not independently tested outcomes.
- **Inferred architecture:** identified separately from observations. Hosted implementation details remain unknown.
- No private application databases, credentials, recordings, or meeting contents were inspected. Neither app was launched; no live Ask request was submitted. No package installation or product-code change was needed. No Jev inference was used.
- The old [Wispr May teardown](../wisprflow-reverse-engineering-2026-05.md) described 1.5.308. Its conclusions cannot characterize the newer installed Notetaker. Circleback's [September dossier](../2026-09-11-circleback/) records an earlier 2.9.6 desktop inspection; that app and its temporary extraction are no longer present at the checked locations.

## Circleback: a hosted meeting assistant with structured context

Its official assistant guide documents questions across meetings, citations, chat history, and `@` references to meetings, tags, people, and companies. That directly supports the proposed searchable source-reference UX: a user chooses an entity rather than typing a unique meeting identifier. [Ask Circleback guide](https://support.circleback.ai/en/articles/13615023-ask-circleback-assistant).

Circleback also documents taking actions in connected apps through connectors/MCP, and updating derived person/company summaries as meetings accumulate. These extend beyond MacParakeet's proposed read-only meeting research; they demonstrate a wider product scope, not requirements we need to copy. [Connected-app actions](https://circleback.ai/releases/ask-circleback-to-do-things-in-your-apps), [person and company summaries](https://circleback.ai/releases/person-and-company-summaries).

Current public client evidence, using artifact IDs defined below:

| Observation | Source anchor | What it establishes |
| --- | --- | --- |
| Requests target `/api/assistant` or a meeting-specific assistant endpoint. Request fields include context, timezone, and the chat entity. | C1 bytes 184264, 185556 | Explicit context is passed to a hosted assistant; this is more than sending a textbox string. |
| Stream handling distinguishes sources and actions; active actions are keyed by tool-call ID. | C1 bytes 180329, 180718 | The UI can represent tool work and evidence separately from answer text. |
| A stream reference is retained under an assistant/chat session-storage key. | C1 byte 179713 | Client support for reconnecting to an existing stream; complete server recovery semantics are unknown. |
| Action types include meeting search, transcript search, transcript retrieval, meeting reads, calendar/email searches, and MCP calls. | C2 bytes 657873, 491408 | The client contract supports multiple domain operations. It does not reveal their implementations or which operations any particular run uses. |
| Action records carry tool-call/result IDs and time metadata; citations resolve through source IDs. | C2 bytes 491724, 826787 | Tool activity and citations have structured identity rather than relying solely on answer prose. |
| A public data hook references `/api/search/embedding`; shared models include a transcript-chunk embedding type. | C3 byte 41537; C2 byte 645284 | Retrieval-related client surfaces exist. This does not establish Ask's retrieval path, ranking algorithm, vector store, or actual embedding dimensionality. |

**Interpretation:** a hosted service plausibly conducts the tool-based investigation and streams its progress/evidence to the client. We cannot identify its orchestration framework, model, prompt, RLM/REPL use, or strict context-selection guarantees from this client evidence.

**Lesson for our design:** use stable references for selected meetings and cited passages, and separate run activity from the final answer. Circleback's `@` pattern is compatible with an expanded source picker; the two need not compete.

## Wispr Flow: a directly observable Notetaker harness

Wispr's current documentation describes two Ask surfaces: a meeting drawer that starts with the open meeting, and a hub that searches more broadly. The drawer can look elsewhere when the question or missing evidence warrants it. Answers identify source meetings; requested edits can change notes. This is a useful comparison, but it is **not the same contract as strictly limiting every operation to a user-selected source set**. [Ask Wispr guide](https://docs.wisprflow.ai/articles/5694642921-Ask-Wispr:-chat-with-your-meeting-notes).

The installed app's main bundle makes its implementation unusually visible:

| Piece | Observed implementation | Source anchor |
| --- | --- | --- |
| Turn setup | Opens a persisted chat turn, aborts an older run for that chat, selects hub/drawer configuration, prepares trajectory and current context. | W1 byte 8888543, function `yr` |
| Research loop | Calls the provider, identifies client filesystem tool calls, runs them, appends results, and calls the provider again. After ten client-tool rounds, it requests a final response with tools disabled. | W1 byte 8900090 |
| Model/host boundary | Uses an `openai_responses` configuration through Wispr's `/llm/agent_response` HTTP/SSE endpoint. | W1 bytes 8888543, 3451903 |
| Other tools | Requests a managed MCP server identified as `wispr`; the server's internal operations are not present here. | W1 byte 8898439 |
| Context management | Sends trajectory and an automatic-compaction threshold of 200,000; strips current-turn injected snapshots from the persisted trajectory path. | W1 bytes 8898439, 8900090 onward |
| Progress and stop | Streams message deltas and tool explanations, checks active-run identity, and uses abort signals. HTTP code has idle/wall timeouts and premature-stream-end handling. | W1 function `yr`; byte 3451903 |
| Durable state | A shipped migration defines per-chat agent trajectory, display sequence index, revision, and update time. | W3 |

The ten-round limit applies to **client filesystem-tool rounds**. A hosted response can itself involve managed tools; this is not proof of a ten-step limit across all backend reasoning or model work. Likewise, the compaction configuration is observed, but its hosted implementation and quality are unknown.

The model defaults in W1 are configurable by remote feature flags. The shipped fallback is `gpt-5.6-sol` with reasoning `none`; this does not establish the model currently serving a user's account.

### Virtual files rather than an unrestricted computer

The meeting drawer presents title, notes, summary, transcript, and speakers as named virtual files under `/wispr/`. Tools read a range, search literal text, or edit a permitted file. These are application-owned projections of meeting content, not evidence that the model can browse arbitrary local files. [W1 bytes 8881971, 8894320; W2 bytes 2185734–2187800.]

The implementation bounds reads to 20,000 characters and grep output to 40 lines of at most 400 characters each. The transcript is mounted read-only; notes/title/summary/speaker labels have conditional write access. Edits validate the mounted path and access, and use exact-match replacement. The drawer also supplies bounded initial snapshots, including up to 20,000 transcript characters, so it combines up-front context with further tool reads. This is not evidence that the transcript was never uploaded through recording/sync or other hosted paths. [W1 bytes 8879300–8881971, 8894320 onward; W2 bytes 2185734–2187800.]

This is already agentic: the model can inspect a source, request more content, and continue. A Python/JavaScript REPL or recursive submodel calls are not required to obtain that behavior. The inspected path establishes ordinary tool iteration; it does not prove that the hosted service lacks additional execution mechanisms.

Wispr separately exposes remote read-only MCP access to other assistants. Its documentation says that search covers titles, summaries, and notes, with long transcripts retrievable in portions; it does not promise transcript-body search. That distinction matters when evaluating exhaustive questions across many meetings. [Wispr MCP guide](https://docs.wisprflow.ai/articles/9551372685-connect-an-mcp-client-to-wispr-flow-remote-mcp-server).

### A separate example of reusing an existing agent

The bundle also contains an extension agent manager. It spawns the external `claude` executable with streaming JSON input/output, supports session resume, and bridges registered extension tools through an MCP process and a local socket. [W1 bytes 3026694, 3030262; W4.]

This is concrete evidence of a shipped integration with an existing general agent. It is **not evidence that Notetaker Ask uses Claude CLI**: the inspected Ask path calls the hosted response endpoint and its own client tool loop. We did not verify extension availability, activation, or successful CLI execution. A detected-coding-CLI enum containing `opencode` is also not evidence that Flow embeds OpenCode as its meeting runtime.

## Implication for MacParakeet and OpenCode

The earlier [OpenCode assessment](../../plans/2026-09-25-1308-feat-meeting-chat-workspace-plan.md#build-versus-reuse-opencode-assessment) remains a viable integration option. OpenCode documents a headless server and custom/MCP tools; its own security model says permissions are not a sandbox. [Server](https://opencode.ai/docs/server/), [custom tools](https://opencode.ai/docs/custom-tools/), [security model at reviewed revision](https://github.com/anomalyco/opencode/blob/adee738d1e4597a2d0d317ca61a1625eff289efa/SECURITY.md).

The new competitor evidence sharpens the experiment: **implement the meeting operations once, then compare a small application-owned loop with a managed existing runtime over those same operations.** Wispr shows that a product-specific loop is concrete and appropriately scoped; its separate CLI integration shows why runtime reuse remains credible. Neither vendor settles the choice for our Swift app.

MacParakeet must own selected-source enforcement, corrected transcript projection, stable passage citations, retained-data lifecycle, and cancellation. Runtime reuse can supply orchestration, but it cannot determine those product contracts for us. Our selection must remain authoritative even after a model has read a removed meeting into conversation history, compaction, or REPL variables.

Start with adaptive search/read/compare and inspectable evidence. Add a bounded REPL or model subcalls if the same evaluation questions show better coverage, useful computation, or lower context cost. Compare factual support, missed evidence, source-scope failures, cancellation/restart behavior, latency, provider usage, and packaging complexity. No competitor evidence justifies immediately committing to a generic coding runtime or a bespoke recursive framework.

## Reproducible source identities

Offsets below are zero-based **UTF-8 byte offsets in the named file**, not offsets in the ASAR archive. Symbol names provide a second lookup anchor. Hashes identify exactly the inspected artifacts; future updates may move or replace them.

Installed Wispr metadata: `/Applications/Wispr Flow.app/Contents/Info.plist`, bundle ID `com.electron.wispr-flow`, short/build version `1.6.937`. ASAR SHA-256: `b11c89eb55c538577096e50db1d0160fc8c5e1cd2a99e0c84eab464b7713f785`. This is the hash of the whole archive, distinct from Electron's header-integrity value in the plist.

| ID | Artifact | SHA-256 |
| --- | --- | --- |
| W1 | `Contents/Resources/app.asar` → `.webpack/main/index.js` | `f9be6b7265d07705e1ad50a02f7c2eac5a67483c0e2e08faca18fb640585c19e` |
| W2 | Same archive → `.webpack/renderer/hub/index.js` | `9d6177ebe0f37305bfdcde1dd6841f67b6c317e645ed9574b8e12a7db4142811` |
| W3 | `Contents/Resources/migrations/20260729120000-create-notetaker-chat-agent-states.js` | `77c5836d602c43aa7940be215ca9236b227c6854f45b05e8938b54d95a7948b4` |
| W4 | Same archive → `.webpack/main/agentToolBridge.js` | `1ff6c38b9951fd0a34a3b448be6b0fff00085e3930fea4a8285b227fbb302bf5` |
| C1 | [Current assistant client chunk](https://circleback.ai/_next/static/immutable/chunks/1abn6ohv0ssui.js) | `508bf579b545c2e35b16df26847eea528424263f949c9a722aa4429ca9f834e4` |
| C2 | [Current shared schema/rendering chunk](https://circleback.ai/_next/static/immutable/chunks/1bp42s8g3_b6g.js) | `e9c3629231afe8440f9e707f86b9d69cad3287594114cd603894d40065b30579` |
| C3 | [Current data-hook chunk](https://circleback.ai/_next/static/immutable/chunks/3uaoz-55i-apc.js) | `e79f10c6bbc13348a2e6adf600948997cdae9f7c6e40b8caebfa30721eeefd32` |

Circleback's public login page referenced 67 script assets, totaling 5,174,168 downloaded bytes. C1–C3 belong to that fresh page snapshot. Four historical assets remained downloadable but were not referenced by the current page; their continued availability was not treated as proof of current deployment. No current installed Circleback executable was available for inspection.

## What this does not establish

We have not tested answer accuracy, completeness, latency, current account flags, backend scope enforcement, deletion propagation, or production failure recovery in either assistant. We cannot identify Circleback's backend framework or either vendor's complete hosted tool loop. There is no verified evidence here of OpenCode-powered meeting chat, RLM recursion, or a generated-code REPL; absence of a matching bundle string would not establish their absence on a server.
