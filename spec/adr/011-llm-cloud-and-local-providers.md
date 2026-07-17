# ADR-011: LLM via Cloud API Keys + Optional Local Providers

> Status: **Accepted**
> Date: 2026-03-11
> Supersedes: ADR-008 (local-only Qwen3-8B via mlx-swift-lm, removed 2026-02-23)

## Context

MacParakeet has a rich transcript dataset (file transcriptions, YouTube transcriptions, dictation history) but no way to do anything intelligent with it beyond deterministic text cleanup. Users can export transcripts but can't summarize them, ask questions about them, or transform them with AI.

### Previous Attempt (ADR-008)

In February 2026, we shipped Qwen3-8B locally via mlx-swift-lm on the GPU. It was removed 10 days later because:

1. **Quality was mediocre.** A local 8B model produces "okay" summaries and transforms — nowhere near the quality users expect from AI in 2026.
2. **Scope exploded.** Five processing modes (raw/clean/formal/email/code), Command Mode, and Chat with Transcript turned a simple app into a complex one.
3. **Resource cost was high.** ~5 GB GPU RAM for the LLM model, competing with user's other apps. 8 GB Macs were marginal.
4. **Maintenance burden.** mlx-swift-lm had breaking API changes. Pinning, validating, and packaging a 5 GB model added significant complexity.

The product decision to remove it was correct — the local LLM didn't deliver enough value to justify the complexity.

### What Changed

The insight is: **the problem was the runtime, not the features.** Summarization, chat-with-transcript, and text transforms are genuinely valuable. The mistake was trying to run the LLM locally instead of letting users bring their own provider.

Cloud models (Claude, GPT-4, Gemini) are dramatically better than any local 8B for these tasks. And the "bring your own API key" pattern is well-established (Cursor, Raycast, Continue, many others). Users who want local-only can point at Ollama, or use a Local CLI tool if they prefer that workflow.

### Competitive Validation

Char (fastrepl/char) — a meeting transcription app — supports this general BYO-provider pattern. That validates the product direction even though MacParakeet now uses a mixed transport layer: Anthropic native Messages API, Ollama native `/api/chat`, OpenAI-compatible providers including LM Studio, and Local CLI subprocess execution.

## Decision

**Public/default LLM features use external providers via API.** MacParakeet does not bundle a model, does not download one automatically, and does not expose a public/default in-process runtime unless the Local MLX gates pass. Users configure their preferred provider in Settings.

### Supported Providers

The current implementation supports these provider/runtime types through one shared service layer:

| Provider | Type | Base URL | Auth |
|----------|------|----------|------|
| Anthropic (Claude) | Cloud | `https://api.anthropic.com/v1/` | API key (`Authorization: Bearer`) |
| OpenAI (GPT) | Cloud | `https://api.openai.com/v1` | API key (`Authorization: Bearer`) |
| Google (Gemini) | Cloud | `https://generativelanguage.googleapis.com/v1beta/openai` | API key (`Authorization: Bearer`) |
| OpenRouter | Cloud | `https://openrouter.ai/api/v1` | API key (`Authorization: Bearer`) |
| OpenAI-Compatible | Custom | User-configured `/v1` endpoint | Provider-specific API token or none |
| Ollama | Local | `http://localhost:11434/v1` | `apiKey: nil` in config; client injects `Bearer ollama` |
| LM Studio | Local | `http://localhost:1234/v1` | Optional API token (`Authorization: Bearer`) |
| Local CLI | CLI | N/A (subprocess) | N/A (tool manages its own auth) |
| Local MLX | In-process local, developer-gated | `inprocess://local` | N/A |

**Amendment (2026-04-03): Local CLI provider.** Users with Claude Code or Codex subscriptions can use their CLI tools (`claude -p`, `codex exec`, or any custom command) for summaries, chat, and transforms — no separate API key needed. The CLI tool runs as a subprocess via `posix_spawn` with process group management. Prompts are delivered via stdin and `MACPARAKEET_*` environment variables. This extends the provider model without changing the `LLMClientProtocol` — a `RoutingLLMClient` dispatches `.localCLI` contexts to `LocalCLILLMClient` and everything else to the HTTP `LLMClient`. See PR #47.

**Implementation note (2026-04-04):** Anthropic now uses the native Messages API and Ollama uses its native `/api/chat` endpoint. OpenAI, Gemini, OpenRouter, and LM Studio use OpenAI-compatible chat completions. The shared abstraction is the service/client interface, not a single wire protocol.

### Locked Decisions

1. **No bundled/default LLM runtime.** No LLM model is bundled, no local model downloads automatically, and no local LLM is public-default. The in-process MLX implementation is isolated behind a gated app-build target, and the verified first-party model downloader/setup UI is developer-gated while the public feature flag remains off.
2. **Provider-aware transport behind one shared service boundary.** Runtime choices are external providers, OpenAI-compatible endpoints, local servers, or Local CLI tools. Transport details may vary per provider.
3. **LLM features are optional.** The app is fully functional without any provider configured. Transcription, dictation, export — all work without LLM.
4. **No default provider.** User must explicitly choose and configure. No "sign up for our cloud" upsell.
5. **Transcription stays local.** Audio never leaves the device. The app can remain fully local when users choose only local providers/features. Only transcript text is sent to providers/CLI tools when the user explicitly triggers an LLM feature. This distinction must be clear in the UI.

**Amendment (2026-07-04): direction confirmed, positioning fixed.** Product decision: MacParakeet will offer a first-party local model (Qwen/Gemma-class via MLX) as a dead-simple, one-click *option* aimed at non-technical and privacy-first users, while cloud/frontier providers remain the recommended quality path per surface until the local model demonstrably reaches parity there. Phase 0 in `plans/active/2026-06-27-on-device-local-llm.md` gates the public product promise, any default/recommendation, and the shipped surface scope; it is not a denial that non-public foundation code can exist. Shipping bar per surface: fidelity-safe and clearly above the deterministic pipeline to *offer*; cloud parity to *recommend*. Agentic/tool-calling and whole-library analysis stay cloud-first until proven.

**Amendment (2026-07-05): developer-gated Local MLX foundation.** The provider seam, gated MLX runtime wiring, verified model downloader, and one-click Settings card may exist in `main` as non-public infrastructure. `AppFeatures.inProcessLocalLLMEnabled` stays `false`; developers expose the option with `MacParakeetEnableInProcessLocalLLM` or `--enable-local-ai`. Public one-click setup remains blocked by runtime capability gating, setup UX, release readiness, and Phase 0 quality evidence. The first plausible public scope is single-transcript cleanup/summarization/Q&A; cross-meeting or whole-library analysis remains future-gated. The app still never bundles a model, never downloads one automatically, and never recommends Local MLX over cloud/frontier quality until surface-specific evidence justifies that change.

### Features Enabled

| Feature | Description | Scope |
|---------|-------------|-------|
| **Summary / Prompt Results** | One-click or prompt-library transcript outputs | File, URL, and meeting transcriptions |
| **Chat / Meeting Ask** | Ask questions about a finalized transcript or a live meeting transcript | File, URL, and meeting transcriptions; live meetings |
| **AI Formatter** | Optional post-STT cleanup for dictation and file transcripts | Dictation and file transcription final text |
| **Transforms** | System-wide selected-text rewrites through saved prompts/hotkeys | User-selected text in other apps |
| **Custom Prompts** | User-defined transcript prompt outputs | File, URL, and meeting transcriptions |

LLM features stay explicit and provider-backed. The app still ships no bundled/default LLM and no voice Command Mode. AI Formatter runs only after local STT has produced text; it is optional, can be disabled, and never changes the fact that audio stays local.

## Rationale

### Quality over locality for text intelligence

Local 8B models produce mediocre summaries. Cloud models (Claude Sonnet, GPT-4o) produce excellent ones. Users expect quality. The cost of cloud API calls is pennies per transcript for users who bring their own keys, avoiding a hosted backend dependency for the current LLM design.

### Zero resource impact

No GPU memory, model downloads, or ANE contention in the public/default product path. The app's resource profile stays focused on STT unless a developer explicitly enables and tests the gated Local MLX path. Public LLM inference still happens outside the app's process — either on a remote server, in Ollama's separate process, or inside an external CLI tool.

### Privacy spectrum, user's choice

| Provider | Audio leaves device? | Transcript text leaves device? |
|----------|---------------------|-------------------------------|
| None (default) | No | No |
| Ollama | No | No (localhost) |
| Local CLI | No | Depends on the CLI tool |
| Cloud API | No | **Yes (user-initiated, text only)** |

Users choose their privacy/quality tradeoff. The app makes the tradeoff explicit in the UI. Audio NEVER leaves the device regardless of provider choice.

### Implementation simplicity

One Swift service boundary with provider-aware routing. The current implementation keeps UI/domain code simple while allowing provider-specific transport where needed. The developer-gated Local MLX path owns its model management, runtime lifetime, and idle unload behavior behind `InProcessLLMClient`; normal provider call sites do not change.

### Bring-your-own-model via local providers

Users who want local-only LLM can install Ollama (`brew install ollama && ollama pull llama3.2`) and point MacParakeet at `localhost:11434`. They get local privacy with whatever model they choose. MacParakeet doesn't need to know or care what model is running.

## Consequences

### Positive

- LLM features with zero resource impact on the app
- Best-in-class quality via cloud models (Claude, GPT-4)
- Local-only option via Ollama for privacy users
- Minimal implementation complexity (~200-300 lines of networking code)
- No new SPM dependencies in default builds; MLX dependencies are gated
- No automatic model downloads, GPU memory, or ANE contention in the default path
- Lightweight default distribution footprint with no bundled model
- Users control their own costs (their API keys, their usage)

### Negative

- **Cloud providers require internet.** LLM features won't work offline unless user has Ollama running. This is acceptable because transcription (the core value) works fully offline.
- **Cloud providers cost money.** API calls are cheap (cents per transcript) but non-zero. Users manage their own billing. We should show estimated token counts before sending.
- **Privacy nuance.** "100% local" messaging needs updating to "speech stays local, and the app can remain fully local if you use only local paths." Must be clear and honest.
- **Transcript text sent to cloud.** When using cloud providers, transcript text leaves the device. Audio never does. The distinction must be explicit in the UI and docs.
- **Provider API changes.** Provider-native and OpenAI-compatible APIs may change independently. Mitigated by keeping routing isolated inside the client layer.
- **No offline summarization.** Users without Ollama and without internet get no LLM features. The deterministic clean pipeline still works for basic text cleanup.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    MacParakeet App                        │
│                                                          │
│  TranscriptResultView / DictationHistoryView             │
│       │                                                  │
│       ▼                                                  │
│  ┌──────────────────┐                                    │
│  │  LLMService      │  (protocol)                        │
│  │  .summarize()    │                                    │
│  │  .chat()         │                                    │
│  │  .transform()    │                                    │
│  └────────┬─────────┘                                    │
│           │                                              │
│           ▼                                              │
│  ┌──────────────────┐    ┌──────────────────────────┐   │
│  │ RoutingLLMClient │───▶│  LLMExecutionContext      │   │
│  │                  │    │  - providerConfig          │   │
│  │  .localCLI ──▶ LocalCLILLMClient                  │   │
│  │  .other ────▶ LLMClient (HTTP)                    │   │
│  └──────────────────┘    └──────────────────────────┘   │
│           │                        │                     │
└───────────┼────────────────────────┼─────────────────────┘
            │                        │
            ▼                        ▼
   ┌─────────────────┐   ┌──────────────────┐   ┌────────────────┐
   │  Cloud API       │   │  Local Runtime   │   │  CLI Tool      │
   │  (Claude/GPT/    │   │  (Ollama,        │   │  (claude -p,   │
   │   Gemini)        │   │                  │   │   codex exec)  │
   │                  │   │   LM Studio)     │   │                │
   └─────────────────┘   └──────────────────┘   └────────────────┘
```

### Key Types

```swift
/// Provider configuration — provider ID + model in UserDefaults, API key in Keychain
public struct LLMProviderConfig: Codable, Sendable, Equatable {
    public let id: LLMProviderID       // .anthropic, .openai, .ollama, etc.
    public let baseURL: URL
    public let apiKey: String?         // nil for providers without auth; optional for LM Studio/OpenAI-compatible
    public let modelName: String       // "claude-sonnet-4-6", "gpt-4.1", "qwen3.5:4b"
    public let isLocal: Bool           // true for Ollama, LM Studio, and loopback OpenAI-compatible endpoints
}

public enum LLMProviderID: String, Codable, Sendable, CaseIterable {
    case anthropic, openai, openaiCompatible, gemini, openrouter, ollama, lmstudio, localCLI, inProcessLocal
    // localCLI runs CLI tools (claude -p, codex exec) as subprocesses — no HTTP, no API key.
    // inProcessLocal is developer-gated Local MLX — no HTTP, no API key.
}

/// Client — routes provider-specific HTTP or CLI transport behind one interface
public protocol LLMClientProtocol: Sendable {
    func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse

    func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error>

    func testConnection(context: LLMExecutionContext) async throws
    func listModels(context: LLMExecutionContext) async throws -> [String]
}

/// High-level service — domain-specific operations
public protocol LLMServiceProtocol: Sendable {
    func summarize(transcript: String, systemPrompt: String?) async throws -> String
    func summarizeStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error>
    func chat(question: String, transcript: String, history: [ChatMessage]) async throws -> String
    func chatStream(question: String, transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    func transform(text: String, prompt: String) async throws -> String
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error>
}
```

### What Lives Where

| Component | Target | Notes |
|-----------|--------|-------|
| `LLMClientProtocol` | MacParakeetCore | HTTP client, no UI deps |
| `LLMProviderConfig` | MacParakeetCore | Model + Codable |
| `LLMService` | MacParakeetCore | Domain operations (summarize, chat, transform) |
| `LLMSettingsView` | MacParakeet (GUI) | Provider picker, API key input, test connection |
| `TranscriptChatView` | MacParakeet (GUI) | Chat UI for transcript Q&A |
| `LLMViewModel` | MacParakeetViewModels | Testable orchestration |

## Alternatives Considered

### Bundle mlx-swift-lm again (local-only)

Rejected. Already tried and removed (ADR-008). Quality ceiling is too low, resource cost too high, maintenance burden too large. The cloud API approach delivers better results with less code and zero resource impact.

### Bundle Ollama/llama.cpp

Rejected. Spawning an external daemon violates App Store sandboxing, adds distribution complexity, and is slower than MLX on Apple Silicon anyway. Users who want local LLM can install Ollama themselves — we just connect to it.

### Build a hosted backend (proxy API keys through our server)

Rejected for the current LLM design. Adds server costs, requires a separate hosted-service monetization model, adds a reliability dependency, and adds a privacy concern (we'd see transcript text). Users bringing their own keys is simpler, cheaper, and more private. This does not prohibit future paid hosted services if explicitly designed and documented.

### Anthropic native Messages API (historical alternative)

Historical note: this alternative has since been implemented. Anthropic now uses the native Messages API behind the same `LLMClientProtocol` boundary, while the higher-level product decision in this ADR remains unchanged.

## References

- ADR-002: Local-first processing (updated with LLM provider exception)
- ADR-008: Previous local LLM approach (HISTORICAL)
- `spec/11-llm-integration.md`: Previous integration spec (HISTORICAL)
- Char (fastrepl/char): Meeting app with cloud + local-provider LLM support
- Cursor, Raycast, Continue: Precedent for "bring your own API key" in developer tools
