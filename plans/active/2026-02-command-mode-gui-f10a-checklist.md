# Command Mode GUI (F10a) Implementation Checklist

Status: Ready for implementation
Owner: Core app team
Updated: 2026-02-13

## Objective

Ship the core Command Mode GUI flow end-to-end:

1. user selects text in any app
2. user activates Command Mode
3. user speaks a command
4. STT + Qwen3-8B transforms selected text
5. result replaces selection via existing paste mechanism

This is the GUI counterpart to the already-working CLI path:
`macparakeet-cli llm command "<command>" "<selected_text>"`.

## Scope (F10a)

In scope:

1. hotkey activation for command mode
2. selected-text capture via Accessibility API
3. recording + overlay UX for spoken command
4. LLM transform via existing `LLMPromptBuilder.commandTransform`
5. in-place replace via existing `ClipboardService.pasteText`
6. core unit/integration tests and manual cross-app validation

Out of scope (F10b follow-up):

1. pre-built command quick actions in overlay
2. custom command templates/save-reuse UX
3. command-mode hotkey configurability
4. command history UI

## Required Spec Alignment (before code PR or in same PR, first commit)

Current acceptance in `spec/02-features.md` includes pre-built/custom commands.
For this slice, split acceptance into:

1. `F10a` (core flow): hotkey, selection capture, STT, LLM transform, replacement, error handling
2. `F10b` (enhancements): pre-built commands + custom templates

Also keep `spec/07-text-processing.md` consistent with this split.

## Locked Decisions

| Decision | Choice |
|---|---|
| Activation | Default chord `Fn+Control` |
| Trigger model | Single activation model: `Fn+Control` starts recording; overlay Stop processes; `Esc` or second `Fn+Control` cancels |
| Dictation interaction | Mutual exclusion: command mode and dictation cannot run together |
| Selected text limit | Hard cap 16,000 chars; fail with explicit error (no silent truncation) |
| Selection retrieval | Fallback chain via AX API (not only `kAXSelectedTextAttribute`) |
| Overlay implementation | Separate command overlay/controller; reuse design tokens + `WaveformView` |
| Service boundary | `CommandModeService` handles record+STT+LLM; `AppDelegate` orchestrates selection read + paste |
| Entitlements/permissions | Reuse existing transcribe entitlement gate + accessibility permission gate |

## Architecture Changes

### New files

1. `Sources/MacParakeetCore/Services/AccessibilityService.swift`
2. `Sources/MacParakeetCore/Services/CommandModeService.swift`
3. `Sources/MacParakeetCore/Models/CommandModeResult.swift`
4. `Sources/MacParakeet/Views/CommandMode/CommandModeOverlayView.swift`
5. `Sources/MacParakeet/Views/CommandMode/CommandModeOverlayController.swift`
6. `Sources/MacParakeet/Views/CommandMode/CommandModeOverlayViewModel.swift`
7. `Tests/MacParakeetTests/Services/AccessibilityServiceTests.swift`
8. `Tests/MacParakeetTests/Services/CommandModeServiceTests.swift`

### Modified files

1. `Sources/MacParakeet/Hotkey/HotkeyManager.swift`
2. `Sources/MacParakeet/AppDelegate.swift`
3. `Sources/MacParakeet/App/AppEnvironment.swift`
4. `spec/02-features.md` (F10a/F10b acceptance split)
5. `spec/07-text-processing.md` (scope alignment)
6. `plans/active/2026-02-qwen3-8b-implementation-checklist.md` (mark F10a in progress/completed when done)

## Implementation Order

### 0. Spec commit (mandatory first)

1. split F10 acceptance into F10a/F10b in spec docs
2. confirm this PR is F10a only

### 1. Accessibility service

Implement `AccessibilityServiceProtocol`:

1. `getSelectedText() throws -> String`
2. fallback sequence:
   - focused element + `kAXSelectedTextAttribute`
   - if empty, read selected range and parameterized substring from value
3. validate non-empty selection
4. reject >16,000 chars with `textTooLong`

Error taxonomy:

1. `notAuthorized`
2. `noFocusedElement`
3. `noSelectedText`
4. `textTooLong(max: Int, actual: Int)`
5. `unsupportedElement`

### 2. Command mode core service

`CommandModeService` actor responsibilities:

1. `startRecording()`
2. `stopRecordingAndProcess(selectedText: String) async throws -> CommandModeResult`
3. `cancelRecording()`
4. state exposure: `idle | recording | processing`
5. `audioLevel` passthrough from `AudioProcessorProtocol`

Processing path:

1. stop capture
2. STT transcript for spoken command
3. validate spoken command non-empty
4. build `LLMTask.commandTransform(command:selectedText:)`
5. call `LLMServiceProtocol.generate` with command-mode options
6. return transformed text + metadata

### 3. Hotkey manager chord support

Add callbacks:

1. `onStartCommandMode`
2. `onCancelCommandMode`

Behavior:

1. detect rising edge of `Fn+Control` chord
2. command chord takes precedence over dictation gestures
3. when command mode active, suppress dictation state-machine actions
4. second chord press while command mode active triggers cancel callback
5. `Esc` path stays supported via app-level cancel handling

### 4. Command overlay UI

Add command-specific overlay states:

1. recording: "Speak your command..." + selected text preview + waveform + cancel/stop
2. processing: "Applying command..."
3. success: brief checkmark
4. error: brief actionable message

Preview rules:

1. show truncated preview (UI only, e.g. 50 chars)
2. always show total selected char count

### 5. App environment wiring

In `Sources/MacParakeet/App/AppEnvironment.swift`:

1. instantiate `AccessibilityService`
2. instantiate `CommandModeService`
3. expose both for app delegate usage

### 6. App delegate orchestration

In `Sources/MacParakeet/AppDelegate.swift`:

1. add command-mode task/controller/view-model references
2. `startCommandMode` flow:
   - guard not dictating
   - entitlement check
   - read selection (accessibility service)
   - show recording overlay
   - start command recording
3. `stopCommandMode` flow:
   - move to processing
   - get `CommandModeResult`
   - `resignKeyWindow()` on command overlay controller
   - paste transformed text with `ClipboardService`
4. `cancelCommandMode` flow:
   - cancel recording
   - dismiss overlay
5. wire hotkey callbacks and `Esc` cancellation

### 7. Menu bar integration

In status item menu:

1. add "Command Mode" action (matches feature spec)
2. invoke same `startCommandMode` entry point

## Test Plan

### Unit tests

`AccessibilityServiceTests`:

1. no focus element
2. no selected text
3. selected text retrieval success
4. selected text too long rejection

`CommandModeServiceTests`:

1. happy path: selected text + spoken command -> transformed text
2. empty STT command -> error
3. LLM error/timeout -> propagated error
4. state transitions idle -> recording -> processing -> idle

### Integration tests

1. hotkey chord precedence over dictation trigger
2. second chord press cancels command mode
3. no selected text path shows user-facing error and returns idle
4. stop path pastes transformed result once

### Manual matrix

1. TextEdit
2. Notes
3. Slack
4. Safari text area
5. VS Code editor

Verify:

1. selection captured correctly
2. replacement works
3. `Cmd+Z` in target app reverts replacement

## PR Slicing (recommended)

1. `spec`: F10a/F10b acceptance split
2. `core`: accessibility + command service + tests
3. `app`: hotkey + overlay + app delegate + menu action
4. `final`: integration tests + docs/checklist status update

## Definition of Done

1. `swift build` passes
2. `swift test` passes
3. manual matrix passes for all listed apps
4. no regression to dictation hotkey behavior
5. F10a acceptance checked in spec and PR description
