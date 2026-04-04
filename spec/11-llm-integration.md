# 11 - LLM Integration

> Status: **IMPLEMENTED** - Done, still accurate (CLI command signatures updated 2026-04-02)
> Supersedes: Previous HISTORICAL version (local Qwen3-8B via mlx-swift-lm, removed 2026-02-23)
> ADR: ADR-011 (Cloud API keys + optional local providers)
> Note: §1 (Transcript Summary) and §3 (Custom Transforms) are superseded by [spec/12-processing-layer.md](12-processing-layer.md) — Prompt Library + multi-summary architecture. Provider protocol, chat, and CLI sections remain current.

This spec defines how MacParakeet integrates LLM-powered features via external providers.

---

## Goals

1. Deliver transcript summarization, chat, and custom transforms via user-configured LLM providers.
2. Support cloud APIs (Claude, GPT, Gemini), local runtimes (Ollama, LM Studio), and CLI tools (Claude Code, Codex) through one protocol.
3. Keep transcription 100% local — only transcript text is sent to LLM providers, never audio.
4. LLM features are optional — the app is fully functional without any provider configured.

## Non-Goals

1. Bundling any LLM runtime or model (no mlx-swift-lm, no llama.cpp, no model downloads).
2. Dictation-time LLM processing (no Command Mode, no AI refinement during dictation).
3. Building a hosted backend or proxy service.
4. Automatic fallback between providers.

---

## Architecture

```
User triggers LLM action (Summary / Chat / Transform)
    → LLMService (builds prompt with transcript context)
    → LLMExecutionContextResolver (resolves provider config + CLI config)
    → RoutingLLMClient
        → .localCLI: LocalCLILLMClient → LocalCLIExecutor (posix_spawn)
        → .other:    LLMClient (URLSession, POST /v1/chat/completions)
    → Response streamed back to UI
```

### Provider Protocol

All providers use the OpenAI-compatible chat completions API:

```
POST {baseURL}/chat/completions
Content-Type: application/json
Authorization: Bearer {apiKey}

{
  "model": "{modelName}",
  "messages": [
    {"role": "system", "content": "..."},
    {"role": "user", "content": "..."}
  ],
  "stream": true
}

SSE format: data: {"choices": [{"delta": {"content": "token"}}]}
Terminator: data: [DONE]

Parser must handle: empty delta objects, role-only frames,
finish_reason frames, and blank data: lines between events.
```

One protocol, one SSE parser, one code path. If Anthropic-specific features (prompt caching, extended thinking) are needed later, the client can branch on `config.id == .anthropic` internally with zero API change for consumers.

### Supported Providers

| Provider | Type | Default Base URL | Auth |
|----------|------|-----------------|------|
| Anthropic | Cloud | `https://api.anthropic.com/v1/` | `Authorization: Bearer` |
| OpenAI | Cloud | `https://api.openai.com/v1` | `Authorization: Bearer` |
| Google Gemini | Cloud | `https://generativelanguage.googleapis.com/v1beta/openai` | `Authorization: Bearer` |
| Ollama | Local | `http://localhost:11434/v1` | `apiKey: nil` in config; client injects `Bearer ollama` |
| LM Studio | Local | `http://localhost:1234/v1` | Optional `Authorization: Bearer` |
| Custom | Either | User-provided | Optional |
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
    public let isLocal: Bool           // true for Ollama/LM Studio/local custom
}

public enum LLMProviderID: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case gemini
    case ollama
    case lmstudio
    case custom
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
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse

    /// Streaming response
    func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error>

    /// Verify provider is reachable and auth is valid
    func testConnection(config: LLMProviderConfig) async throws
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
    func summarize(transcript: String) async throws -> String

    /// Chat about a transcript (maintains conversation context)
    func chat(
        question: String,
        transcript: String,
        history: [ChatMessage]
    ) async throws -> String

    /// Apply a custom transform to text
    func transform(text: String, prompt: String) async throws -> String

    /// Streaming variants
    func summarizeStream(transcript: String) -> AsyncThrowingStream<String, Error>
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
│  │   For fully local AI, use Ollama or     │ │
│  │   LM Studio.                            │ │
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

Custom transforms are stored in UserDefaults (not the database) because they're preferences, not user data. Built-in transforms are hardcoded and not editable.

---

## CLI Support

All CLI LLM commands require `--provider` and `--api-key` (except Ollama and Local CLI). Supported providers: `anthropic`, `openai`, `gemini`, `openrouter`, `ollama`, `cli`.

```bash
# Test provider connectivity
macparakeet-cli llm test-connection --provider openai --api-key sk-...

# Summarize a transcript file
macparakeet-cli llm summarize transcript.txt --provider anthropic --api-key sk-ant-...

# Chat with a transcript (--question flag required)
macparakeet-cli llm chat transcript.txt --provider openai --api-key sk-... --question "What were the action items?"

# Transform text with custom instruction
macparakeet-cli llm transform input.txt --provider anthropic --api-key sk-ant-... --prompt "Make formal"
```

```bash
# Local CLI provider (no API key needed)
macparakeet-cli llm test-connection --provider cli --command "claude -p --model haiku"
macparakeet-cli llm summarize transcript.txt --provider cli --command "claude -p --model haiku"
```

Additional options: `--model`, `--base-url`, `--local`, `--stream`, `--command` (Local CLI only). Use `-` as input to read from stdin.

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
- Ollama/LM Studio installation or model management.
- Cloud provider uptime or rate limits.

---

## Acceptance Criteria

1. User can configure any supported provider in Settings.
2. API keys are stored in Keychain, never in plain text.
3. "Test Connection" button verifies provider reachability and auth.
4. Summary button produces a streamed summary for any transcript.
5. Chat panel supports multi-turn conversation with transcript context.
6. Custom transforms can be created, edited, and deleted.
7. All LLM features are unavailable (greyed out with explanation) when no provider is configured.
8. Transcription continues to work fully offline regardless of LLM configuration.
9. Privacy notice in Settings clearly explains what data is sent where.
10. `swift test` passes with new LLM seam tests.
