# Transcript Chat GUI Deep Dive

> Status: **HISTORICAL** - Transcript Chat and LLM support removed 2026-02-23.

Status: Draft proposal for implementation  
Date: 2026-02-14  
Scope: Codebase readiness review + premium UI/UX ideation for transcript chat GUI

## 1) Executive Summary

Transcript chat GUI is a strong near-term bet:

1. Core LLM stack is already in production for other surfaces.
2. CLI transcript chat is shipped and tested.
3. Main missing piece is app-level orchestration + premium interaction design in the transcript detail view.

The shortest path is an in-context chat panel in `TranscriptResultView` backed by new chat state in `TranscriptionViewModel`, reusing `LLMTask.transcriptChat` + `TranscriptContextAssembler`.

## 2) Codebase Deep Dive

### 2.1 What Already Exists (High Reuse Potential)

1. GUI transcript detail surface is already present and stable:
   - `Sources/MacParakeet/Views/Transcription/TranscriptResultView.swift`
2. Transcript selection + detail routing already exists:
   - `Sources/MacParakeet/Views/Transcription/TranscribeView.swift`
   - `Sources/MacParakeetViewModels/TranscriptionViewModel.swift`
3. LLM runtime is integrated and shared:
   - `Sources/MacParakeet/App/AppEnvironment.swift`
   - `Sources/MacParakeetCore/LLM/MLXLLMService.swift`
4. Prompt contracts for transcript chat are in core:
   - `Sources/MacParakeetCore/LLM/LLMPromptBuilder.swift`
5. Context bounding/truncation already exists:
   - `Sources/MacParakeetCore/LLM/TranscriptContextAssembler.swift`
6. CLI transcript chat baseline is implemented and tested:
   - `Sources/CLI/Commands/LLMCommand.swift`
   - `Tests/CLITests/LLMChatCommandTests.swift`

### 2.2 Gaps Blocking GUI Chat

1. `TranscriptionViewModel` has no LLM dependency injection path today.
2. No chat message domain model exists in GUI layers (messages, roles, timestamps, status, errors).
3. `TranscriptResultView` has no sidecar/panel region; it is transcript-first with export action bar only.
4. No chat-focused tests in `TranscriptionViewModelTests`.
5. No persistence contract for chat history per transcription (decision still open).

### 2.3 Architecture Readiness Notes

1. `LLMServiceProtocol` is async and already suitable for GUI requests.
2. Runtime idle unload is already handled by `MLXLLMService` (good for memory safety).
3. Existing risk register already names transcript context overflow; GUI should preserve bounded context policy:
   - `docs/planning/llm-runtime-risk-register.md` (R8)

### 2.4 Product/Spec Alignment

1. GUI transcript chat is explicitly planned in README:
   - `README.md` ("Chat with Transcript (GUI)")
2. LLM integration spec explicitly says transcript chat GUI is pending:
   - `spec/11-llm-integration.md`

## 3) Current Constraints To Design Around

1. Local-only runtime means variable first-response latency.
2. 8 GB devices can hit memory pressure under repeated chat use.
3. Transcript text can be long; prompt assembly must be bounded.
4. Mac app is currently single-window split nav; chat should not break that mental model.

## 4) Premium UI/UX Research Synthesis

### 4.1 Patterns Seen In Strong Transcript-Chat Products

1. "Ask in panel" adjacent to notes/transcript:
   - Otter opens AI Chat in a right-side panel with suggested prompts.
2. Explicit scope controls ("this note" vs "all notes/calls"):
   - Granola supports "This meeting" vs broader, team-wide meeting scope.
   - Fathom product updates indicate all-meetings ask/chat direction.
3. Grounded answers with evidence:
   - Granola shows citations to source notes.
   - Microsoft Copilot recaps expose citation numbers and source references.
4. Prompt acceleration:
   - Otter uses suggested starter prompts to reduce blank-state friction.
5. Thread continuity:
   - Granola supports chat over selected notes and team meeting sets.

### 4.2 macOS Quality/A11y Baseline

Apple guidance highlights:

1. minimum text size around 12 pt in body contexts,
2. minimum touch/click targets around 44x44,
3. clear contrast and clear state communication.

These requirements map directly to chat composer, chips, and message rows.

## 5) Premium Transcript Chat GUI Concept Directions

### Direction A: Sidecar Analyst (Recommended MVP)

Layout:
1. Keep transcript reading flow central.
2. Add right-side chat panel inside transcript detail view.

Why:
1. Matches user expectation from Otter/Granola/Fathom patterns.
2. Preserves transcript as source of truth.
3. Lowest implementation risk in current SwiftUI structure.

### Direction B: Full-Screen Conversation Mode

Layout:
1. Toggle from transcript detail into "Q&A mode".
2. Transcript becomes contextual strip; chat takes focus.

Why:
1. Premium and immersive.
2. Better for long exploratory analysis sessions.
3. Higher implementation complexity and navigation churn.

### Direction C: Floating Command Deck

Layout:
1. Compact floating ask bar with expandable answer tray.
2. Works as lightweight overlay over transcript.

Why:
1. Fast and stylish.
2. Great for quick one-off questions.
3. Harder to support deep multi-turn history cleanly.

## 6) Recommended UX Spec (MVP -> Premium)

### 6.1 Information Architecture

MVP:
1. Transcript (left/main)
2. Chat panel (right, fixed width ~360-420)

Panel sections:
1. Header: "Ask this transcript", model status badge.
2. Suggested prompts row.
3. Message thread.
4. Composer with send action.

### 6.2 Interaction Model

1. Send question:
   - optimistic add user bubble
   - assistant bubble in loading state
   - replace with final answer or recoverable error state
2. Follow-up:
   - thread kept in-memory for current transcription session
3. Scope:
   - MVP fixed to current transcript only
   - future: add "current transcript / all transcripts" segmented control
4. Trust:
   - show "Grounded in this transcript" chip
   - future: inline citations to transcript segments

### 6.3 Premium Visual Language

1. Reuse existing warm/coral design tokens (`DesignSystem`).
2. Assistant responses in elevated warm cards, user prompts in lighter neutral cards.
3. Use subtle staged reveal for first answer card (not constant motion).
4. Suggested prompt chips as pill controls with clear hover/focus states.

### 6.4 Empty/Loading/Error States

1. Empty:
   - 3-4 suggested prompts (action items, decisions, blockers, summary)
2. Loading:
   - typed dots or shimmer line + "Analyzing transcript locally..."
3. Error:
   - non-blocking inline error row with retry button
   - preserve user prompt text in composer

## 7) Implementation Plan (Code-Level)

### Slice 1: Core GUI Chat State

1. Extend `TranscriptionViewModel`:
   - inject `llmService`
   - add chat message model + state (`idle/generating/error`)
   - add `sendChatQuestion()` using `LLMPromptBuilder` + `TranscriptContextAssembler`
2. Wire from app startup:
   - `AppDelegate.setupEnvironment()` passes `env.llmService` into `TranscriptionViewModel.configure(...)`

### Slice 2: Transcript Chat Panel UI

1. Add chat panel component(s) under `Sources/MacParakeet/Views/Transcription/`.
2. Embed panel in `TranscriptResultView` as two-column content region.
3. Add suggested prompts and keyboard send behavior.

### Slice 3: Test Coverage

1. `TranscriptionViewModelTests`:
   - success response flow
   - empty question rejection
   - runtime error flow
   - context bounding behavior (long transcript)
2. Mock updates:
   - add `MockLLMService` usage from existing LLM test helpers

### Slice 4: Premium Enhancements

1. Per-transcription thread persistence.
2. Evidence links/highlightable citation spans in transcript.
3. Scope toggle ("this transcript" / "all transcripts") with retrieval strategy.

## 8) Risks and Mitigations

1. Cold-start latency:
   - Mitigation: explicit local processing status line and optimistic UI shell.
2. Long transcript overflow:
   - Mitigation: keep `TranscriptContextAssembler` bounds in GUI path.
3. Hallucination trust gap:
   - Mitigation: constrain system prompt to transcript-only answers and add provenance UI in v2.
4. Memory on lower-RAM devices:
   - Mitigation: keep current idle unload behavior, avoid background chat preloads.

## 9) Recommendation

Build Direction A (Sidecar Analyst) first. It delivers the highest perceived value-to-effort ratio, reuses existing code seams, and aligns with observed premium patterns from transcript AI products.

## 10) External References

1. Apple design tips (text size, target size, contrast): https://developer.apple.com/design/tips/  
2. Microsoft Copilot citations in recap: https://support.microsoft.com/en-us/office/get-started-with-copilot-in-meetings-and-events-c78dbf5d-8d53-4dcd-85d3-1eb56f9d0049  
3. Granola Ask + citations + note selection: https://help.granola.ai/en/articles/10388357-ask  
4. Granola cross-meeting chat scope: https://help.granola.ai/en/articles/11439685-chat-with-your-whole-teams-meetings  
5. Otter AI chat side panel + suggested prompts: https://help.otter.ai/hc/en-us/articles/360053264454-Otter-AI-Chat  
6. Granola teammate notes as chat scope: https://help.granola.ai/en/articles/11429052-chat-with-teammate-s-meeting-notes  
7. Fathom update ("Ask Fathom over all your meetings"): https://www.fathom.video/whats-new/ask-fathom-chat-over-all-your-meetings
