# LLM Runs Ledger

> Status: **COMPLETED FOR FORMATTER V1**. Archived from `plans/active/`
> during the 2026-05-16 docs/spec audit. Prompt/chat/transform recording
> remains deferred until streaming LLM APIs expose a terminal metadata envelope;
> that expansion should get a fresh plan.

## Goal

Add a local metadata ledger for LLM operations so MacParakeet can answer
questions such as which provider/model ran, how often, how long it took, token
usage when available, failure rate, and which product feature triggered the
call.

This is metadata only. User content remains in the feature-owned tables that
already store it.

## Verified Current State

- `LLMResult` already carries provider, model, token usage, stop reason, and
  latency for non-streaming detailed calls.
- AI Formatter is the only non-streaming app flow still returning only a
  `String`.
- Prompt results, chat, and transforms use streaming APIs in the app. Those
  streams currently yield text tokens only, so they do not expose a final
  provider/model/token envelope to callers yet.
- Prompt result content already lives in `summaries`.
- Chat content already lives in `chat_conversations`.
- Transform input/output already lives in `transform_history`.

## Data Flow

```text
User action
  |
  v
Feature owner
  |
  |-- dictation formatter
  |-- transcription formatter
  |-- prompt result generation
  |-- transcript chat
  |-- transform
  |
  v
LLMService
  |
  |-- resolves provider/model/config
  |-- sends provider request
  |-- returns output + metadata when the call has a detailed envelope
  |
  v
Feature-owned persistence
  |
  |-- dictations.cleanTranscript
  |-- transcriptions.cleanTranscript
  |-- summaries.content
  |-- chat_conversations.messages
  |-- transform_history.inputText/outputText
  |
  v
LLMRunRecorder
  |
  |-- copies metadata only
  |-- links to the persisted source row
  |-- never duplicates transcript/chat/prompt body text
  |
  v
llm_runs

```

## Storage Boundary

```text
llm_runs
  stores:
    feature, status, provider, model, latencyMs
    promptTokens, completionTokens, totalTokens
    inputChars, outputChars, stopReason, errorType
    inputTruncated, defaultPromptUsed, messageCount
    source row ids, createdAt, updatedAt

  does not store:
    transcript text
    chat question/answer text
    prompt templates
    transform input/output text
    rendered prompts
    audio paths or audio content
```

## Source Links

```text
llm_runs
  |
  |-- dictationId        -> dictations.id
  |-- transcriptionId    -> transcriptions.id
  |-- promptResultId     -> summaries.id
  |-- chatConversationId -> chat_conversations.id
  |-- transformHistoryId -> transform_history.id
```

## First Implementation Scope

Implement the table, model, repository, recorder, and formatter recording.

Formatter is the right first writer because it is issue #265's feature surface
and it is a non-streaming app flow. The implementation will add
`formatTranscriptDetailed(...)`, preserve the existing `formatTranscript(...)`
string API as a projection, and record formatter metadata after persisted
dictation/transcription rows exist.

Implemented in this branch:

- `llm_runs` table, model, repository, and recorder.
- `formatTranscriptDetailed(...)` returning `LLMFormatterResult`.
- Formatter run recording for persisted dictations and transcriptions.
- Metadata-only storage; no prompt/input/output content copied into
  `llm_runs`.
- No rows for private/no-history dictations or transient transcriptions.

## Deferred Scope

Do not record prompt/chat/transform runs in this change. Their app flows use
streaming APIs that currently do not return a final metadata envelope. Add
those rows after the stream API has a terminal result shape that includes
provider/model/token metadata.

Do not add analytics UI in this change. The ledger is the foundation for later
local queries.

## Invariants

- `LLMService` remains database-free.
- Deterministic cleanup stays unchanged and LLM-free by default.
- No full prompt/input/output text is duplicated into `llm_runs`.
- Private/no-history dictations do not create formatter run rows.
- Transient transcriptions do not create formatter run rows.
- Every persisted run row has at least one source-row link.
- Deleting a source row cascades its associated run metadata.
