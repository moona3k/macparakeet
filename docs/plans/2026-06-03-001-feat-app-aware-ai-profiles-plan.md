---
title: "feat: Add app-aware AI formatter profiles"
type: feat
status: active
date: 2026-06-03
origin: docs/brainstorms/2026-06-03-app-aware-ai-profiles-requirements.md
---

# App-Aware AI Formatter Profiles Plan

Generated in the style of `/ce-plan` from the requirements doc and fresh
research packet.

## Scope

Implement the first vertical slice: app-aware prompt profiles for Dictation AI
Formatter.

In scope:

- Exact-bundle and coarse-category profile matching.
- Local profile persistence.
- Settings UI to manage profiles.
- Dictation runtime prompt resolution.
- Local match metadata for completed dictations.
- Privacy-safe local-only telemetry boundary.

Out of scope:

- Browser hostname/domain matching.
- Transform per-app variants.
- Per-profile STT engine/language/provider/model overrides.
- Selected-text, clipboard, or screen/OCR context.
- Manual profile hotkeys.
- File/URL transcription profile matching.

## Requirements Mapping

| Requirement | Plan coverage |
|---|---|
| R1 Global fallback | Unit 3 prompt resolver preserves existing global prompt when no profile matches |
| R2 Exact-app profiles | Unit 1 model/matcher, Unit 2 repository, Unit 4 UI |
| R3 Category profiles | Unit 1 matcher reuses `TelemetryAppCategory`, Unit 4 UI category picker |
| R4 Deterministic matching | Unit 1 pure matcher tests |
| R5 Prompt template contract | Unit 3 formatter integration tests |
| R6 Local app context | Unit 3 start snapshot, stop/undo session context update, focus-drift fallback |
| R7 Settings UX | Unit 4 view model and SwiftUI |
| R8 Privacy and telemetry | Unit 5 local-only telemetry boundary and docs |
| R9 History/debuggability | Unit 2 dictation schema fields, Unit 3 save path |
| R10 Transform compatibility path | Unit 1 shared context types, Unit 6 follow-on ADR note |

## Key Technical Decisions

### KTD-1 - Dedicated Formatter Profile Table

Use a dedicated table for Dictation AI Formatter profiles instead of adding
`appVariants` to `Prompt`.

Reasoning:

- `Prompt.appVariants` is a good Transform-specific shape because a Transform is
  already a prompt entity.
- Dictation AI Formatter currently lives in runtime preferences, not the prompt
  library.
- A dedicated formatter-profile table keeps v1 small and avoids pretending this
  is a full shared workflow system.
- The shared piece for future Transform work should be app-context and matching
  utilities, not necessarily the same storage table.

Proposed table: `ai_formatter_profiles`

Columns:

- `id` UUID primary key.
- `name` TEXT not null.
- `isEnabled` INTEGER not null.
- `targetKind` TEXT not null: `bundle` or `category`.
- `bundleIdentifier` TEXT nullable, normalized lowercase for bundle matches.
- `appDisplayName` TEXT nullable.
- `appCategory` TEXT nullable, `TelemetryAppCategory.rawValue` for category
  matches.
- `promptTemplate` TEXT not null.
- `origin` TEXT not null default `custom`: `custom` or `template`.
- `sortOrder` INTEGER not null default 0.
- `createdAt` DATETIME not null.
- `updatedAt` DATETIME not null.

Repository: one table, one repository, following
`Sources/MacParakeetCore/Database/README.md`.

### KTD-2 - Exact Context Is Local Runtime Data

Create a local app context model for prompt matching:

- `AppPromptContext`
  - `bundleIdentifier: String?`
  - `displayName: String?`
  - `category: TelemetryAppCategory`

The production app-context adapter can read `NSWorkspace.shared.frontmostApplication`
on the main actor. It must stay adapter-shaped and not introduce UI ownership
into Core.

Telemetry continues using `TelemetryAppCategory`; exact bundle IDs and display
names remain local.

### KTD-3 - Async Prompt Resolver Replaces No-Arg Closure

Replace the no-argument `aiFormatterPromptTemplate` closure in DictationService
with a small async resolver:

```swift
public struct AIFormatterPromptResolution: Sendable, Equatable {
    public let promptTemplate: String
    public let matchKind: AIFormatterProfileMatchKind
    public let profileID: UUID?
    public let profileName: String?
    public let profileOrigin: AIFormatterProfileOrigin?
}

public protocol AIFormatterPromptResolving: Sendable {
    func resolvePrompt(for context: AppPromptContext?) async -> AIFormatterPromptResolution
}
```

The app implementation reads enabled profiles and the current global runtime
preference, then returns a resolution. Tests can inject a fake resolver.

Reasoning:

- Repository reads are naturally async in service flow.
- The formatter path already runs inside async work.
- Returning match metadata avoids recomputing profile identity later.

### KTD-4 - Stop-Time Context Wins

Dictation prompt selection should use the same lifecycle moment as current
paste-target telemetry: near stop/undo time, just before `stopRecording` or
`undoCancel` enters the service.

Also capture a best-effort start-time snapshot before MacParakeet UI can become
frontmost. Use it only as a fallback when stop/undo-time context is missing or
identifies MacParakeet itself.

Reasoning:

- Current MacParakeet telemetry is intentionally paste-target oriented.
- TypeWhisper, FluidVoice, and Hex show that app capture can be thrown off if
  the app's own overlay steals focus.
- A fallback snapshot gives us resilience without changing the primary contract.

### KTD-5 - Browser Domains Deferred

Do not add browser hostname matching in this implementation.

When it ships later, it should:

- Parse URLs with `URLComponents`.
- Normalize lowercase host.
- Strip only a leading `www.`.
- Match exact host or subdomain suffix.
- Use deterministic precedence: manual override, app+host, host-only, exact app,
  category, global fallback.
- Avoid substring matching.
- Require explicit browser/Apple Events permission and privacy copy.

## Implementation Units

### Unit 1 - Domain Types and Matcher

Files:

- `Sources/MacParakeetCore/Models/AppPromptContext.swift`
- `Sources/MacParakeetCore/Models/AIFormatterProfile.swift`
- `Sources/MacParakeetCore/Models/AIFormatterProfileMatcher.swift`
- `Tests/MacParakeetTests/Models/AIFormatterProfileMatcherTests.swift`

Tasks:

1. Add `AppPromptContext`.
2. Add `AIFormatterProfile` with `MatchKind`.
3. Add `AIFormatterProfileMatchKind` / resolution metadata.
4. Implement pure matcher:
   - enabled exact bundle match first
   - enabled category match second
   - global fallback outside matcher
5. Normalize bundle IDs by trimming whitespace and lowercasing.
6. Add tests:
   - exact beats category
   - category beats no profile
   - disabled profile ignored
   - unknown/nil bundle maps to `.other`
   - duplicate profiles resolve deterministically or are rejected by repository

Verification:

- `swift test --filter AIFormatterProfileMatcherTests`

### Unit 2 - Persistence and Migrations

Files:

- `Sources/MacParakeetCore/Database/DatabaseManager.swift`
- `Sources/MacParakeetCore/Database/AIFormatterProfileRepository.swift`
- `Sources/MacParakeetCore/Database/DictationRepository.swift`
- `Sources/MacParakeetCore/Models/Dictation.swift`
- `spec/01-data-model.md`
- `Tests/MacParakeetTests/Database/AIFormatterProfileRepositoryTests.swift`
- `Tests/MacParakeetTests/Database/DatabaseManagerTests.swift`
- `Tests/MacParakeetTests/Database/DictationRepositoryTests.swift`

Tasks:

1. Read `Sources/MacParakeetCore/Database/README.md` before editing.
2. Register a new forward-only migration with the next available version name.
   Do not reuse the stale `v0.14` from old ADR-023.
3. Create `ai_formatter_profiles`.
4. Add optional local dictation metadata columns:
   - `aiFormatterProfileID`
   - `aiFormatterProfileName`
   - `aiFormatterProfileMatchKind`
5. Implement repository CRUD:
   - list enabled
   - save/update
   - delete
   - fetch by ID
   - normalize match keys
6. Add tests for empty DB migration, CRUD, normalization, disabled filtering,
   and dictation row round-trip.

Verification:

- `swift test --filter AIFormatterProfileRepositoryTests`
- `swift test --filter DatabaseManagerTests`
- `swift test --filter DictationRepositoryTests`

### Unit 3 - Dictation Runtime Integration

Files:

- `Sources/MacParakeet/App/AppEnvironment.swift`
- `Sources/MacParakeet/App/DictationFlowCoordinator.swift`
- `Sources/MacParakeetCore/Services/Dictation/DictationService.swift`
- `Sources/MacParakeetCore/Services/Dictation/DictationServiceSession.swift`
- `Sources/MacParakeetCore/Services/System/FocusedAppContextService.swift`
- `Sources/MacParakeetCore/Services/LLM/LLMService.swift` if signature changes are needed
- `Tests/MacParakeetTests/Services/Dictation/DictationServiceTests.swift`

Tasks:

1. Add a small AppKit-backed focused-app adapter. Keep it service-shaped and
   local-only.
2. Add `updateAIFormatterAppContext(_:phase:sessionID:)` to `DictationService` and
   `DictationServiceSession`.
3. Capture start-time context when recording starts, before any UI can become
   frontmost, and pass it into the service as phase `start`.
4. In `DictationFlowCoordinator.stopRecordingTask`, capture focused app once
   and update both:
   - telemetry category
   - formatter app context
   with phase `finish`
5. Mirror finish-context behavior in `undoCancelTask`.
6. In service state, choose finish context when valid; otherwise fall back to
   start context. Treat MacParakeet's own bundle ID as invalid for profile
   routing.
7. Replace no-arg prompt closure with async resolver.
8. `formatTranscriptIfNeeded` asks resolver for prompt resolution, passes prompt
   to `LLMService`, computes `defaultPromptUsed`, and returns resolution
   metadata with the formatter outcome.
9. Save matched profile metadata on the dictation row when history is saved.
10. Preserve fallback behavior on LLM failure.

Tests:

- No profiles -> existing global prompt used.
- Exact app profile prompt used.
- Category profile prompt used.
- Exact app beats category.
- Stale session context update ignored.
- Finish context beats start context.
- Start context is used when finish context is missing or self-app.
- Undo-cancel uses current context.
- LLM failure falls back to standard cleanup and records failed run metadata.

Verification:

- `swift test --filter DictationServiceTests`
- `swift test --filter LLMService`

### Unit 4 - Settings UI and ViewModel

Files:

- `Sources/MacParakeetViewModels/LLMSettingsViewModel.swift`
- `Sources/MacParakeet/Views/Settings/LLMSettingsView.swift`
- `Tests/MacParakeetTests/ViewModels/LLMSettingsViewModelTests.swift`

Tasks:

1. Add profile list under the existing AI Formatter section.
2. Add create/edit/delete/enable controls.
3. Add manual bundle ID entry for exact-app profiles.
4. Add category picker using `TelemetryAppCategory.allCases`.
5. Add prompt editor using the same `{{TRANSCRIPT}}` contract.
6. Show precedence help in UI: exact app beats category, global prompt is
   fallback.
7. Defer running-app picker and profile templates to a later polish slice.

Verification:

- `swift test --filter LLMSettingsViewModelTests`
- Manual: open Settings -> AI Formatter, create Slack/app profile, create Email
  category profile, disable/delete both.

### Unit 5 - Telemetry, Privacy, and Docs

Files:

- `docs/telemetry.md`
- `docs/brainstorms/2026-06-03-app-aware-ai-profiles-requirements.md`
- `spec/01-data-model.md`
- `spec/11-llm-integration.md`
- `spec/12-processing-layer.md`
- `spec/02-features.md`

Tasks:

1. Keep formatter-profile routing metadata local in V1.
2. Do not add formatter-profile telemetry fields in this branch.
3. Verify no exact bundle ID, app name, profile id/name, match kind, hostname,
   prompt, transcript, clipboard, selected text, or screen text can leave the
   device through telemetry.
4. Update docs to state that exact app context is local-only and AI Formatter
   still sends transcript/prompt only to the user's configured provider.
5. If future telemetry keys are added, update the website allowlist in the
   paired `macparakeet-website` repo before calling that future slice done.

Verification:

- `swift test --filter Telemetry`
- Manual telemetry payload inspection in debug logs or test fake.

### Unit 6 - Follow-On ADR Cleanup

Files:

- `spec/adr/023-app-aware-ai-profiles.md` or an amended transform ADR when
  implementation starts.

Tasks:

1. Capture the final v1 decisions in an ADR before code lands, if owner wants
   locked decision text.
2. Explicitly supersede stale parts of the old transform-only ADR:
   - stale migration number
   - duplicate `CaptureContext`
   - old coordinator capture assumption
3. Keep Transform per-app variants as a follow-on that reuses context/matcher
   utilities but stores variants on individual Transform prompts.

## Data Flow

```text
Focused app at start
    -> start AppPromptContext
Focused app at stop/undo
    -> finish AppPromptContext
    -> DictationServiceSession.updateAIFormatterAppContext(..., phase)
    -> finish context if valid, else start context
    -> DictationService.formatTranscriptIfNeeded(...)
    -> AIFormatterPromptResolver
    -> exact profile / category profile / global prompt
    -> LLMService.formatTranscriptDetailed(...)
    -> Dictation row with local profile metadata
    -> Telemetry with coarse category and optional match kind only
```

## Privacy Review Checklist

- Exact bundle ID stays local.
- App display name stays local.
- Profile prompt body is not telemetry.
- Transcript content is not telemetry.
- Profile match kind is bounded enum.
- App category is existing bounded enum.
- Browser hostname matching is absent in v1.
- No selected text, clipboard, or screen context is read by this feature.
- If stop/undo-time context resolves to MacParakeet itself, it is used only for
  fallback detection, not as a match target.

## Manual Smoke Plan

1. Enable AI Formatter with an LLM provider.
2. Create exact-app profile for TextEdit with a distinctive prompt.
3. Dictate into TextEdit and confirm profile prompt output.
4. Dictate into another app and confirm global prompt output.
5. Create `terminal` category profile.
6. Dictate into Terminal/iTerm and confirm category profile output.
7. Create exact Terminal profile and confirm exact beats category.
8. Disable all profiles and confirm global prompt output.
9. Check history row shows matched profile metadata locally.
10. Inspect telemetry/test fake to confirm no exact app data leaves the device.

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---:|---:|---|
| App context sampled from wrong lifecycle moment | Medium | High | Use stop/undo time as primary, with start-time fallback for focus drift |
| Profile UI becomes a workflow engine | Medium | Medium | Keep v1 fields to match target and prompt only |
| Exact bundle ID leaks through telemetry | Low | High | Bounded telemetry enums only, tests and docs |
| Browser/Gmail expectations exceed v1 | High | Medium | Name browser limitation clearly and plan hostname slice |
| Duplicate profiles make behavior confusing | Medium | Medium | Prevent duplicates or sort deterministically and show precedence |
| Async resolver adds service churn | Medium | Medium | Small protocol, fake resolver tests, preserve existing fallback |

## Done Criteria

- Requirements R1-R9 are implemented and tested.
- `swift test` passes.
- Settings can create, edit, disable, and delete profiles.
- Dictation stop and undo-cancel use matched profile prompts.
- Exact app beats category.
- Existing global behavior is preserved when no profile matches.
- Telemetry contains no exact app/profile content.
- Docs explain browser-domain deferral and future Transform path.
