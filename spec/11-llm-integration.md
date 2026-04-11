# 11 - LLM Integration

> Status: **IMPLEMENTED** - Done, still accurate (CLI command signatures updated 2026-04-02)
> Supersedes: Previous HISTORICAL version (local Qwen3-8B via mlx-swift-lm, removed 2026-02-23)
> ADR: ADR-011 (Cloud API keys + optional local providers)
> Note: §1 (Transcript Summary) and §3 (Custom Transforms) are superseded by [spec/12-processing-layer.md](12-processing-layer.md) — Prompt Library + multi-summary architecture. Provider protocol, chat, and CLI sections remain current.

This spec defines how MacParakeet integrates LLM-powered features via external providers.

---

## Goals

1. Deliver transcript summarization, chat, and custom transforms via user-configured LLM providers.
2. Support cloud APIs (Anthropic, OpenAI, Gemini, OpenRouter), local runtimes (Ollama), and CLI tools (Claude Code, Codex) through one shared service layer.
3. Keep core speech processing local and preserve a fully local setup when users stick to local providers/features — only transcript text is sent to LLM providers, never audio.
4. LLM features are optional — the app is fully functional without any provider configured.

## Non-Goals

1. Bundling any LLM runtime or model (no mlx-swift-lm, no llama.cpp, no model downloads).
2. Dictation-time LLM processing (no Command Mode, no AI refinement during dictation).
3. Building a hosted backend or proxy service.
4. Automatic fallback between providers.

---

## Architecture

```text
User triggers LLM action (Summary / Chat / Transform)
    → LLMService (builds prompt with transcript context)
    → LLMExecutionContextResolver (resolves provider config + CLI config)
    → RoutingLLMClient
        → .localCLI: LocalCLILLMClient → LocalCLIExecutor (posix_spawn)
        → .other:    LLMClient (URLSession)
            → .anthropic: POST /v1/messages
            → .ollama:    POST /api/chat
            → .openai/.gemini/.openrouter: POST /chat/completions
    → Response streamed back to UI
```

### Provider Protocol

The current branch does not flatten every provider into one wire protocol. `RoutingLLMClient` shares one high-level interface, but transport branches by provider:

- **Anthropic** uses the native Messages API (`POST /v1/messages`).
- **Ollama** uses the native chat API (`POST /api/chat`) so thinking can be disabled.
- **OpenAI, Gemini, OpenRouter, and LM Studio** use the OpenAI-compatible chat completions API (`POST /chat/completions` off each provider's configured base URL).
- **Local CLI** is not HTTP at all; prompts are passed to a subprocess via stdin/environment.

Streaming is provider-specific under the hood:

- Anthropic streams event frames from the Messages API.
- OpenAI-compatible providers stream SSE `data:` lines.
- Ollama streams NDJSON chat chunks.
- Local CLI yields stdout incrementally.

The service boundary stays stable even though the transport is mixed.

### Supported Providers

| Provider | Type | Default Base URL | Auth |
|----------|------|-----------------|------|
| Anthropic | Cloud | `https://api.anthropic.com/v1/` | `Authorization: Bearer` |
| OpenAI | Cloud | `https://api.openai.com/v1` | `Authorization: Bearer` |
| Google Gemini | Cloud | `https://generativelanguage.googleapis.com/v1beta/openai` | `Authorization: Bearer` |
| Ollama | Local | `http://localhost:11434/v1` | `apiKey: nil` in config; client injects `Bearer ollama` |
| LM Studio | Local | `http://localhost:1234/v1` | `apiKey: nil` in config |
| OpenRouter | Cloud | `https://openrouter.ai/api/v1` | `Authorization: Bearer` |
| Local CLI | CLI | N/A (subprocess) | N/A (tool manages its own auth) |

**Local CLI:** Users with Claude Code or Codex subscriptions can use their CLI tools directly. The app runs the configured command as a subprocess via `posix_spawn`, delivering prompts via stdin and `MACPARAKEET_*` environment variables. No API key needed — the CLI tool manages its own authentication. Built-in presets for Claude Code (`claude -p --model haiku`) and Codex (`codex exec --model gpt-5.4-mini`), or any custom command. See PR #47.

---

## Core Types

### Provider Configuration

```swift
public struct LLMProviderConfig: Codable, Sendable, Equatable {
    public let id: LLMProviderID
    public let baseURL: URL
    public let apiKey: String?         // nil for local providers; client injects Bearer ollama for Ollama
    public let modelName: String       // e.g. "claude-sonnet-4-20250514", "llama3.2"
    public let isLocal: Bool           // true for Ollama on the current branch
}

public enum LLMProviderID: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case gemini
    case openrouter
    case ollama
    case localCLI    // CLI tools (claude -p, codex exec) — no HTTP, no API key
}
```

API keys are stored in Keychain (via existing `KeychainKeyValueStore`), not UserDefaults. Provider config (ID, base URL, model name) is stored in UserDefaults. **Important:** `apiKey` must be excluded from `Codable` encoding via custom `CodingKeys` to prevent leaking secrets to UserDefaults. The key is always read/written separately through Keychain.

### Client Protocol

```swift
public protocol LLMClientProtocol: Sendable {
    /// Single response
    func chatCompletion(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse

    /// Streaming response
    func chatCompletionStream(
        messages: [ChatMessage],
        context: LLMExecutionContext,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error>

    /// Verify provider is reachable and auth is valid
    func testConnection(context: LLMExecutionContext) async throws

    /// Fetch available models when supported by the provider
    func listModels(context: LLMExecutionContext) async throws -> [String]
}

public struct ChatMessage: Codable, Sendable {
    public let role: Role
    public let content: String

    public enum Role: String, Codable, Sendable {
        case system, user, assistant
    }
}

public struct ChatCompletionOptions: Sendable {
    public let temperature: Double?
    public let maxTokens: Int?
}

public struct ChatCompletionResponse: Sendable {
    public let content: String
    public let model: String
    public let usage: TokenUsage?
}

public struct TokenUsage: Sendable {
    public let promptTokens: Int
    public let completionTokens: Int
}
```

### Service Protocol

```swift
public protocol LLMServiceProtocol: Sendable {
    /// Generate a summary of a transcript
    func summarize(transcript: String, systemPrompt: String?) async throws -> String

    /// Chat about a transcript (maintains conversation context)
    func chat(
        question: String,
        transcript: String,
        history: [ChatMessage]
    ) async throws -> String

    /// Apply a custom transform to text
    func transform(text: String, prompt: String) async throws -> String

    /// Streaming variants
    func summarizeStream(transcript: String, systemPrompt: String?) -> AsyncThrowingStream<String, Error>
    func chatStream(
        question: String,
        transcript: String,
        history: [ChatMessage]
    ) -> AsyncThrowingStream<String, Error>
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error>
}
```

### Error Types

```swift
public enum LLMError: Error, LocalizedError, Sendable {
    case notConfigured             // No provider set up
    case connectionFailed(String)  // Network/localhost unreachable
    case authenticationFailed      // Invalid API key
    case cliError(String)          // Local CLI subprocess failure
    case rateLimited               // Provider rate limit
    case modelNotFound(String)     // Model name invalid
    case contextTooLong            // Transcript exceeds model context
    case providerError(String)     // Provider-specific error message
    case streamingError(String)    // SSE parse failure or stream interruption
}
```

---

## Features

### 1. Transcript Summary

**Trigger:** "Summarize" button on transcript result view (file + YouTube transcriptions).

**Behavior:**
- Sends transcript text to LLM with a summary prompt
- Streams response into a summary section below the transcript
- Summary is persisted with the transcription record (new `summary` column)
- Re-summarize overwrites previous summary

**System prompt:**
```
You are a helpful assistant that summarizes transcripts. Provide a clear,
concise summary that captures the key points, decisions, and action items.
Use bullet points for clarity. Keep the summary under 500 words.
```

**Context assembly:** Full transcript text. If transcript exceeds the context budget, truncate from the middle — keep first 45% + last 45% of the budget with an ellipsis marker. Truncation snaps to word boundaries to avoid slicing multi-byte Unicode. **Budget:** 100,000 characters (~25K tokens) for cloud providers, 24,000 characters (~6K tokens) for local providers (`isLocal == true`) to fit within typical 8K context windows.

### 2. Chat with Transcript

**Trigger:** "Chat" button/tab on transcript result view.

**Behavior:**
- Opens a chat panel alongside the transcript
- User asks questions, LLM responds with transcript as context
- Conversation history maintained in-memory (not persisted across sessions)
- Streaming responses displayed incrementally

**System prompt:**
```
You are a helpful assistant. The user will ask questions about the following
transcript. Answer based on the transcript content. If the answer isn't in
the transcript, say so. Be concise and specific, citing relevant parts when helpful.

<transcript>
{transcript_text}
</transcript>
```

**Context assembly:** System prompt with full transcript + conversation history. Same context budget as summary (100K cloud / 24K local). If total context exceeds the budget, drop oldest conversation turns first (keep system prompt + transcript + recent turns).

### 3. Custom Transforms

> Historical note: the dedicated custom-transform concept below was the original design. The current branch routes this behavior through the Prompt Library in [spec/12-processing-layer.md](12-processing-layer.md) rather than a separate Settings-managed transform list.

**Trigger:** Context menu or toolbar action on selected text (transcript view or dictation history).

**Built-in transforms (not user-editable, shipped with app):**
- "Make formal"
- "Make concise"
- "Extract action items"
- "Fix grammar"

**Custom transforms (user-defined in Settings):**
- User provides a name and prompt template
- Stored in UserDefaults
- `{text}` placeholder replaced with selected text

**System prompt for transforms:**
```
{user_prompt_or_builtin_prompt}

Respond with only the transformed text. Do not add explanations or preamble.
```

---

## UI

> Historical note: the transcript chat surface is current, but the dedicated Custom Transforms settings sketch below predates the Prompt Library implementation in [spec/12-processing-layer.md](12-processing-layer.md).

### Settings > Intelligence

```
┌─────────────────────────────────────────────┐
│  Intelligence                                │
│                                              │
│  Provider: [Anthropic ▾]                     │
│                                              │
│  API Key:  [••••••••••••••••]  [Test ✓]     │
│                                              │
│  Model:    [claude-sonnet-4-20250514    ]      │
│                                              │
│  ┌─────────────────────────────────────────┐ │
│  │ ℹ Transcription is always local.        │ │
│  │   AI features send transcript text to   │ │
│  │   your chosen provider.                 │ │
│  │                                         │ │
│  │   For fully local AI, use Ollama.       │ │
│  └─────────────────────────────────────────┘ │
│                                              │
│  Custom Transforms                           │
│  ┌──────────────────────────────────┐        │
│  │ Make formal                      │        │
│  │ Make concise                     │        │
│  │ Extract action items             │        │
│  │ Fix grammar                      │        │
│  │ + Add custom transform...        │        │
│  └──────────────────────────────────┘        │
└─────────────────────────────────────────────┘
```

### Transcript View (with LLM features)

```
┌──────────────────────────────────────────────────────┐
│  my-recording.mp3                    [Summary] [Chat]│
│                                                      │
│  ┌─── Transcript ──────────────────────────────────┐ │
│  │ Speaker 1: Welcome everyone to the meeting...   │ │
│  │ Speaker 2: Thanks. Let's start with the update  │ │
│  │ on the Q1 results...                            │ │
│  │ ...                                             │ │
│  └─────────────────────────────────────────────────┘ │
│                                                      │
│  ┌─── Summary ─────────────────────────────────────┐ │
│  │ • Q1 results exceeded targets by 12%            │ │
│  │ • Decision to expand team by 3 headcount        │ │
│  │ • Action: Sarah to prepare hiring plan by Fri   │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

### Chat Panel

```
┌──────────────────────────────────────────────────────┐
│  Chat about this transcript                          │
│                                                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │ You: What were the main action items?           │ │
│  │                                                 │ │
│  │ AI: Based on the transcript, there were three   │ │
│  │ action items:                                   │ │
│  │ 1. Sarah to prepare hiring plan by Friday       │ │
│  │ 2. Mike to update the Q2 forecast...            │ │
│  │ ...                                             │ │
│  └─────────────────────────────────────────────────┘ │
│                                                      │
│  ┌─────────────────────────────────────────────────┐ │
│  │ Ask a question about this transcript...    [↑]  │ │
│  └─────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────┘
```

---

## Data Model Changes

> Historical note: this section predates the Prompt Library in [spec/12-processing-layer.md](12-processing-layer.md). The `summary` column shipped, but prompt persistence now lives in the prompt/summary model described in spec/12 rather than a standalone custom-transform store.

### Transcription table (existing, add column)

```sql
ALTER TABLE transcriptions ADD COLUMN summary TEXT;
```

### Custom transforms (new, UserDefaults — not DB)

```swift
struct CustomTransform: Codable, Identifiable {
    let id: UUID
    var name: String        // "Make formal"
    var prompt: String      // "Rewrite the following text in a formal tone: {text}"
    var isBuiltIn: Bool     // true for shipped transforms, false for user-created
}
```

Custom transforms were the original plan. The current branch instead routes summary/transform prompting through the Prompt Library architecture in [spec/12-processing-layer.md](12-processing-layer.md).

---

## CLI Support

All CLI LLM commands require `--provider` and `--api-key` (except Ollama, LM Studio, and Local CLI). Supported providers: `anthropic`, `openai`, `gemini`, `openrouter`, `ollama`, `lmstudio`, `cli`.

```bash
# Test provider connectivity
macparakeet-cli llm test-connection --provider openai --api-key sk-...

# Summarize a transcript file
macparakeet-cli llm summarize transcript.txt --provider anthropic --api-key sk-ant-...

# Chat with a transcript (--question flag required)
macparakeet-cli llm chat transcript.txt --provider openai --api-key sk-... --question "What were the action items?"

# Transform text with custom instruction
macparakeet-cli llm transform input.txt --provider anthropic --api-key sk-ant-... --prompt "Make formal"

# LM Studio provider (no API key needed)
macparakeet-cli llm test-connection --provider lmstudio --model qwen3.5-27b
macparakeet-cli llm summarize transcript.txt --provider lmstudio --model qwen3.5-27b
```

```bash
# Local CLI provider (no API key needed)
macparakeet-cli llm test-connection --provider cli --command "claude -p --model haiku"
macparakeet-cli llm summarize transcript.txt --provider cli --command "claude -p --model haiku"
```

Additional options: `--model`, `--base-url`, `--stream`, `--command` (Local CLI only). Use `-` as input to read from stdin.

CLI LLM commands use ephemeral inline config (not shared with GUI UserDefaults/Keychain).

---

## Testing

### Unit Tests

1. **LLMClient**: Mock URLSession, verify request format (headers, body, auth) for each provider type.
2. **LLMService**: Mock LLMClient, verify prompt assembly for summarize/chat/transform.
3. **Context assembly**: Verify truncation behavior when transcript exceeds limits.
4. **Provider config**: Verify Keychain storage/retrieval of API keys. Verify UserDefaults storage of provider config.
5. **Error mapping**: Verify error mapping inspects response body JSON first (providers return `{"error": {"message": "...", "type": "..."}}`), then falls back to HTTP status codes.
6. **Streaming**: Verify SSE parsing for streamed responses.

### Integration Tests

1. **Provider connectivity**: Test connection to each provider type (mocked HTTP server).
2. **End-to-end flow**: Transcript → summarize → persist summary → display.

### What We Skip

- Actual LLM output quality (depends on external model, not our code).
- Ollama installation or model management.
- Cloud provider uptime or rate limits.

---

## Acceptance Criteria

1. User can configure any supported provider in Settings.
2. API keys are stored in Keychain, never in plain text.
3. "Test Connection" button verifies provider reachability and auth.
4. Summary, chat, and transform actions route through `LLMService` and stream results in the current UI/CLI surfaces.
5. Chat panel supports multi-turn conversation with transcript context.
6. Prompt-driven transforms remain supported through `LLMService`, with Prompt Library details defined in [spec/12-processing-layer.md](12-processing-layer.md).
7. All LLM features are unavailable (greyed out with explanation) when no provider is configured.
8. Transcription continues to work fully offline regardless of LLM configuration.
9. Privacy notice in Settings clearly explains what data is sent where.
10. `swift test` passes with new LLM seam tests.
