# Plan: `--json` output mode for CLI LLM commands

> Status: **IMPLEMENTED for non-streaming JSON in PR #149** — NDJSON streaming deferred
> Author: agent (Claude) + Daniel
> Date: 2026-04-26
> Related: PR #138 (CLI prompts + JSON sweep, merged), PR #144 (CLI 1.0 + AGENTS.md, merged), PR #147 (1.0.1 transcribe stderr fix, merged), PR #148 (post-1.0 bug cleanup, in review)

---

## TL;DR

Add `--json` to the four LLM CLI commands (`summarize`, `chat`, `transform`, `test-connection`) plus `prompts run`, before 1.x output shapes harden into a contract. Agents calling the CLI today get free-form prose; they want a structured envelope with model, usage, and latency so cost/observability dashboards work and so multi-step pipelines don't have to regex the output.

This is mostly a **MacParakeetCore refactor**: today `LLMService.summarize/chat/transform` returns `String`. To populate `usage`/`stopReason`/`latencyMs`, each of the 8 providers in `RoutingLLMClient` needs to surface a result envelope. The CLI change is the easy part.

---

## Output schema (decided)

### Non-streaming

```json
{
  "output": "...",
  "provider": "anthropic",
  "model": "claude-sonnet-4-6",
  "usage": {
    "promptTokens": 1234,
    "completionTokens": 567,
    "totalTokens": 1801
  },
  "latencyMs": 2345,
  "stopReason": "end_turn"
}
```

- **Token names**: OpenAI-compat (`promptTokens`/`completionTokens`/`totalTokens`). Already familiar to agent authors building on top of OpenAI/Anthropic SDKs.
- **`usage`**: omitted when the provider doesn't surface it (`localCLI`; some `openaiCompatible` servers).
- **`stopReason`**: pass-through, not normalized. Honest over friendly. Document the per-provider strings agents will actually see.

### Streaming (`--stream --json`) — deferred NDJSON follow-up

```ndjson
{"type":"delta","output":"Hello"}
{"type":"delta","output":" world"}
{"type":"final","output":"","provider":"anthropic","model":"claude-sonnet-4-6","usage":{...},"latencyMs":2345,"stopReason":"end_turn"}
```

- One JSON object per line, terminated with `\n`.
- Always ends with exactly one `final` line. Usage-less providers omit `usage`, matching the one-shot envelope.
- Streaming deltas carry content as it arrives; the final `output` is empty unless a future implementation explicitly chooses to repeat the concatenated text.
- Lets agents share a parser between streaming and one-shot paths.
- In PR #149, `--json --stream` is rejected during argument validation with a clear error.

### `test-connection --json`

```json
{ "ok": true, "provider": "anthropic", "model": "claude-sonnet-4-6", "latencyMs": 234 }
```

### Errors

Stdout stays empty on failure. Stderr gets the `LocalizedError` text. Exit code non-zero. **No `{"error": ...}` envelope on stdout** — consistent with how the rest of the CLI already behaves and avoids the "did this succeed with empty output?" ambiguity.

### `prompts run --json`

Same envelope. `prompts run` is the same operation under the hood; agents will expect it to behave identically. The "Saved PromptResult X" confirmation continues to land on stderr.

---

## Provider capability table

| Provider | output | model | provider | usage | stopReason | latencyMs |
|---|---|---|---|---|---|---|
| `anthropic` | yes | yes | yes | yes (`input_tokens`/`output_tokens`) | yes (`end_turn`/`max_tokens`/`stop_sequence`/`tool_use`) | yes |
| `openai` | yes | yes | yes | yes (`prompt_tokens`/`completion_tokens`/`total_tokens`) | yes (`stop`/`length`/`tool_calls`) | yes |
| `openaiCompatible` | yes | yes | yes | server-dependent — omitted if absent | server-dependent | yes |
| `gemini` | yes | yes | yes | yes (different field names — normalize) | yes (`STOP`/`MAX_TOKENS`/`SAFETY`/`RECITATION`) | yes |
| `openrouter` | yes | yes | yes | yes (varies by upstream — pass through) | yes (varies) | yes |
| `ollama` | yes | yes | yes | partial (`prompt_eval_count`/`eval_count`) | yes (`done_reason`) | yes |
| `lmstudio` | yes | yes | yes | yes (OpenAI-compatible) | yes | yes |
| `localCLI` | yes | `cli` | yes (`localCLI`) | omitted | omitted | yes |

Normalization rule: providers map their native usage fields to `promptTokens`/`completionTokens`/`totalTokens`. PR #149 emits usage only when the provider reports enough data to avoid fabrication; the public schema still allows partial fields if a future provider can honestly report them.

---

## Implementation phases

### Phase 1 — Core API change (MacParakeetCore)

Add a result envelope type:

```swift
public struct LLMResult: Sendable, Codable {
    public let output: String
    public let provider: String
    public let model: String
    public let usage: LLMUsage?
    public let stopReason: String?
    public let latencyMs: Int
}

public struct LLMUsage: Sendable, Codable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
}
```

Augment `LLMService` with envelope-returning variants — keep the existing `String`-returning methods so the GUI doesn't churn:

```swift
public func summarize(transcript: String) async throws -> String  // existing — unchanged
public func summarizeWithMetadata(transcript: String) async throws -> LLMResult  // new
```

Same for `chat`, `transform`, and `generatePromptResult`.

For streaming, introduce a `LLMStreamEvent` enum:

```swift
public enum LLMStreamEvent: Sendable {
    case delta(String)
    case final(LLMResult)
}
```

New stream methods return `AsyncThrowingStream<LLMStreamEvent, Error>`. Existing `AsyncThrowingStream<String, Error>` methods remain.

### Phase 2 — Provider plumbing (RoutingLLMClient)

Each `LLMClient` gains an envelope-returning method that captures upstream metadata. Where the underlying SDK already exposes usage (Anthropic, OpenAI, Gemini), this is mechanical. Ollama needs its `done`/`eval_count` fields wired through. `localCLI` omits `usage`. `openaiCompatible` honors usage if the server returns it, else omits it.

Latency is measured at the client boundary: `let start = Date(); ... ; latencyMs = Int(Date().timeIntervalSince(start) * 1000)`.

### Phase 3 — CLI surface

```swift
struct LLMSummarizeCommand: AsyncParsableCommand {
    @Flag(name: .long) var json: Bool = false
    // ... existing flags
}
```

Branching:
- `!json && !stream` — existing behavior (`print(output)`).
- `!json && stream` — existing behavior (token stream to stdout).
- `json && !stream` — call envelope variant, print one JSON object via shared `printJSON` helper.
- `json && stream` — rejected at argument validation in PR #149. NDJSON streaming is a follow-up.

`prompts run` gets the same `--json` flag. The "Saved PromptResult" confirmation continues on stderr.

`test-connection --json` is a smaller change — just wraps the existing test path and reports `{ok, provider, model, latencyMs}`.

### Phase 4 — Tests

- Unit: envelope encoding round-trips, omitted-optional-field shape, and `--json --stream` validation.
- Integration: at least one provider path end-to-end (Ollama is the obvious choice — runs locally, no API key, exposes usage). Capture stdout, parse one JSON object, assert envelope shape.
- Schema golden: a small JSON snapshot per command so future drift surfaces in review.

---

## Sequencing relative to PR #148

Implementation waits for #148 to merge so the new branch can fork off main without conflicting on the `printErr` changes #148 lands in `LLMSummarize/Chat/Transform/Test/Feedback`.

Plan doc lands now (cheap, lets reviewers redirect schema decisions before code exists).

---

## What's explicitly out of scope

- **Cost-in-USD calculation.** Token counts are enough. Pricing tables churn weekly and belong in user-facing dashboards, not in a deterministic CLI envelope.
- **`stopReason` normalization.** Pass-through. Each agent ecosystem will normalize per their own taxonomy.
- **Tool-use / function-calling envelope.** Not surfaced today by these commands; revisit when/if MacParakeet exposes it.
- **Cache hit/miss flags.** Anthropic prompt caching surfaces these, but not all providers do — and MacParakeet doesn't currently use prompt caching anywhere.
- **Backwards-compatibility for the existing `String`-returning methods.** Keep them. The GUI is a happy consumer; no reason to churn.

---

## Open decisions

None left to resolve. (Earlier round: token names = OpenAI-compat; `stopReason` = pass-through; streaming follow-up = NDJSON with terminating `final`; errors = stderr + non-zero exit, no JSON envelope; `prompts run` included.)

---

## Success signal

An agent author can pipe `macparakeet-cli llm summarize transcript.txt --provider anthropic --api-key ... --json | jq '.usage.totalTokens'` and get an integer. The same envelope shape is observable across all 8 providers, with the `usage` field honestly absent when unavailable. NDJSON streaming will let `read line; jq -r '.output' <<< "$line"` work in a shell loop in the follow-up.
