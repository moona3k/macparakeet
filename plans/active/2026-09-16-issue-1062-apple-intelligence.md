# Apple Intelligence on-device LLM provider (#1062)

> Status: **REVIEW**
> Date: 2026-09-16
> Issue: [#1062](https://github.com/moona3k/macparakeet/issues/1062)
> Branch: `feat/issue-1062-apple-intelligence`

## Context zone

**In scope**

- Add Apple's on-device Foundation Models (`SystemLanguageModel` /
  `LanguageModelSession`) as a first-class, user-selected LLM provider on
  macOS 26+ when the Mac is eligible.
- Wire it through the existing `LLMClientProtocol` / `RoutingLLMClient` seam
  so summaries, chat, Ask, Transforms, the AI formatter, and CLI inline
  commands work without per-feature pickers.
- Honest Settings copy for the three availability reasons Apple actually
  returns: not enabled, model still downloading, device not eligible.
- Dedicated short-context budget. No silent use of the 80k-char local window.

**Must not change**

- macOS 14.2 deployment floor.
- ADR-011: no auto-selected default provider, including for new Tahoe users.
- Spec 11: no automatic fallback to a second provider on overflow.
- Audio still never leaves the device.
- In-process MLX remains developer-gated and is not replaced by this path.

**Out of scope**

- `@Generable` structured decode, tool calling, permissive guardrails.
- SpeechAnalyzer / `ohr`, Apfel `--serve`, MCP, raising the OS floor.
- Token-budget honesty rewrite for every provider (#563).
- Making Apple Intelligence the recommended quality path vs cloud.

## Decisions (locked)

Fable 5.1 medium review (2026-09-17): **LGTM with nits**. Accepted:

| ID | Decision |
|---|---|
| A | Explicit select, not auto-default. A "great default" would be a broken default while Apple Intelligence is commonly `.appleIntelligenceNotEnabled`. |
| B | `#if canImport(FoundationModels)` + `@available(macOS 26.0, *)` so Xcode 16.1 CI still compiles. Protocol-seam generator for tests. |
| C | Fresh `LanguageModelSession` per request. Callers already send full history through `ChatMessage`. |
| D | Distinct 12k-char budget (not `isLocal` fallthrough) plus existing middle truncation; client still maps overflow. |
| E | Additive CLI `--provider appleIntelligence` in v1. |

Nits folded in: re-check availability on every request; map guardrail refusals;
audit `isLocal` / sentinel URL; exhaustive `LLMProviderID` switches; structured
output uses `.promptEmbeddedJSONSchema` (the existing non-native path; this
codebase has no "unsupported" capability case).

Live probe on this Mac (26.6.2): after enable, `.available`. Path smoke (native
`respond` / `streamResponse` / client) all returned `PING`. Quality/latency A/B
vs Ollama `qwen3.5:4b` and `llama3.2:3b` on cleanup, summary, and grounded Ask:
[`docs/research/2026-09-16-apple-intelligence-quality-ab.md`](../../docs/research/2026-09-16-apple-intelligence-quality-ab.md).

## Shape

```
LLMProviderID.appleIntelligence
  → RoutingLLMClient
      → AppleIntelligenceLLMClient
          → AppleIntelligenceGenerating
              → FoundationModelsAppleIntelligenceGenerator  (canImport + macOS 26)
              → UnavailableAppleIntelligenceGenerator       (CI / old OS)
```

Display name: **Apple Intelligence**. Sentinel URL: `appleintelligence://system`.
No API key, no model catalog, no base-URL override UI.
