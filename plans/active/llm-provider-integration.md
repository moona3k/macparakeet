# LLM Provider Integration Plan

> Status: **ACTIVE**
> ADR: 011 (Cloud API keys + optional local providers)
> Spec: spec/11-llm-integration.md

## Overview

Add LLM-powered features (Summary, Chat, Custom Transforms) via external providers. Users configure their own provider (Claude, GPT, Gemini, Ollama, LM Studio, or custom). No bundled LLM runtime — zero resource impact.

## Design Decisions

1. **One HTTP client, all providers.** All providers use the OpenAI-compatible `/v1/chat/completions` endpoint. One `LLMClient` implementation covers everything.
2. **Streaming by default.** All LLM responses stream via Server-Sent Events (SSE). Better UX for long responses.
3. **API keys in Keychain.** Via existing `KeychainKeyValueStore` pattern. Provider config (ID, base URL, model) in UserDefaults.
4. **LLM features are transcript-level actions.** No dictation-time processing. Summary/Chat/Transform appear on transcript detail views.
5. **Anthropic Messages API.** Anthropic's OpenAI-compatible endpoint has limitations (no streaming in some configurations). Use the native Messages API for Anthropic, OpenAI-compatible for everything else.

## Implementation Phases

### Phase 1: Core LLM Client (MacParakeetCore)

The foundation — HTTP client and provider configuration. No UI yet.

#### Step 1.1: Provider Config Model

**File:** `Sources/MacParakeetCore/Models/LLMProvider.swift`

```swift
public enum LLMProviderID: String, Codable, Sendable, CaseIterable {
    case anthropic
    case openai
    case gemini
    case ollama
    case lmstudio
    case custom
}

public struct LLMProviderConfig: Codable, Sendable, Equatable {
    public let id: LLMProviderID
    public let baseURL: URL
    public let apiKey: String?
    public let modelName: String
    public let isLocal: Bool

    // Factory methods for known providers with sensible defaults
    public static func anthropic(apiKey: String, model: String = "claude-sonnet-4-20250514") -> Self
    public static func openai(apiKey: String, model: String = "gpt-4o") -> Self
    public static func gemini(apiKey: String, model: String = "gemini-2.5-flash") -> Self
    public static func ollama(model: String = "llama3.2") -> Self
    public static func lmstudio(model: String) -> Self
    public static func custom(baseURL: URL, apiKey: String?, model: String) -> Self
}
```

#### Step 1.2: Chat Types

**File:** `Sources/MacParakeetCore/Models/LLMTypes.swift`

```swift
public struct ChatMessage: Codable, Sendable {
    public let role: Role
    public let content: String
    public enum Role: String, Codable, Sendable { case system, user, assistant }
}

public struct ChatCompletionOptions: Sendable {
    public let temperature: Double?
    public let maxTokens: Int?
    public let stream: Bool
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

#### Step 1.3: LLM Client Protocol + Implementation

**File:** `Sources/MacParakeetCore/Services/LLMClient.swift`

```swift
public protocol LLMClientProtocol: Sendable {
    func chatCompletion(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) async throws -> ChatCompletionResponse

    func chatCompletionStream(
        messages: [ChatMessage],
        config: LLMProviderConfig,
        options: ChatCompletionOptions
    ) -> AsyncThrowingStream<String, Error>

    /// Verify provider is reachable and auth is valid
    func testConnection(config: LLMProviderConfig) async throws
}
```

Implementation uses URLSession. Key details:
- **OpenAI-compatible path:** `POST {baseURL}/chat/completions` with `Authorization: Bearer {apiKey}`
- **Anthropic native path:** `POST https://api.anthropic.com/v1/messages` with `x-api-key` header and `anthropic-version` header
- **SSE parsing:** Parse `data: {...}` lines for streaming. Handle `data: [DONE]` terminator.
- **Error mapping:** HTTP 401 → `.authenticationFailed`, 429 → `.rateLimited`, 404 → `.modelNotFound`, etc.

#### Step 1.4: LLM Error Types

**File:** `Sources/MacParakeetCore/Services/LLMError.swift`

```swift
public enum LLMError: Error, LocalizedError, Sendable {
    case notConfigured
    case connectionFailed(String)
    case authenticationFailed
    case rateLimited
    case modelNotFound(String)
    case contextTooLong
    case providerError(String)
    case streamingError(String)
}
```

#### Step 1.5: LLM Service (Domain Operations)

**File:** `Sources/MacParakeetCore/Services/LLMService.swift`

```swift
public protocol LLMServiceProtocol: Sendable {
    func summarize(transcript: String) async throws -> String
    func summarizeStream(transcript: String) -> AsyncThrowingStream<String, Error>
    func chat(question: String, transcript: String, history: [ChatMessage]) async throws -> String
    func chatStream(question: String, transcript: String, history: [ChatMessage]) -> AsyncThrowingStream<String, Error>
    func transform(text: String, prompt: String) async throws -> String
    func transformStream(text: String, prompt: String) -> AsyncThrowingStream<String, Error>
}
```

Implementation:
- Builds system prompts per feature (summary, chat, transform)
- Assembles messages array (system + transcript context + user input)
- Context truncation: if transcript is too long, truncate middle (keep beginning + end)
- Delegates to `LLMClientProtocol`

#### Step 1.6: Provider Config Storage

**File:** `Sources/MacParakeetCore/Services/LLMConfigStore.swift`

- Provider ID, base URL, model name → UserDefaults
- API key → Keychain (via existing `KeychainKeyValueStore`)
- Expose as a simple read/write interface for the ViewModel

#### Step 1.7: Tests

**File:** `Tests/MacParakeetTests/LLMClientTests.swift`

- Mock URLSession (or URLProtocol) to test request construction
- Verify headers, body format, auth for each provider type
- Verify SSE parsing (streaming)
- Verify error mapping (401, 429, 404, etc.)

**File:** `Tests/MacParakeetTests/LLMServiceTests.swift`

- Mock LLMClient, verify prompt assembly per feature
- Verify context truncation behavior
- Verify summary/chat/transform prompt templates

**File:** `Tests/MacParakeetTests/LLMConfigStoreTests.swift`

- Verify provider config persistence round-trip
- Verify API key goes to Keychain, not UserDefaults

---

### Phase 2: Settings UI

#### Step 2.1: LLM Settings View

**File:** `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`

Provider picker, API key field, model selector, test connection button, privacy notice. See spec/11-llm-integration.md UI wireframe.

Key behaviors:
- Provider picker updates base URL and clears API key field
- "Test Connection" calls `LLMClient.testConnection()` and shows result
- API key field is a SecureField
- Model name is a text field (not a dropdown — we don't query model lists)
- Privacy notice is always visible, different text for local vs cloud providers
- For Ollama/LM Studio: show "No API key needed" and helpful setup instructions

#### Step 2.2: LLM Settings ViewModel

**File:** `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`

`@MainActor @Observable` with `configure()` pattern. Manages:
- Selected provider ID
- API key (read from Keychain on appear, write on change)
- Model name
- Connection test state (idle/testing/success/error)
- Save/load from LLMConfigStore

#### Step 2.3: Custom Transforms View

**File:** `Sources/MacParakeet/Views/Settings/CustomTransformsView.swift`

List of transforms (built-in + custom). Add/edit/delete custom transforms. Each has name + prompt template.

#### Step 2.4: Wire into Settings

Add "Intelligence" section to existing SettingsView. Below existing settings sections.

#### Step 2.5: Tests

**File:** `Tests/MacParakeetTests/LLMSettingsViewModelTests.swift`

- Test provider selection updates config
- Test connection test flow (mock client)
- Test API key storage/retrieval

---

### Phase 3: Summary Feature

#### Step 3.1: Summary UI on Transcript View

**File:** Modify `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`

Add "Summarize" button to transcript toolbar. When pressed:
- Show summary section below transcript
- Stream response incrementally
- Show loading state during generation
- If no provider configured, show "Set up AI in Settings" message

#### Step 3.2: Summary Persistence

**File:** Modify `Sources/MacParakeetCore/Models/Transcription.swift`

Add `summary: String?` column to Transcription model.

**File:** Modify `Sources/MacParakeetCore/Database/DatabaseManager.swift`

Add migration to add `summary` column.

**File:** Modify `Sources/MacParakeetCore/Database/TranscriptionRepository.swift`

Add `updateSummary(id:summary:)` method.

#### Step 3.3: TranscriptionViewModel Updates

**File:** Modify `Sources/MacParakeetViewModels/TranscriptionViewModel.swift`

Add:
- `summary: String?` (loaded from DB, updated after generation)
- `summaryState: LoadingState` (idle/loading/loaded/error)
- `summarize()` method — calls LLMService.summarizeStream(), persists result
- `llmAvailable: Bool` (checks if provider is configured)

#### Step 3.4: Tests

- ViewModel: test summarize flow with mock LLMService
- Repository: test summary persistence
- Migration: test schema change

---

### Phase 4: Chat Feature

#### Step 4.1: Chat View

**File:** `Sources/MacParakeet/Views/Transcription/TranscriptChatView.swift`

Chat panel alongside transcript. Message list + input field. Streaming responses. See spec wireframe.

#### Step 4.2: Chat ViewModel

**File:** `Sources/MacParakeetViewModels/TranscriptChatViewModel.swift`

`@MainActor @Observable` with `configure()`. Manages:
- `messages: [ChatMessage]` (in-memory conversation history)
- `streamingResponse: String` (current streaming response)
- `isStreaming: Bool`
- `sendMessage(_ text: String)` — appends user message, calls LLMService.chatStream()
- `clearHistory()`

Conversation is in-memory only (not persisted). Scoped to one transcript.

#### Step 4.3: Wire into Transcript View

Add "Chat" tab/toggle to transcript result view. Show chat panel alongside or below transcript.

#### Step 4.4: Tests

- ViewModel: test message flow, streaming state, history management
- Test context assembly with long transcripts (truncation)

---

### Phase 5: Custom Transforms

#### Step 5.1: Transform Action on Text

**File:** Modify transcript views to add context menu / toolbar action for transforms.

When text is selected (or full transcript), show transform options:
- Built-in: "Make formal", "Make concise", "Extract action items", "Fix grammar"
- User-defined custom transforms

#### Step 5.2: Transform Result Display

Show transformed text in a sheet or inline replacement. User can copy result or dismiss.

#### Step 5.3: Tests

- Test transform prompt assembly
- Test custom transform CRUD (UserDefaults)

---

### Phase 6: CLI Support

#### Step 6.1: CLI Commands

**Files:** `Sources/CLI/Commands/LLM/`

- `LLMSummarizeCommand.swift` — `macparakeet-cli llm summarize --file <path>`
- `LLMChatCommand.swift` — `macparakeet-cli llm chat --file <path> "question"`
- `LLMTransformCommand.swift` — `macparakeet-cli llm transform --prompt "..." "text"`
- `LLMStatusCommand.swift` — `macparakeet-cli llm status` (show configured provider)

#### Step 6.2: Tests

- Test CLI argument parsing
- Test output formatting

---

## File Summary

### New Files

| File | Target | Description |
|------|--------|-------------|
| `Models/LLMProvider.swift` | Core | Provider config, IDs, factory methods |
| `Models/LLMTypes.swift` | Core | ChatMessage, options, response, usage types |
| `Services/LLMClient.swift` | Core | HTTP client protocol + implementation |
| `Services/LLMError.swift` | Core | Error taxonomy |
| `Services/LLMService.swift` | Core | Domain operations (summarize, chat, transform) |
| `Services/LLMConfigStore.swift` | Core | Provider config persistence |
| `Views/Settings/LLMSettingsView.swift` | GUI | Provider config UI |
| `Views/Settings/CustomTransformsView.swift` | GUI | Custom transforms management |
| `Views/Transcription/TranscriptChatView.swift` | GUI | Chat panel |
| `ViewModels/LLMSettingsViewModel.swift` | ViewModels | Settings orchestration |
| `ViewModels/TranscriptChatViewModel.swift` | ViewModels | Chat orchestration |
| `Tests/LLMClientTests.swift` | Tests | Client unit tests |
| `Tests/LLMServiceTests.swift` | Tests | Service unit tests |
| `Tests/LLMConfigStoreTests.swift` | Tests | Config persistence tests |
| `Tests/LLMSettingsViewModelTests.swift` | Tests | Settings VM tests |
| `Tests/TranscriptChatViewModelTests.swift` | Tests | Chat VM tests |
| `CLI/Commands/LLM/*.swift` | CLI | CLI commands (4 files) |

### Modified Files

| File | Change |
|------|--------|
| `Models/Transcription.swift` | Add `summary: String?` |
| `Database/DatabaseManager.swift` | Add migration for summary column |
| `Database/TranscriptionRepository.swift` | Add `updateSummary()` |
| `ViewModels/TranscriptionViewModel.swift` | Add summary + LLM state |
| `Views/Transcription/TranscriptResultView.swift` | Add Summary/Chat buttons |
| `Views/Settings/SettingsView.swift` | Add Intelligence section |
| `CLI entry point` | Register LLM commands |

## Implementation Order

Start with Phase 1 (core client) and Phase 2 (settings) — these unblock everything else. Phase 3 (summary) is the highest-value feature and should come next. Phase 4 (chat) and Phase 5 (transforms) can follow in either order. Phase 6 (CLI) is lowest priority.

```
Phase 1 (Core Client) → Phase 2 (Settings UI) → Phase 3 (Summary) → Phase 4 (Chat) → Phase 5 (Transforms) → Phase 6 (CLI)
```

## Out of Scope

- Model list fetching from providers (user types model name manually)
- Token counting / cost estimation (future enhancement)
- Conversation persistence (chat history is in-memory only)
- Dictation-time LLM processing
- Multi-provider fallback routing
- Prompt templates beyond the built-in set
